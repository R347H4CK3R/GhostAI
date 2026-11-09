package app.asterion.veyra

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.Collections
import java.util.UUID

/**
 * Unused, pure in-memory chat-family foundation. No production call sites, I/O, codec,
 * migration, restoration, mirrors, credentials or writer authorization belong here.
 *
 * This is not the v1 three-way merge. Join laws apply only to compatible normalized
 * states whose intermediate results fit the same limits. Exact outer vault/journal
 * serialization and SavedState limits remain independent future integration gates.
 */
internal object ChatStateV2 {
    private val contentDomain = "Veyra chat content v2\u0000".toByteArray(Charsets.UTF_8)
    private val identityDomain = "Veyra chat variant identity v2\u0000".toByteArray(Charsets.UTF_8)
    private val uuidPattern = Regex("[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}")
    private val counterPattern = Regex("0|[1-9][0-9]{0,19}")

    class Failure(val code: String, val detail: String? = null) : IllegalArgumentException(
        if (detail == null) code else "$code: $detail")

    data class Payload(val project: String, val role: String, val text: String)

    /** Defensive copies avoid ByteArray's mutable/reference-equality map-key semantics. */
    class ContentKey(bytes: ByteArray) : Comparable<ContentKey> {
        private val value = bytes.copyOf().also { if (it.size != 32) throw Failure("invalid_key") }
        val bytes: ByteArray get() = value.copyOf()
        val hex: String get() = hex(value)
        override fun equals(other: Any?): Boolean = other is ContentKey && value.contentEquals(other.value)
        override fun hashCode(): Int = value.contentHashCode()
        override fun toString(): String = hex
        override fun compareTo(other: ContentKey): Int {
            for (index in value.indices) {
                val result = (value[index].toInt() and 255).compareTo(other.value[index].toInt() and 255)
                if (result != 0) return result
            }
            return 0
        }
        companion object { fun fromHex(value: String) = ContentKey(parseHex(value, 32)) }
    }

    /** Raw Foundation-reference IEEE binary64. Never convert through Unix time. */
    data class DateBits(val rawValue: ULong) {
        init {
            val value = Double.fromBits(rawValue.toLong())
            if (!value.isFinite() || value < -978307200.0 || value > 252423993599.0) throw Failure("invalid_date")
        }
        val value: Double get() = Double.fromBits(rawValue.toLong())
        val hex: String get() = rawValue.toString(16).padStart(16, '0')
        companion object {
            fun fromDouble(value: Double) = DateBits(value.toRawBits().toULong())
            fun fromHex(value: String): DateBits = DateBits(ByteBuffer.wrap(parseHex(value, 8)).long.toULong())
            fun minimum(a: DateBits, b: DateBits): DateBits = when {
                a.value < b.value -> a
                b.value < a.value -> b
                a.rawValue <= b.rawValue -> a
                else -> b
            }
        }
    }

    data class OrderKey(val counter: ULong, val originID: String, val batchID: String, val sequence: ULong) : Comparable<OrderKey> {
        override fun compareTo(other: OrderKey): Int {
            // Canonical lowercase UUID spelling has the same order as network bytes.
            // Unlike UUID.compareTo(), this never compares its two longs as signed.
            if (counter != other.counter) return counter.compareTo(other.counter)
            if (originID != other.originID) return originID.compareTo(other.originID)
            if (batchID != other.batchID) return batchID.compareTo(other.batchID)
            return sequence.compareTo(other.sequence)
        }
    }
    data class Variant(val contentKey: ContentKey, val payload: Payload, val dateBits: DateBits)
    data class Family(val familyID: String, val anchorContentKey: ContentKey, val orderKey: OrderKey, val variants: List<Variant>)
    data class Reference(val familyID: String, val contentKey: ContentKey, val projectedID: String) : Comparable<Reference> {
        override fun compareTo(other: Reference): Int {
            if (familyID != other.familyID) return familyID.compareTo(other.familyID)
            if (contentKey != other.contentKey) return contentKey.compareTo(other.contentKey)
            return projectedID.compareTo(other.projectedID)
        }
    }
    data class State(
        val format: String = "veyra-chat-families-v2",
        val identityScheme: String = "chat-content-v2",
        val orderClock: ULong = 0uL,
        val families: List<Family> = emptyList(),
        val familyDeletes: List<String> = emptyList(),
        val variantDeletes: List<Reference> = emptyList(),
        val chatTombstones: List<String> = emptyList())

    data class Limits(
        val maximumLiveVariants: Long = 10000,
        val maximumRecords: Long = 30000,
        val maximumFamilies: Long = 30000,
        val maximumTombstones: Long = 20000,
        val maximumDocumentBytes: Long = 8 * 1024 * 1024,
        val maximumJournalBytes: Long = 17 * 1024 * 1024,
        // Caller reservations for non-chat records and original note marker strings.
        val otherRecords: Long = 0,
        val otherTombstones: Long = 0,
        val otherDocumentBytes: Long = 0,
        val otherJournalBytes: Long = 0)
    data class Usage(val liveVariants: Long, val retainedRoots: Long, val tombstones: Long, val documentBytes: Long, val journalBytes: Long)
    data class Validated(val state: State, val usage: Usage, internal val references: List<Reference>)
    data class Row(val reference: Reference, val payload: Payload, val dateBits: DateBits)
    data class MutationResult(val state: Validated, val addedIDs: Set<String>, val addedVariantDeletes: Set<Reference>,
        val addedFamilyDeletes: Set<String>, val addedTombstones: Set<String>)

    /** Strict primitive only, not a state decoder or a change to the frozen v1 codec. */
    fun parseCounter(value: String): ULong {
        if (!counterPattern.matches(value)) throw Failure("invalid_counter")
        return value.toULongOrNull() ?: throw Failure("invalid_counter")
    }

    class Engine(val limits: Limits = Limits(), private val digest: (ByteArray) -> ByteArray = { MessageDigest.getInstance("SHA-256").digest(it) }) {
        /** TLV uses UTF-8 byte lengths, not UTF-16 units, code points or normalized strings. */
        fun contentBytes(payload: Payload): ByteArray {
            val fields = payloadBytes(payload)
            val output = ByteArrayOutputStream()
            output.write(contentDomain)
            for (raw in fields) {
                output.write(ByteBuffer.allocate(8).putLong(raw.size.toLong()).array())
                output.write(raw)
            }
            return output.toByteArray()
        }
        fun contentKey(payload: Payload) = ContentKey(hash(contentBytes(payload)))
        fun projectedID(familyID: String, anchor: ContentKey, key: ContentKey): String {
            val root = uuidBytes(familyID)
            if (key == anchor) return familyID
            val result = hash(identityDomain + root + key.bytes).copyOfRange(0, 16)
            result[6] = ((result[6].toInt() and 15) or 128).toByte()
            result[8] = ((result[8].toInt() and 63) or 128).toByte()
            val buffer = ByteBuffer.wrap(result)
            return UUID(buffer.long, buffer.long).toString()
        }
        private fun hash(bytes: ByteArray): ByteArray {
            val result = digest(bytes)
            if (result.size != 32) throw Failure("invalid_hash_length")
            return result.copyOf()
        }
        private fun reference(family: Family, key: ContentKey) = Reference(family.familyID, key,
            projectedID(family.familyID, family.anchorContentKey, key))

        /**
         * Validate every supplied body before deletion can hide collisions or invalid facts.
         * Lists expose duplicate facts to validation; successful states use immutable snapshots.
         * Bare chat markers fail instead of guessing deletion scope. Note markers stay outside.
         */
        fun validate(input: State): Validated {
            validateLimits()
            if (input.format != "veyra-chat-families-v2" || input.identityScheme != "chat-content-v2") throw Failure("unsupported_epoch")
            val families = linkedMapOf<String, Family>()
            var clock = input.orderClock
            for (family in input.families) {
                uuidBytes(family.familyID); uuidBytes(family.orderKey.originID); uuidBytes(family.orderKey.batchID)
                if (families.put(family.familyID, family) != null) throw Failure("duplicate_family", family.familyID)
                clock = maxOf(clock, family.orderKey.counter)
            }
            for (id in input.familyDeletes + input.chatTombstones) uuidBytes(id)
            for (selector in input.variantDeletes) { uuidBytes(selector.familyID); uuidBytes(selector.projectedID) }
            val familyDeletes = input.familyDeletes.toSet()
            val tombstones = input.chatTombstones.toMutableSet()
            val selectors = input.variantDeletes.toMutableSet()
            if (familyDeletes.size != input.familyDeletes.size || tombstones.size != input.chatTombstones.size) throw Failure("duplicate_marker")
            if (selectors.size != input.variantDeletes.size) throw Failure("duplicate_selector")
            val roots = families.keys + familyDeletes
            val owners = mutableMapOf<String, Reference>()
            val payloads = mutableMapOf<ContentKey, Payload>()
            fun register(ref: Reference) {
                val family = families[ref.familyID] ?: throw Failure("unknown_family", ref.familyID)
                if (ref != reference(family, ref.contentKey)) throw Failure("incorrect_projected_id", ref.projectedID)
                val isAnchor = ref.projectedID == family.familyID && ref.contentKey == family.anchorContentKey
                if (ref.projectedID in roots && !isAnchor) throw Failure("identifier_collision", ref.projectedID)
                val previous = owners.put(ref.projectedID, ref)
                if (previous != null && previous != ref) throw Failure("identifier_collision", ref.projectedID)
            }
            for (selector in selectors) register(selector)
            if (tombstones != familyDeletes + selectors.map { it.projectedID }) throw Failure("unexplained_or_missing_tombstone")
            for (family in input.families) {
                val keys = mutableSetOf<ContentKey>()
                for (variant in family.variants) {
                    if (!keys.add(variant.contentKey)) throw Failure("duplicate_variant", family.familyID)
                    if (contentKey(variant.payload) != variant.contentKey) throw Failure("payload_key_mismatch", variant.contentKey.hex)
                    val previous = payloads.put(variant.contentKey, variant.payload)
                    if (previous != null && previous != variant.payload) throw Failure("content_collision", variant.contentKey.hex)
                    register(reference(family, variant.contentKey))
                }
                if (family.anchorContentKey !in keys && family.familyID !in familyDeletes && reference(family, family.anchorContentKey) !in selectors) {
                    throw Failure("missing_anchor", family.familyID)
                }
            }
            val normalizedFamilies = input.families.map { family ->
                val remaining = family.variants.filter { variant ->
                    val ref = reference(family, variant.contentKey)
                    if (family.familyID in familyDeletes) { selectors.add(ref); tombstones.add(ref.projectedID) }
                    ref !in selectors
                }.sortedBy { it.contentKey }
                family.copy(variants = frozen(remaining))
            }.sortedBy { it.familyID }
            val normalized = State(orderClock = clock, families = frozen(normalizedFamilies),
                familyDeletes = frozen(familyDeletes.sorted()), variantDeletes = frozen(selectors.sorted()), chatTombstones = frozen(tombstones.sorted()))
            return Validated(normalized, preflight(normalized), frozen(normalized.families.flatMap { f -> f.variants.map { reference(f, it.contentKey) } }))
        }

        fun join(a: Validated, b: Validated): Validated {
            val left = checked(a).state; val right = checked(b).state
            val combined = left.families.associateBy { it.familyID }.toMutableMap()
            // Descriptor conflicts are errors, never original-ID winner selection.
            for (family in right.families) {
                val existing = combined[family.familyID]
                if (existing != null && existing.anchorContentKey != family.anchorContentKey) throw Failure("anchor_conflict", family.familyID)
            }
            for (family in right.families) {
                val previous = combined[family.familyID]
                if (previous == null) { combined[family.familyID] = family; continue }
                val variants = previous.variants.associateBy { it.contentKey }.toMutableMap()
                for (variant in family.variants) {
                    val existing = variants[variant.contentKey]
                    if (existing != null && existing.payload != variant.payload) throw Failure("content_collision", variant.contentKey.hex)
                    variants[variant.contentKey] = if (existing == null) variant else variant.copy(dateBits = DateBits.minimum(existing.dateBits, variant.dateBits))
                }
                combined[family.familyID] = family.copy(orderKey = minOf(previous.orderKey, family.orderKey), variants = variants.values.toList())
            }
            return validate(State(orderClock = maxOf(left.orderClock, right.orderClock), families = combined.values.toList(),
                familyDeletes = (left.familyDeletes + right.familyDeletes).distinct(),
                variantDeletes = (left.variantDeletes + right.variantDeletes).distinct(),
                chatTombstones = (left.chatTombstones + right.chatTombstones).distinct()))
        }

        /** Projection is presentation only; a source sequence never becomes ordering facts. */
        fun project(value: Validated): List<Row> = frozen(projectState(checked(value).state))
        private fun projectState(state: State): List<Row> = state.families
            .sortedWith(compareBy<Family> { it.orderKey }.thenBy { it.familyID })
            .flatMap { family -> family.variants.sortedWith(compareBy<Variant> { it.contentKey != family.anchorContentKey }.thenBy { it.contentKey })
                .map { Row(reference(family, it.contentKey), it.payload, it.dateBits) } }

        fun newOrderBatch(clock: ULong, origin: String, persistedBatch: String, count: Int): List<OrderKey> {
            validateLimits(); uuidBytes(origin); uuidBytes(persistedBatch)
            if (count <= 0 || count.toLong() > limits.maximumLiveVariants) throw Failure("capacity_order_batch")
            if (clock == ULong.MAX_VALUE) throw Failure("capacity_order_clock")
            return frozen(List(count) { OrderKey(clock + 1uL, origin, persistedBatch, it.toULong()) })
        }

        fun observe(value: Validated, familyID: String, payload: Payload, originalDateBits: DateBits): MutationResult {
            val before = checked(value); uuidBytes(familyID)
            val family = before.state.families.find { it.familyID == familyID } ?: throw Failure("unknown_family", familyID)
            val key = contentKey(payload)
            val variants = family.variants.associateBy { it.contentKey }.toMutableMap()
            val previous = variants[key]
            if (previous != null && previous.payload != payload) throw Failure("content_collision", key.hex)
            val date = if (previous == null) originalDateBits else DateBits.minimum(previous.dateBits, originalDateBits)
            variants[key] = Variant(key, payload, date)
            val changed = family.copy(variants = variants.values.toList())
            return mutation(before, validate(before.state.copy(families = before.state.families.map { if (it.familyID == familyID) changed else it })))
        }

        fun deleteVariants(value: Validated, references: Set<Reference>): MutationResult {
            val before = checked(value)
            val known = (projectState(before.state).map { it.reference } + before.state.variantDeletes).toSet()
            for (ref in references) {
                uuidBytes(ref.familyID); uuidBytes(ref.projectedID)
                if (ref !in known) throw Failure("unknown_reference", ref.projectedID)
            }
            return mutation(before, validate(before.state.copy(
                variantDeletes = (before.state.variantDeletes + references).distinct(),
                chatTombstones = (before.state.chatTombstones + references.map { it.projectedID }).distinct())))
        }

        fun deleteFamilies(value: Validated, familyIDs: Set<String>): MutationResult {
            val before = checked(value)
            val known = before.state.families.map { it.familyID }.toSet() + before.state.familyDeletes
            for (id in familyIDs) { uuidBytes(id); if (id !in known) throw Failure("unknown_family", id) }
            return mutation(before, validate(before.state.copy(
                familyDeletes = (before.state.familyDeletes + familyIDs).distinct(),
                chatTombstones = (before.state.chatTombstones + familyIDs).distinct())))
        }

        private fun mutation(before: Validated, after: Validated): MutationResult {
            val old = before.state; val new = after.state
            val oldIDs = projectState(old).map { it.reference.projectedID }.toSet()
            return MutationResult(after, frozenSet(projectState(new).map { it.reference.projectedID }.toSet() - oldIDs),
                frozenSet(new.variantDeletes.toSet() - old.variantDeletes.toSet()),
                frozenSet(new.familyDeletes.toSet() - old.familyDeletes.toSet()),
                frozenSet(new.chatTombstones.toSet() - old.chatTombstones.toSet()))
        }
        private fun checked(value: Validated): Validated {
            // A Kotlin data-class copy is constructible, and engines can have different
            // limits/hash contexts. Never treat the wrapper as an authority token.
            val verified = validate(value.state)
            if (value.references != verified.references) throw Failure("validation_context_mismatch")
            return verified
        }
        private fun validateLimits() {
            if (listOf(limits.maximumLiveVariants, limits.maximumRecords, limits.maximumFamilies, limits.maximumTombstones,
                    limits.maximumDocumentBytes, limits.maximumJournalBytes, limits.otherRecords, limits.otherTombstones,
                    limits.otherDocumentBytes, limits.otherJournalBytes).any { it < 0 }) throw Failure("invalid_limits")
        }
        /**
         * Conservative chat-only accounting, NOT serialization or an outer wire-size proof.
         * Six bytes per UTF-8 byte cover JSON escapes. Fixed allowances cover field names,
         * punctuation, UUID/hash/date spellings and 20-digit counters. Journal allows two
         * chat-state copies. A future codec must check actual complete serialized sizes.
         */
        private fun preflight(state: State): Usage {
            var live = 0L
            var size = add(512, multiply(384, state.families.size.toLong()))
            for (family in state.families) for (variant in family.variants) {
                live = add(live, 1)
                val rawBytes = payloadBytes(variant.payload).fold(0L) { sum, bytes -> add(sum, bytes.size.toLong()) }
                size = add(size, add(256, multiply(6, rawBytes)))
            }
            size = add(size, multiply(192, state.variantDeletes.size.toLong()))
            size = add(size, multiply(40, add(state.familyDeletes.size.toLong(), state.chatTombstones.size.toLong())))
            val roots = (state.families.map { it.familyID }.toSet() + state.familyDeletes).size.toLong()
            val markers = add(state.chatTombstones.size.toLong(), limits.otherTombstones)
            val document = add(size, limits.otherDocumentBytes)
            val journal = add(multiply(2, size), limits.otherJournalBytes)
            fun bound(actual: Long, maximum: Long, name: String) {
                if (actual > maximum) throw Failure("capacity_$name", "required=$actual maximum=$maximum")
            }
            bound(live, limits.maximumLiveVariants, "live_variants")
            bound(add(live, limits.otherRecords), limits.maximumRecords, "records")
            bound(roots, limits.maximumFamilies, "families")
            bound(markers, limits.maximumTombstones, "tombstones")
            bound(document, limits.maximumDocumentBytes, "document_bytes")
            bound(journal, limits.maximumJournalBytes, "journal_bytes")
            return Usage(live, roots, markers, document, journal)
        }
    }

    private fun uuidBytes(value: String): ByteArray {
        if (!uuidPattern.matches(value)) throw Failure("invalid_uuid")
        val uuid = UUID.fromString(value)
        return ByteBuffer.allocate(16).putLong(uuid.mostSignificantBits).putLong(uuid.leastSignificantBits).array()
    }
    private fun payloadBytes(payload: Payload): List<ByteArray> {
        if (payload.role != "user" && payload.role != "assistant") throw Failure("invalid_payload")
        return listOf(payload.project, payload.role, payload.text).map { value ->
            try {
                // String.toByteArray() silently replaces unpaired surrogates on the JVM.
                val buffer = Charsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).encode(CharBuffer.wrap(value))
                ByteArray(buffer.remaining()).also { buffer.get(it) }
            } catch (_: CharacterCodingException) { throw Failure("invalid_utf8") }
        }
    }
    private fun parseHex(value: String, count: Int): ByteArray {
        if (value.length != count * 2 || value.any { it !in '0'..'9' && it !in 'a'..'f' }) throw Failure("invalid_hex")
        return ByteArray(count) { value.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }
    private fun hex(value: ByteArray): String = value.joinToString("") { (it.toInt() and 255).toString(16).padStart(2, '0') }
    private fun <T> frozen(values: Collection<T>): List<T> = Collections.unmodifiableList(ArrayList(values))
    private fun <T> frozenSet(values: Collection<T>): Set<T> = Collections.unmodifiableSet(LinkedHashSet(values))
    private fun add(a: Long, b: Long): Long = try { Math.addExact(a, b) } catch (_: ArithmeticException) { throw Failure("capacity_arithmetic") }
    private fun multiply(a: Long, b: Long): Long = try { Math.multiplyExact(a, b) } catch (_: ArithmeticException) { throw Failure("capacity_arithmetic") }
}
