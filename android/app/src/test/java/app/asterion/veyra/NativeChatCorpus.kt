package app.asterion.veyra

import app.asterion.veyra.ChatStateV2.ContentKey
import app.asterion.veyra.ChatStateV2.DateBits
import app.asterion.veyra.ChatStateV2.Engine
import app.asterion.veyra.ChatStateV2.Family
import app.asterion.veyra.ChatStateV2.OrderKey
import app.asterion.veyra.ChatStateV2.Payload
import app.asterion.veyra.ChatStateV2.Reference
import app.asterion.veyra.ChatStateV2.State
import app.asterion.veyra.ChatStateV2.Validated
import app.asterion.veyra.ChatStateV2.Variant
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/**
 * Fixed synthetic XCTest evidence reader/replayer, compiled only in unit tests.
 * Not a vault codec, general state importer, production serializer or writer gate.
 * The resource digest is checked separately: adversarial tests reach the actual
 * coverage and result comparisons instead of failing only at a checksum check.
 */
internal object NativeChatCorpus {
    private const val MAX_BYTES = 1024 * 1024
    private const val ROOT = "abcdef01-2345-4abc-8def-0123456789ab"
    private const val ORIGIN = "00000000-0000-4000-8000-000000000001"
    private const val BATCH = "00000000-0000-4000-8000-000000000002"
    private const val FORMAT = "veyra-chat-state-v2-projection-evidence-v1"
    private val permutations = listOf(listOf(0, 1, 2), listOf(0, 2, 1), listOf(1, 0, 2), listOf(1, 2, 0), listOf(2, 0, 1), listOf(2, 1, 0))

    fun verify(raw: ByteArray): Int {
        require(raw.size <= MAX_BYTES) { "Evidence size limit" }
        val document = Reader(utf8(raw)).read()
        keys(document, setOf("format", "producer", "status", "scenarios"))
        require(document.get("format") == FORMAT && document.get("producer") == "ChatStateV2Tests" && document.get("status") == "native-export") {
            "Complete native chat evidence is required"
        }
        val scenarios = document.get("scenarios") as? JSONArray ?: error("Expected scenarios")
        val required = inputs()
        require(scenarios.length() == required.size) { "Incomplete scenario coverage" }
        var count = 0
        required.entries.forEachIndexed { index, (name, sources) ->
            val scenario = scenarios.get(index) as? JSONObject ?: error("Expected scenario")
            keys(scenario, setOf("name", "inputs", "results"))
            match(scenario.get("name"), name, "scenarios[$index].name")
            // Pin every source, including its raw order, date bits and exact bytes,
            // before constructing typed states. Changed coverage cannot validate itself.
            match(scenario.get("inputs"), array(sources.map(::stateRecord)), "scenarios[$index].inputs")
            val received = scenario.getJSONArray("inputs")
            val decoded = (0 until received.length()).map { coveredState(received.getJSONObject(it)) }
            val calculated = replay(name, decoded)
            match(scenario.get("results"), calculated, "scenarios[$index].results")
            count += calculated.length()
        }
        require(count == 44) { "Incomplete result coverage" }
        return count
    }

    /** Independent Kotlin construction of the fixed native coverage specification. */
    private fun inputs(): Map<String, List<State>> {
        val engine = Engine()
        fun variant(text: String, date: DateBits, project: String = "General", role: String = "user"): Variant {
            val payload = Payload(project, role, text)
            return Variant(engine.contentKey(payload), payload, date)
        }
        fun v(text: String, date: Double) = variant(text, DateBits.fromDouble(date))
        fun family(variants: List<Variant>, id: String = ROOT, anchor: ContentKey = engine.contentKey(Payload("General", "user", "X")),
                   order: OrderKey = OrderKey(0uL, ORIGIN, BATCH, 0uL)) = Family(id, anchor, order, variants)
        fun state(variants: List<Variant>) = State(families = listOf(family(variants)))
        val nfc = variant("café", DateBits(0x8000000000000000uL), role = "assistant")
        val plus = variant("café", DateBits(0uL), role = "assistant")
        val nfd = variant("cafe\u0301", DateBits(1uL), role = "assistant")
        val escaped = variant("\u0000😀\n", DateBits(0x3ff0000000000001uL), project = "😀")
        val small = OrderKey(1uL, BATCH, ORIGIN, 9uL)
        val large = OrderKey(2uL, ORIGIN, BATCH, 0uL)
        val f0 = family(listOf(v("X", 100.0)), id = "00000000-0000-4000-8000-000000000000")
        val f1 = family(listOf(v("X", 100.0)), id = ORIGIN, order = OrderKey(0uL, ORIGIN, BATCH, 1uL))
        val stale = state(listOf(v("X", 200.0), v("Y", 150.0), v("Z", 99.0)))
        return linkedMapOf(
            "unicode" to listOf(
                State(orderClock = 3uL, families = listOf(family(listOf(nfc), anchor = nfc.contentKey, order = small))),
                State(orderClock = 7uL, families = listOf(family(listOf(plus, nfd), anchor = nfc.contentKey, order = large))),
                State(families = listOf(family(listOf(plus, escaped), anchor = nfc.contentKey, order = small)))),
            "source-order" to listOf(State(families = listOf(f0)), State(families = listOf(f1)), State(families = listOf(f1, f0))),
            "date-grouping" to listOf(state(listOf(v("X", 100.0))), state(listOf(v("X", 200.0))), state(listOf(v("X", 200.0), v("Y", 150.0)))),
            "variant-delete-replay" to listOf(state(listOf(v("X", 100.0), v("Y", 150.0))), stale),
            "family-delete-replay" to listOf(state(listOf(v("X", 100.0))), stale))
    }

    private fun replay(name: String, sources: List<State>): JSONArray {
        val engine = Engine()
        val checked = sources.map(engine::validate)
        fun result(label: String, value: Validated) = obj("name" to label, "state" to stateRecord(value.state),
            "projection" to array(engine.project(value).map { row -> obj("reference" to referenceRecord(row.reference),
                "payload" to payloadRecord(row.payload), "dateBits" to row.dateBits.hex) }))
        if (name in setOf("unicode", "source-order", "date-grouping")) {
            return array(permutations.flatMap { (a, b, c) ->
                val label = "$a$b$c"
                listOf(result("$label-left", engine.join(engine.join(checked[a], checked[b]), checked[c])),
                    result("$label-right", engine.join(checked[a], engine.join(checked[b], checked[c]))))
            })
        }
        val initial = checked[0]
        val deleted: Validated
        val text: String
        when (name) {
            "variant-delete-replay" -> { deleted = engine.deleteVariants(initial, setOf(engine.project(initial).first().reference)).state; text = "X" }
            "family-delete-replay" -> { deleted = engine.deleteFamilies(initial, setOf(ROOT)).state; text = "late" }
            else -> error("Unknown scenario")
        }
        val replayed = engine.join(deleted, checked[1])
        val observed = engine.observe(replayed, ROOT, Payload("General", "user", text), DateBits.fromDouble(1.0)).state
        return array(listOf(result("initial", initial), result("deleted", deleted), result("replayed", replayed), result("observed", observed)))
    }

    private fun payloadRecord(payload: Payload) = obj("projectUTF8" to hex(payload.project.toByteArray(Charsets.UTF_8)),
        "roleUTF8" to hex(payload.role.toByteArray(Charsets.UTF_8)), "textUTF8" to hex(payload.text.toByteArray(Charsets.UTF_8)))
    private fun referenceRecord(reference: Reference) = obj("familyID" to reference.familyID, "contentKey" to reference.contentKey.hex, "projectedID" to reference.projectedID)
    private fun stateRecord(state: State): JSONObject = obj("format" to state.format, "identityScheme" to state.identityScheme,
        "orderClock" to state.orderClock.toString(), "families" to array(state.families.map { family ->
            obj("familyID" to family.familyID, "anchorContentKey" to family.anchorContentKey.hex,
                "orderKey" to obj("counter" to family.orderKey.counter.toString(), "originID" to family.orderKey.originID,
                    "batchID" to family.orderKey.batchID, "sequence" to family.orderKey.sequence.toString()),
                "variants" to array(family.variants.map { variant -> obj("contentKey" to variant.contentKey.hex,
                    "payload" to payloadRecord(variant.payload), "dateBits" to variant.dateBits.hex) }))
        }), "familyDeletes" to array(state.familyDeletes), "variantDeletes" to array(state.variantDeletes.map(::referenceRecord)),
        "chatTombstones" to array(state.chatTombstones))

    /** Called only after exact shape/value coverage checks, never on arbitrary state JSON. */
    private fun coveredState(value: JSONObject): State {
        fun payload(value: JSONObject) = Payload(utf8(unhex(value.getString("projectUTF8"))),
            utf8(unhex(value.getString("roleUTF8"))), utf8(unhex(value.getString("textUTF8"))))
        fun reference(value: JSONObject) = Reference(value.getString("familyID"), ContentKey.fromHex(value.getString("contentKey")), value.getString("projectedID"))
        val families = value.getJSONArray("families")
        return State(value.getString("format"), value.getString("identityScheme"), ChatStateV2.parseCounter(value.getString("orderClock")),
            (0 until families.length()).map { index ->
                val family = families.getJSONObject(index); val order = family.getJSONObject("orderKey"); val variants = family.getJSONArray("variants")
                Family(family.getString("familyID"), ContentKey.fromHex(family.getString("anchorContentKey")),
                    OrderKey(ChatStateV2.parseCounter(order.getString("counter")), order.getString("originID"), order.getString("batchID"), ChatStateV2.parseCounter(order.getString("sequence"))),
                    (0 until variants.length()).map { n -> val variant = variants.getJSONObject(n)
                        Variant(ContentKey.fromHex(variant.getString("contentKey")), payload(variant.getJSONObject("payload")), DateBits.fromHex(variant.getString("dateBits"))) })
            }, strings(value.getJSONArray("familyDeletes")),
            value.getJSONArray("variantDeletes").let { deletes -> (0 until deletes.length()).map { reference(deletes.getJSONObject(it)) } },
            strings(value.getJSONArray("chatTombstones")))
    }

    /** Object key order is irrelevant; every key, value, scalar type and array position is exact. */
    private fun match(received: Any, expected: Any, path: String) {
        when (expected) {
            is JSONObject -> {
                require(received is JSONObject) { "Evidence type mismatch at $path" }
                require(received.keys().asSequence().toSet() == expected.keys().asSequence().toSet()) { "Evidence fields mismatch at $path" }
                for (key in expected.keys()) match(received.get(key), expected.get(key), "$path.$key")
            }
            is JSONArray -> {
                require(received is JSONArray && received.length() == expected.length()) { "Evidence coverage mismatch at $path" }
                for (index in 0 until expected.length()) match(received.get(index), expected.get(index), "$path[$index]")
            }
            is String -> require(received is String && received == expected) { "Evidence value mismatch at $path" }
            else -> error("Unexpected comparison scalar")
        }
    }
    private fun keys(value: JSONObject, expected: Set<String>) = require(value.keys().asSequence().toSet() == expected) { "Missing or extra evidence fields" }
    private fun strings(value: JSONArray) = (0 until value.length()).map { value.getString(it) }
    private fun obj(vararg pairs: Pair<String, Any>) = JSONObject().apply { for ((key, value) in pairs) put(key, value) }
    private fun array(values: Collection<Any>) = JSONArray().apply { for (value in values) put(value) }
    private fun hex(bytes: ByteArray) = bytes.joinToString("") { (it.toInt() and 255).toString(16).padStart(2, '0') }
    private fun unhex(value: String): ByteArray {
        require(value.length % 2 == 0 && value.all { it in '0'..'9' || it in 'a'..'f' }) { "Invalid evidence hex" }
        return ByteArray(value.length / 2) { value.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }
    private fun utf8(bytes: ByteArray): String = try {
        Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
    } catch (_: java.nio.charset.CharacterCodingException) { throw IllegalArgumentException("Invalid evidence UTF-8") }
    private fun error(message: String): Nothing = throw IllegalArgumentException(message)

    /**
     * A bounded JSON grammar for this string-scalar-only evidence format. org.json's
     * permissive object parser also accepts unquoted values and trailing commas, so
     * restrict grammar here and use JSONTokener only for validated string escapes.
     * Reject duplicates before put(), deep nesting and excessive object allocation.
     */
    private class Reader(private val text: String) {
        private var position = 0
        private var nodes = 0
        fun read(): JSONObject {
            val value = value(0)
            whitespace()
            require(position == text.length && value is JSONObject) { "Malformed evidence root or trailing data" }
            return value
        }
        private fun whitespace() { while (position < text.length && text[position] in " \t\r\n") position++ }
        private fun take(char: Char): Boolean {
            whitespace()
            if (position >= text.length || text[position] != char) return false
            position++; return true
        }
        private fun expect(char: Char) { require(take(char)) { "Malformed evidence JSON" } }
        private fun value(depth: Int): Any {
            require(depth <= 32 && ++nodes <= 10000) { "Evidence complexity limit" }
            whitespace()
            require(position < text.length) { "Truncated evidence JSON" }
            return when (text[position]) {
                '"' -> string()
                '{' -> {
                    position++; val result = JSONObject()
                    if (!take('}')) {
                        do {
                            val key = string()
                            require(!result.has(key)) { "Duplicate evidence key" }
                            expect(':'); result.put(key, value(depth + 1))
                            if (take('}')) break
                            expect(',')
                        } while (true)
                    }
                    result
                }
                '[' -> {
                    position++; val result = JSONArray()
                    if (!take(']')) {
                        do {
                            result.put(value(depth + 1))
                            if (take(']')) break
                            expect(',')
                        } while (true)
                    }
                    result
                }
                else -> error("Only string evidence scalars are accepted")
            }
        }
        private fun string(): String {
            whitespace(); val start = position; expect('"')
            while (position < text.length) {
                val char = text[position++]
                require(char.code >= 32) { "Control character in evidence string" }
                if (char == '"') return JSONTokener(text.substring(start, position)).nextValue() as String
                if (char == '\\') {
                    require(position < text.length) { "Truncated evidence escape" }
                    val escaped = text[position++]
                    if (escaped == 'u') {
                        require(position + 4 <= text.length && text.substring(position, position + 4).all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) { "Invalid evidence Unicode escape" }
                        position += 4
                    } else require(escaped in "\"\\/bfnrt") { "Invalid evidence escape" }
                }
            }
            error("Unterminated evidence string")
        }
    }
}
