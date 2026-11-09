package app.asterion.veyra

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.security.MessageDigest

/** Every expected result comes from the checked-in actual Swift attachment. */
class ChatStateV2NativeCorpusTest {
    private fun fixture(): ByteArray = javaClass.getResourceAsStream("/chat-state-v2/native-chat-projections.json")!!.use { stream ->
        val bytes = ByteArray(1024 * 1024 + 1)
        var count = 0
        while (count < bytes.size) {
            val read = stream.read(bytes, count, bytes.size - count)
            if (read == -1) break
            count += read
        }
        require(count <= 1024 * 1024)
        bytes.copyOf(count)
    }
    private fun document() = JSONObject(fixture().toString(Charsets.UTF_8))
    private fun scenario(document: JSONObject, index: Int) = document.getJSONArray("scenarios").getJSONObject(index)
    private fun result(document: JSONObject, scenario: Int, result: Int) = scenario(document, scenario).getJSONArray("results").getJSONObject(result)
    private fun bytes(document: JSONObject) = document.toString().toByteArray(Charsets.UTF_8)
    private fun rejects(raw: ByteArray, reason: String? = null) {
        try { NativeChatCorpus.verify(raw); fail("Divergent or incomplete evidence was accepted") }
        catch (error: IllegalArgumentException) { if (reason != null) assertEquals(reason, error.message) }
    }
    private fun changed(scenarioIndex: Int, resultIndex: Int, path: List<Any>, replacement: Any) {
        val doc = document()
        var target: Any = result(doc, scenarioIndex, resultIndex)
        for (part in path.dropLast(1)) target = if (part is Int) (target as JSONArray).get(part) else (target as JSONObject).get(part as String)
        val last = path.last()
        val old = if (last is Int) (target as JSONArray).get(last) else (target as JSONObject).get(last as String)
        assertNotEquals("Mutation must change the evidence", old, replacement)
        if (last is Int) (target as JSONArray).put(last, replacement) else (target as JSONObject).put(last as String, replacement)
        rejects(bytes(doc))
    }

    @Test fun resourceIsUnchangedNativeAttachment() {
        val raw = fixture()
        assertEquals(158421, raw.size)
        val hash = MessageDigest.getInstance("SHA-256").digest(raw).joinToString("") { "%02x".format(it) }
        assertEquals("e799774a7f823224779cb7fadefa1a3952563a36369e23f15c0210a859f768ca", hash)
    }

    @Test fun allFortyFourActualNativeResultsReplayExactlyInKotlin() {
        assertEquals(44, NativeChatCorpus.verify(fixture()))
    }

    @Test fun everyScenarioInputResultAndGroupingIsRequired() {
        val scenarios = document().getJSONArray("scenarios")
        for (index in 0 until scenarios.length()) {
            val missing = document(); missing.getJSONArray("scenarios").remove(index); rejects(bytes(missing))
            for (field in listOf("inputs", "results")) {
                val count = scenario(document(), index).getJSONArray(field).length()
                for (item in 0 until count) {
                    val changed = document(); scenario(changed, index).getJSONArray(field).remove(item); rejects(bytes(changed))
                }
            }
        }
        for ((field, value) in listOf("format" to "v2", "producer" to "python", "status" to "pending-native-export")) {
            val doc = document(); doc.put(field, value); rejects(bytes(doc))
        }
        val duplicate = document(); duplicate.getJSONArray("scenarios").put(1, scenario(duplicate, 0)); rejects(bytes(duplicate))
        val extra = document(); extra.put("unexpected", "ignored"); rejects(bytes(extra))
        val inputChanged = document(); val inputs = scenario(inputChanged, 2).getJSONArray("inputs")
        inputs.put(1, inputs.getJSONObject(0)); rejects(bytes(inputChanged))
    }

    @Test fun everyResultIsActuallyComparedRatherThanJustCounted() {
        val doc = document().getJSONArray("scenarios")
        for (s in 0 until doc.length()) for (r in 0 until doc.getJSONObject(s).getJSONArray("results").length()) {
            changed(s, r, listOf("state", "orderClock"), "999")
            changed(s, r, listOf("name"), "unverified-result")
        }
    }

    @Test fun everyIdentityPayloadDateAndOrderFieldIsCompared() {
        val changes = listOf(
            listOf("projection", 0, "reference", "familyID") to "00000000-0000-4000-8000-000000000001",
            listOf("projection", 0, "reference", "projectedID") to "00000000-0000-4000-8000-000000000001",
            listOf("projection", 0, "reference", "contentKey") to "00".repeat(32),
            listOf("projection", 0, "payload", "projectUTF8") to "00",
            listOf("projection", 0, "payload", "roleUTF8") to "75736572",
            listOf("projection", 0, "payload", "textUTF8") to "63616665cc81",
            listOf("projection", 0, "dateBits") to "8000000000000000",
            listOf("state", "format") to "v3",
            listOf("state", "identityScheme") to "chat-content-v3",
            listOf("state", "families", 0, "familyID") to "00000000-0000-4000-8000-000000000001",
            listOf("state", "families", 0, "anchorContentKey") to "00".repeat(32),
            listOf("state", "families", 0, "orderKey", "counter") to "2",
            listOf("state", "families", 0, "orderKey", "originID") to "00000000-0000-4000-8000-000000000001",
            listOf("state", "families", 0, "orderKey", "batchID") to "00000000-0000-4000-8000-000000000002",
            listOf("state", "families", 0, "orderKey", "sequence") to "0",
            listOf("state", "families", 0, "variants", 0, "contentKey") to "00".repeat(32),
            listOf("state", "families", 0, "variants", 0, "dateBits") to "0000000000000000",
            listOf("state", "families", 0, "variants", 0, "payload", "textUTF8") to "58")
        for ((path, replacement) in changes) changed(0, 0, path, replacement)
        for (index in 0 until 12) {
            val changed = document(); val rows = result(changed, 1, index).getJSONArray("projection")
            val first = rows.get(0); rows.put(0, rows.get(1)); rows.put(1, first); rejects(bytes(changed))
        }
    }

    @Test fun deletionSelectorsAndPermanentMarkersAreComparedAtEveryStage() {
        for (s in listOf(3, 4)) for (r in 1..3) for (field in listOf("familyDeletes", "variantDeletes", "chatTombstones")) {
            val doc = document(); val markers = result(doc, s, r).getJSONObject("state").getJSONArray(field)
            if (markers.length() > 0) { markers.remove(0); rejects(bytes(doc)) }
        }
        for (field in listOf("familyID", "contentKey", "projectedID")) {
            changed(4, 3, listOf("state", "variantDeletes", 0, field), if (field == "contentKey") "00".repeat(32) else "00000000-0000-4000-8000-000000000001")
        }
        val extra = document(); result(extra, 0, 0).getJSONObject("state").getJSONArray("chatTombstones")
            .put("00000000-0000-4000-8000-000000000001"); rejects(bytes(extra))
    }

    @Test fun wrongTypesNoncanonicalFieldsAndUnknownNestedFieldsFailClosed() {
        for (replacement in listOf<Any>(0, true, JSONObject.NULL, "01", "18446744073709551616")) {
            val doc = document(); scenario(doc, 0).getJSONArray("inputs").getJSONObject(0).put("orderClock", replacement); rejects(bytes(doc))
        }
        for (replacement in listOf<Any>(0, true, JSONObject.NULL, "0", "NaN")) changed(0, 0, listOf("projection", 0, "dateBits"), replacement)
        for (replacement in listOf("c0af", "eda080", "FF", "0")) {
            val doc = document(); scenario(doc, 0).getJSONArray("inputs").getJSONObject(0).getJSONArray("families").getJSONObject(0)
                .getJSONArray("variants").getJSONObject(0).getJSONObject("payload").put("textUTF8", replacement)
            rejects(bytes(doc))
        }
        val extra = document(); result(extra, 0, 0).getJSONArray("projection").getJSONObject(0).put("unexpected", "ignored"); rejects(bytes(extra))
        val empty = document(); result(empty, 0, 0).put("state", JSONObject()).put("projection", JSONArray()); rejects(bytes(empty))
    }

    @Test fun boundedReaderRejectsTruncationDuplicatesInvalidUtf8AndMalformedJson() {
        val raw = fixture()
        for (length in listOf(0, 1, raw.size / 2, raw.size - 1)) rejects(raw.copyOf(length))
        rejects(raw + ByteArray(1024 * 1024 + 1 - raw.size) { 32 }, "Evidence size limit")
        rejects(byteArrayOf(0xff.toByte()), "Invalid evidence UTF-8")
        // Exact reasons ensure an unrelated schema failure cannot mask a removed
        // size/depth/node guard or a parser accepting malformed JSON syntax.
        val malformed = listOf(
            """{"format":"a","format":"b"}""" to "Duplicate evidence key",
            """{"format":"a","for\u006dat":"b"}""" to "Duplicate evidence key",
            """{"value":NaN}""" to "Only string evidence scalars are accepted",
            """{"value":Infinity}""" to "Only string evidence scalars are accepted",
            "[] trailing" to "Malformed evidence root or trailing data",
            "{}{}" to "Malformed evidence root or trailing data",
            """{unquoted:"x"}""" to "Malformed evidence JSON",
            """{"a":"x",}""" to "Malformed evidence JSON",
            """["x",]""" to "Only string evidence scalars are accepted",
            """{"x":"\q"}""" to "Invalid evidence escape",
            """{"x":"\u00"}""" to "Invalid evidence Unicode escape",
            ("[".repeat(40) + "]".repeat(40)) to "Evidence complexity limit",
            ("[" + List(10001) { "\"x\"" }.joinToString(",") + "]") to "Evidence complexity limit")
        for ((text, reason) in malformed) rejects(text.toByteArray(Charsets.UTF_8), reason)
        // These are otherwise complete valid corpus documents. A permissive parser
        // would preserve all values and let replay pass despite invalid JSON syntax.
        val compact = document().toString()
        val duplicate = "{\"format\":\"veyra-chat-state-v2-projection-evidence-v1\"," + compact.drop(1)
        rejects(duplicate.toByteArray(Charsets.UTF_8), "Duplicate evidence key")
        rejects((compact.dropLast(1) + ",}").toByteArray(Charsets.UTF_8), "Malformed evidence JSON")
        val unquotedField = compact.replaceFirst("\"format\":", "format:")
        assertNotEquals(compact, unquotedField)
        rejects(unquotedField.toByteArray(Charsets.UTF_8), "Malformed evidence JSON")
        val unquotedValue = compact.replace("\"status\":\"native-export\"", "\"status\":native-export")
        assertNotEquals(compact, unquotedValue)
        rejects(unquotedValue.toByteArray(Charsets.UTF_8), "Only string evidence scalars are accepted")
    }
}
