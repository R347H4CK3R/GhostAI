package app.asterion.veyra

import app.asterion.veyra.ChatStateV2.ContentKey
import app.asterion.veyra.ChatStateV2.DateBits
import app.asterion.veyra.ChatStateV2.Engine
import app.asterion.veyra.ChatStateV2.Failure
import app.asterion.veyra.ChatStateV2.Family
import app.asterion.veyra.ChatStateV2.Limits
import app.asterion.veyra.ChatStateV2.OrderKey
import app.asterion.veyra.ChatStateV2.Payload
import app.asterion.veyra.ChatStateV2.State
import app.asterion.veyra.ChatStateV2.Validated
import app.asterion.veyra.ChatStateV2.Variant
import org.junit.Assert.*
import org.junit.Test
import java.security.MessageDigest
import java.util.UUID
import kotlin.random.Random

/** Synthetic v2 fixtures. These are not v1/Foundation JSON golden vectors. */
class ChatStateV2Test {
    private val engine = Engine()
    private val root = "abcdef01-2345-4abc-8def-0123456789ab"
    private val origin = "00000000-0000-4000-8000-000000000001"
    private val batch = "00000000-0000-4000-8000-000000000002"
    private fun payload(text: String = "X", project: String = "General", role: String = "user") = Payload(project, role, text)
    private fun variant(text: String = "X", date: Double = 100.0, project: String = "General", using: Engine = engine): Variant {
        val p = payload(text, project)
        return Variant(using.contentKey(p), p, DateBits.fromDouble(date))
    }
    private fun order(sequence: ULong = 0uL, counter: ULong = 0uL, o: String = origin, b: String = batch) = OrderKey(counter, o, b, sequence)
    private fun family(variants: List<Variant> = listOf(variant()), id: String = root, anchor: String = "X", key: OrderKey = order(), using: Engine = engine) =
        Family(id, using.contentKey(payload(anchor)), key, variants)
    private fun state(variants: List<Variant> = listOf(variant()), key: OrderKey = order()) = engine.validate(State(families = listOf(family(variants, key = key))))
    private fun rejects(code: String, block: () -> Unit) {
        try { block(); fail("Expected $code") } catch (error: Failure) { assertEquals(code, error.code) }
    }
    private fun permutations(values: List<Validated>) = listOf(
        listOf(values[0], values[1], values[2]), listOf(values[0], values[2], values[1]),
        listOf(values[1], values[0], values[2]), listOf(values[1], values[2], values[0]),
        listOf(values[2], values[0], values[1]), listOf(values[2], values[1], values[0]))
    private fun laws(states: List<Validated>): Validated {
        val expected = engine.join(engine.join(states[0], states[1]), states[2])
        for ((a, b, c) in permutations(states)) {
            assertEquals(expected, engine.join(engine.join(a, b), c))
            assertEquals(expected, engine.join(a, engine.join(b, c)))
        }
        assertEquals(expected, engine.join(expected, expected))
        val empty = engine.validate(State())
        assertEquals(expected, engine.join(expected, empty))
        assertEquals(expected, engine.join(empty, expected))
        assertEquals(expected, engine.validate(expected.state))
        return expected
    }

    @Test fun literalTlvAndFourSha256UuidVectors() {
        val vectors = listOf(
            Triple(payload(), "58b32ca7a34840dc3a7ef370534b1b810e1a6f4efd831a053c88218534a6c25f", "cca7cac2-8201-8b3b-8033-078c6bea66a1"),
            Triple(payload("café", role = "assistant"), "c0bd1ba711785726140ddee8c7b4af34c8d0b4379ac08c2952ae2c600996bed4", "f05d9b78-64a6-83ab-a1e8-5c0e0ef25bc1"),
            Triple(payload("cafe\u0301", role = "assistant"), "0a9f819d4fad98d8134e23f16f7ff61ebd0f79e9f9f401bc59491da268125e72", "92401135-eeab-8a56-8a2e-8f2ca559b2b0"),
            Triple(payload("\u0000😀\n", "😀"), "8cba91f3e0fec54203843d059b1612c433b07ddaa385b3417ccd95ebdbb87beb", "dce58054-07f4-8e60-9983-72dfe56518e1"))
        assertEquals("5665797261206368617420636f6e74656e7420763200000000000000000747656e6572616c" +
            "000000000000000475736572000000000000000158", engine.contentBytes(payload()).joinToString("") { "%02x".format(it) })
        for ((p, hash, id) in vectors) {
            val key = engine.contentKey(p)
            assertEquals(hash, key.hex)
            assertEquals(root, engine.projectedID(root, key, key))
            assertEquals(id, engine.projectedID(root, ContentKey(ByteArray(32)), key))
            assertEquals(8, UUID.fromString(id).version())
            assertEquals(2, UUID.fromString(id).variant())
        }
    }

    @Test fun exactUtf8FieldsAndTlvBoundariesNeverFold() {
        val values = listOf(payload("bc", "a"), payload("c", "ab"), payload("bc", "a", "assistant"),
            payload("X", "é"), payload("X", "e\u0301"), payload("é"), payload("e\u0301"),
            payload(" X\r\n", " General "), payload("X\n"), payload("\u0000"))
        assertEquals(values.size, values.map(engine::contentKey).toSet().size)
        assertEquals(32, engine.contentKey(payload("", "")).bytes.size)
        for (p in listOf(payload("\uD800"), payload("X", "\uDC00"), payload(role = "system"), payload(role = "User"))) {
            rejects(if (p.role == "user") "invalid_utf8" else "invalid_payload") { engine.contentKey(p) }
        }
        // Kotlin prohibits null fields; callers from Java/reflection must also fail at construction.
        val constructor = Payload::class.java.getConstructor(String::class.java, String::class.java, String::class.java)
        for (index in 0..2) {
            val args = arrayOf<String?>("General", "user", "X"); args[index] = null
            try { constructor.newInstance(*args); fail("Null payload field accepted") }
            catch (e: java.lang.reflect.InvocationTargetException) { assertTrue(e.cause is NullPointerException) }
        }
    }

    @Test fun strictPrimitiveLengthsCanonicalUuidAndUnsignedCounters() {
        for (length in listOf(0, 31, 33)) rejects("invalid_key") { ContentKey(ByteArray(length)) }
        for (hex in listOf("", "0".repeat(63), "G".repeat(64), "A".repeat(64))) rejects("invalid_hex") { ContentKey.fromHex(hex) }
        for (id in listOf(root.uppercase(), root.replace("-", ""), "{$root}", " $root", "1-1-1-1-1")) {
            rejects("invalid_uuid") { engine.projectedID(id, ContentKey(ByteArray(32)), ContentKey(ByteArray(32))) }
        }
        for (counter in listOf("", "00", "+1", "-1", "1.0", "1e0", " 1", "١", "18446744073709551616")) {
            rejects("invalid_counter") { ChatStateV2.parseCounter(counter) }
        }
        assertEquals(0uL, ChatStateV2.parseCounter("0"))
        assertEquals(ULong.MAX_VALUE, ChatStateV2.parseCounter("18446744073709551615"))
        for (size in listOf(0, 31, 33)) rejects("invalid_hash_length") { Engine(digest = { ByteArray(size) }).contentKey(payload()) }
    }

    @Test fun referenceDateBitsPreserveSignedZeroSubnormalAndNextUp() {
        for (value in listOf(-978307200.0, 252423993599.0, -0.0, 0.0, -0.5, Double.MIN_VALUE, -Double.MIN_VALUE, Math.nextUp(1.0))) {
            val bits = DateBits.fromDouble(value)
            assertEquals(value.toRawBits().toULong(), bits.rawValue)
            assertEquals(bits, DateBits.minimum(bits, bits))
            assertEquals(bits, DateBits.fromHex(bits.hex))
        }
        val minus = DateBits.fromDouble(-0.0); val plus = DateBits.fromDouble(0.0)
        assertEquals("8000000000000000", minus.hex)
        assertEquals(plus, DateBits.minimum(minus, plus)); assertEquals(plus, DateBits.minimum(plus, minus))
        assertEquals(DateBits.fromDouble(-Double.MIN_VALUE), DateBits.minimum(DateBits.fromDouble(-Double.MIN_VALUE), minus))
        assertEquals(DateBits.fromDouble(721692800.0), DateBits.minimum(DateBits.fromDouble(Math.nextUp(721692800.0)), DateBits.fromDouble(721692800.0)))
        for (bad in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, Math.nextDown(-978307200.0), Math.nextUp(252423993599.0))) {
            rejects("invalid_date") { DateBits.fromDouble(bad) }
        }
        for (bad in listOf("", "0".repeat(15), "0".repeat(17), "F".repeat(16))) rejects("invalid_hex") { DateBits.fromHex(bad) }
    }

    @Test fun x100X200Y150EveryGroupingRetainsExactlyTwoStableIds() {
        val a = state(listOf(variant("X", 100.0)))
        val b = state(listOf(variant("X", 200.0)))
        val c = state(listOf(variant("X", 200.0), variant("Y", 150.0)))
        val result = laws(listOf(a, b, c)); val rows = engine.project(result)
        assertEquals(listOf("X", "Y"), rows.map { it.payload.text })
        assertEquals(listOf(DateBits.fromDouble(100.0), DateBits.fromDouble(150.0)), rows.map { it.dateBits })
        assertEquals(root, rows[0].reference.projectedID)
        assertEquals(engine.project(c)[1].reference, rows[1].reference)
        assertEquals(result, engine.join(engine.validate(engine.join(b, c).state), a))
        val anchoredY = engine.validate(State(families = listOf(family(listOf(variant("Y", 150.0), variant("X", 200.0)), anchor = "Y"))))
        val changed = engine.observe(anchoredY, root, payload(), DateBits.fromDouble(100.0)).state
        assertEquals("Y", engine.project(changed).first().payload.text)
        assertEquals(engine.project(anchoredY).map { it.reference }, engine.project(changed).map { it.reference })
    }

    @Test fun oldSourceOrderCounterexampleUsesEstablishedKeysNotInputSequence() {
        val id0 = "00000000-0000-0000-0000-000000000000"; val id1 = "00000000-0000-0000-0000-000000000001"
        val f0 = family(id = id0, key = order(0uL)); val f1 = family(id = id1, key = order(1uL))
        val result = laws(listOf(engine.validate(State(families = listOf(f0))), engine.validate(State(families = listOf(f1))), engine.validate(State(families = listOf(f1, f0)))))
        assertEquals(listOf(id0, id1), engine.project(result).map { it.reference.projectedID })
        val observed = engine.observe(result, id1, payload(), DateBits.fromDouble(1.0)).state
        assertEquals(listOf(id0, id1), engine.project(observed).map { it.reference.projectedID })
    }

    @Test fun orderMinimumIsWholeTupleAndClockRetainsLosingMaximum() {
        val low = order(99uL, 1uL, batch, origin); val high = order(0uL, 2uL)
        val result = laws(listOf(state(key = low), state(key = high), state(key = order(5uL, 7uL))))
        assertEquals(low, result.state.families.single().orderKey); assertEquals(7uL, result.state.orderClock)
        assertEquals(listOf(order(0uL, 8uL), order(1uL, 8uL)), engine.newOrderBatch(7uL, origin, batch, 2))
        val unsigned = state(key = order(ULong.MAX_VALUE, ULong.MAX_VALUE))
        assertEquals(ULong.MAX_VALUE, engine.join(result, unsigned).state.orderClock)
        rejects("capacity_order_clock") { engine.newOrderBatch(ULong.MAX_VALUE, origin, batch, 1) }
        for (count in listOf(-1, 0, 10001)) rejects("capacity_order_batch") { engine.newOrderBatch(0uL, origin, batch, count) }
        val highOrigin = "80000000-0000-0000-0000-000000000000"
        val lowerOrigin = "7fffffff-ffff-ffff-ffff-ffffffffffff"
        assertTrue(order(o = lowerOrigin) < order(o = highOrigin))
        assertTrue(order(b = lowerOrigin) < order(b = highOrigin))
        assertTrue(order(0uL) < order(ULong.MAX_VALUE))
        assertTrue(order(counter = 0uL) < order(counter = ULong.MAX_VALUE))
    }

    @Test fun unrelatedLegacyOriginalConflictAndRestorationRootsAreNeverDeduplicated() {
        val ids = listOf(root, "b1fbeefd-3dd1-5f9a-b0a9-103d1e093175", "deafbeef-0000-5000-8000-000000000000")
        var current = engine.validate(State(families = ids.mapIndexed { i, id -> family(id = id, key = order(i.toULong())) }.reversed()))
        assertEquals(ids, engine.project(current).map { it.reference.projectedID })
        for (p in listOf(payload("é"), payload("e\u0301"), payload("X", "é"), payload("X", "e\u0301"), payload(role = "assistant"))) {
            current = engine.observe(current, root, p, DateBits.fromDouble(100.0)).state
        }
        assertEquals(8, engine.project(current).size)
    }

    @Test fun dateOnlyReplaysNeverGrowStateAndProjectedBytesStayExact() {
        val initial = state(listOf(variant(date = -0.0)))
        assertEquals("8000000000000000", engine.project(initial).single().dateBits.hex)
        val change = engine.observe(initial, root, payload(), DateBits.fromDouble(0.0))
        assertTrue(change.addedIDs.isEmpty()); assertEquals("0000000000000000", engine.project(change.state).single().dateBits.hex)
        var current = change.state
        repeat(20) { current = engine.observe(current, root, payload(), DateBits.fromDouble(it.toDouble())).state }
        assertEquals(change.state, current)
        assertEquals(payload(), engine.project(current).single().payload)
    }

    @Test fun selectiveAnchorDeletionNeverPromotesSiblingAndNeverResurrects() {
        val before = state(listOf(variant(), variant("Y", 150.0)))
        val rows = engine.project(before); val anchor = rows[0].reference; val sibling = rows[1].reference
        val deleted = engine.deleteVariants(before, setOf(anchor))
        assertEquals(setOf(anchor), deleted.addedVariantDeletes); assertEquals(setOf(root), deleted.addedTombstones)
        assertEquals(listOf(sibling), engine.project(deleted.state).map { it.reference })
        assertTrue(deleted.addedFamilyDeletes.isEmpty())
        val older = engine.observe(before, root, payload(), DateBits.fromDouble(1.0)).state
        val result = laws(listOf(before, older, deleted.state))
        assertEquals(listOf(sibling), engine.project(result).map { it.reference })
        assertEquals(result, engine.observe(result, root, payload(), DateBits.fromDouble(300.0)).state)
        assertEquals(result, engine.deleteVariants(result, setOf(anchor)).state)
    }

    @Test fun selectiveCopyDeletionAndExactProjectClearDoNotDeleteOtherPayloads() {
        val before = state(listOf(variant(), variant("Y", 150.0, "Other"), variant("Z", 200.0)))
        val selected = engine.project(before).filter { it.payload.project == "General" }.map { it.reference }.toSet()
        val after = engine.deleteVariants(before, selected).state
        assertEquals(listOf("Other"), engine.project(after).map { it.payload.project })
        assertEquals(after, engine.join(after, before))
        assertEquals(before, engine.deleteVariants(before, emptySet()).state)
        assertEquals(before, engine.join(before, engine.validate(State())))
        val sibling = engine.project(before).first { it.payload.text == "Y" }.reference
        val copyDeleted = engine.deleteVariants(before, setOf(sibling)).state
        assertFalse(engine.project(engine.join(copyDeleted, before)).any { it.reference == sibling })
        rejects("unknown_reference") { engine.deleteVariants(before, setOf(sibling.copy(projectedID = root))) }
    }

    @Test fun familyBarrierRetainsEveryObservedMarkerIncludingFutureVariants() {
        val before = state(listOf(variant(), variant("Y")))
        val deleted = engine.deleteFamilies(before, setOf(root))
        assertTrue(engine.project(deleted.state).isEmpty())
        assertEquals(2, deleted.addedVariantDeletes.size); assertEquals(setOf(root), deleted.addedFamilyDeletes)
        val later = engine.observe(before, root, payload("Z"), DateBits.fromDouble(50.0)).state
        val result = laws(listOf(before, deleted.state, later))
        assertTrue(engine.project(result).isEmpty()); assertEquals(3, result.state.variantDeletes.size)
        assertEquals(3, result.state.chatTombstones.size); assertEquals(1, result.state.families.size)
        assertEquals(result, engine.observe(result, root, payload("Z"), DateBits.fromDouble(1.0)).state)
        assertEquals(result, engine.deleteFamilies(result, setOf(root)).state)
        val barrier = engine.validate(State(familyDeletes = listOf(root), chatTombstones = listOf(root)))
        assertTrue(engine.project(engine.join(barrier, later)).isEmpty())
        rejects("unknown_family") { engine.deleteFamilies(before, setOf(origin)) }
    }

    @Test fun missingAnchorsAndUnexplainedMarkersFailClosed() {
        rejects("missing_anchor") { engine.validate(State(families = listOf(family(emptyList())))) }
        rejects("unexplained_or_missing_tombstone") { engine.validate(State(chatTombstones = listOf(root))) }
        rejects("unexplained_or_missing_tombstone") { engine.validate(State(familyDeletes = listOf(root))) }
        val anchor = engine.project(state()).single().reference
        rejects("unexplained_or_missing_tombstone") { engine.validate(State(families = listOf(family()), variantDeletes = listOf(anchor))) }
        rejects("unknown_family") { engine.validate(State(variantDeletes = listOf(anchor), chatTombstones = listOf(root))) }
        val valid = engine.validate(State(families = listOf(family(emptyList())), variantDeletes = listOf(anchor), chatTombstones = listOf(root)))
        assertTrue(engine.project(valid).isEmpty()); assertEquals(1L, valid.usage.retainedRoots)
    }

    @Test fun duplicateAndMalformedMetadataAreRejectedBeforeNormalization() {
        val f = family(); val anchor = engine.project(state()).single().reference
        rejects("unsupported_epoch") { engine.validate(State(format = "v3")) }
        rejects("unsupported_epoch") { engine.validate(State(identityScheme = "chat-content-v3")) }
        rejects("duplicate_family") { engine.validate(State(families = listOf(f, f))) }
        rejects("duplicate_variant") { engine.validate(State(families = listOf(f.copy(variants = f.variants + f.variants)))) }
        rejects("duplicate_marker") { engine.validate(State(familyDeletes = listOf(root, root), chatTombstones = listOf(root))) }
        rejects("duplicate_marker") { engine.validate(State(familyDeletes = listOf(root), chatTombstones = listOf(root, root))) }
        rejects("duplicate_selector") { engine.validate(State(families = listOf(f), variantDeletes = listOf(anchor, anchor), chatTombstones = listOf(root))) }
        rejects("incorrect_projected_id") { engine.validate(State(families = listOf(f), variantDeletes = listOf(anchor.copy(projectedID = origin)), chatTombstones = listOf(origin))) }
        val wrongBody = f.copy(variants = listOf(variant().copy(payload = payload("Wrong"))))
        rejects("payload_key_mismatch") { engine.validate(State(families = listOf(wrongBody), familyDeletes = listOf(root), chatTombstones = listOf(root))) }
        rejects("invalid_uuid") { engine.validate(State(families = listOf(f.copy(orderKey = order(o = root.uppercase()))))) }
    }

    @Test fun incompatibleAnchorsFailWithoutChangingInputs() {
        val a = state(); val b = engine.validate(State(families = listOf(family(listOf(variant("Y")), anchor = "Y"))))
        val snapshots = listOf(a, b)
        rejects("anchor_conflict") { engine.join(a, b) }; rejects("anchor_conflict") { engine.join(b, a) }
        assertEquals(snapshots, listOf(a, b)); assertEquals("X", engine.project(a).single().payload.text)
    }

    @Test fun injectedContentCollisionIsRejectedWithinAndAcrossFamiliesAndJoins() {
        val collision = Engine(digest = { ByteArray(32) })
        val x = variant(using = collision); val y = variant("Y", using = collision)
        rejects("duplicate_variant") { collision.validate(State(families = listOf(family(listOf(x, y), using = collision)))) }
        val fx = family(listOf(x), using = collision); val fy = family(listOf(y), id = origin, anchor = "Y", using = collision)
        rejects("content_collision") { collision.validate(State(families = listOf(fx, fy))) }
        val a = collision.validate(State(families = listOf(fx))); val b = collision.validate(State(families = listOf(fy)))
        rejects("content_collision") { collision.join(a, b) }
        rejects("content_collision") { collision.observe(a, root, payload("Y"), DateBits.fromDouble(1.0)) }
    }

    private fun forcedIdentity(id: String): Engine = Engine(digest = { bytes ->
        if (bytes.take(31).toByteArray().toString(Charsets.UTF_8) == "Veyra chat variant identity v2\u0000") {
            val uuid = UUID.fromString(id); val buffer = java.nio.ByteBuffer.allocate(32)
            buffer.putLong(uuid.mostSignificantBits).putLong(uuid.leastSignificantBits).array()
        } else MessageDigest.getInstance("SHA-256").digest(bytes)
    })

    @Test fun injectedProjectedIdCollisionsRejectRootsDerivedIdsAndReservedMarkers() {
        val target = "00000000-0000-8000-8000-000000000010"
        val collide = forcedIdentity(target)
        val f = family(listOf(variant(), variant("Y")))
        rejects("identifier_collision") { collide.validate(State(families = listOf(f, family(id = target)))) }
        rejects("identifier_collision") { collide.validate(State(families = listOf(f), familyDeletes = listOf(target), chatTombstones = listOf(target))) }
        rejects("identifier_collision") { collide.validate(State(families = listOf(family(listOf(variant(), variant("Y"), variant("Z")))))) }
        val a = collide.validate(State(families = listOf(f)))
        val deleted = collide.deleteVariants(a, setOf(collide.project(a).last().reference)).state
        rejects("identifier_collision") { collide.observe(deleted, root, payload("Z"), DateBits.fromDouble(3.0)) }
        rejects("identifier_collision") { forcedIdentity(root.replace("4abc", "8abc")).validate(State(families = listOf(f.copy(familyID = root.replace("4abc", "8abc"))))) }
    }

    @Test fun keysAndValidatedCollectionsCannotBeChangedThroughCallerAliases() {
        val bytes = ByteArray(32) { 1 }; val key = ContentKey(bytes); bytes[0] = 9
        assertEquals(1, key.bytes[0].toInt()); val exposed = key.bytes; exposed[0] = 9; assertEquals(1, key.bytes[0].toInt())
        val variants = mutableListOf(variant()); val families = mutableListOf(family(variants))
        val checked = engine.validate(State(families = families)); variants.clear(); families.clear()
        assertEquals(1, engine.project(checked).size)
        try { (checked.state.families as MutableList).clear(); fail("Mutable validated state") } catch (_: UnsupportedOperationException) {}
        try { (checked.state.families.single().variants as MutableList).clear(); fail("Mutable variants") } catch (_: UnsupportedOperationException) {}
    }

    @Test fun validationContextCannotSilentlyChangeProjectedIdentities() {
        val before = state(listOf(variant(), variant("Y")))
        val changed = forcedIdentity("00000000-0000-8000-8000-000000000010")
        rejects("validation_context_mismatch") { changed.project(before) }
    }

    @Test fun allCapacityReservationsAndExactInclusiveLimitsAreEnforced() {
        val single = state(); val usage = single.usage
        val exact = Limits(maximumLiveVariants = 1, maximumRecords = 3, otherRecords = 2,
            maximumFamilies = 1, maximumTombstones = 2, otherTombstones = 2,
            maximumDocumentBytes = usage.documentBytes + 5, otherDocumentBytes = 5,
            maximumJournalBytes = usage.journalBytes + 7, otherJournalBytes = 7)
        assertEquals(1L, Engine(exact).validate(single.state).usage.liveVariants)
        val cases = listOf("live_variants" to exact.copy(maximumLiveVariants = 0), "records" to exact.copy(maximumRecords = 2),
            "families" to exact.copy(maximumFamilies = 0), "tombstones" to exact.copy(maximumTombstones = 1),
            "document_bytes" to exact.copy(maximumDocumentBytes = usage.documentBytes + 4), "journal_bytes" to exact.copy(maximumJournalBytes = usage.journalBytes + 6))
        for ((kind, limits) in cases) rejects("capacity_$kind") { Engine(limits).validate(single.state) }
        rejects("invalid_limits") { Engine(Limits(otherRecords = -1)).validate(State()) }
        rejects("capacity_arithmetic") { Engine(Limits(otherDocumentBytes = Long.MAX_VALUE)).validate(State()) }
        val noteFull = Engine(Limits(otherTombstones = 20000))
        val live = noteFull.validate(single.state)
        rejects("capacity_tombstones") { noteFull.deleteFamilies(live, setOf(root)) }
        assertEquals(single.state, live.state)
    }

    @Test fun deleteFanoutCapacityFailureNeverPartiallyApplies() {
        val bounded = Engine(Limits(maximumTombstones = 2))
        val old = bounded.validate(State(families = listOf(family(listOf(variant(), variant("Y"))))))
        val deleted = bounded.deleteFamilies(old, setOf(root)).state
        val incoming = bounded.validate(State(families = listOf(family(listOf(variant(), variant("Y"), variant("Z"))))))
        rejects("capacity_tombstones") { bounded.join(deleted, incoming) }
        assertEquals(2, deleted.state.variantDeletes.size); assertEquals(3, bounded.project(incoming).size)
        val replay = bounded.join(deleted, old)
        assertEquals(deleted, replay)
    }

    @Test fun descriptorAndMarkerBoundsCountUnknownDeletedRootsAndRejectAliases() {
        val id2 = "00000000-0000-0000-0000-000000000002"
        val bounded = Engine(Limits(maximumFamilies = 1))
        val one = bounded.validate(State(familyDeletes = listOf(root), chatTombstones = listOf(root)))
        assertEquals(1L, one.usage.retainedRoots)
        rejects("capacity_families") { bounded.validate(State(familyDeletes = listOf(root, id2), chatTombstones = listOf(root, id2))) }
        val two = engine.validate(State(familyDeletes = listOf(root, id2), chatTombstones = listOf(root, id2)))
        assertEquals(2L, two.usage.tombstones)
    }

    @Test fun projectionUsesUnsignedRootTieBreakAndKeepsSortedSiblingsAdjacent() {
        val low = "7fffffff-ffff-ffff-ffff-ffffffffffff"
        val high = "80000000-0000-0000-0000-000000000000"
        val f0 = family(listOf(variant("Y"), variant("Z"), variant("X")), id = low, anchor = "Y")
        val f1 = family(id = high)
        val value = engine.validate(State(orderClock = 99uL, families = listOf(f1, f0)))
        val rows = engine.project(value)
        assertEquals(listOf("Y", "Z", "X", "X"), rows.map { it.payload.text })
        assertEquals(listOf(low, low, low, high), rows.map { it.reference.familyID })
        assertEquals(99uL, engine.join(value, engine.validate(State())).state.orderClock)
        assertEquals(100uL, engine.newOrderBatch(value.state.orderClock, origin, batch, 1).single().counter)
    }

    @Test fun wrappersNeverBypassValidationOrStricterLimits() {
        val value = state()
        rejects("capacity_live_variants") { Engine(Limits(maximumLiveVariants = 0)).project(value) }
        rejects("missing_anchor") { engine.project(value.copy(state = value.state.copy(families = listOf(family(emptyList()))))) }
        rejects("validation_context_mismatch") { engine.project(value.copy(references = emptyList())) }
        assertEquals(value, engine.join(value.copy(usage = value.usage.copy(liveVariants = 0)), engine.validate(State())))
        rejects("unknown_family") { engine.observe(value, origin, payload(), DateBits.fromDouble(1.0)) }
    }

    @Test fun conservativeByteBudgetUsesLiteralUtf8CountsAndRetainedDeleteMetadata() {
        val p = Payload("é", "assistant", "\"\n\\😀")
        val key = engine.contentKey(p)
        val f = Family(root, key, order(), listOf(Variant(key, p, DateBits.fromDouble(100.0))))
        val value = engine.validate(State(families = listOf(f)))
        // 512 state + 384 descriptor + 256 variant + 6 * (2 + 9 + 7 UTF-8 bytes).
        assertEquals(1260L, value.usage.documentBytes)
        assertEquals(2520L, value.usage.journalBytes)
        rejects("capacity_document_bytes") { Engine(Limits(maximumDocumentBytes = 1259)).validate(value.state) }
        val selective = engine.deleteVariants(value, setOf(engine.project(value).single().reference)).state
        // Body gone: 512 + 384 + 192 selector + 40 projected marker.
        assertEquals(1128L, selective.usage.documentBytes)
        assertEquals(2256L, selective.usage.journalBytes)
        val familyDelete = engine.deleteFamilies(value, setOf(root)).state
        // Family barrier adds a separate 40-byte root entry without dropping the selector.
        assertEquals(1168L, familyDelete.usage.documentBytes)
        assertEquals(2336L, familyDelete.usage.journalBytes)
        val oversized = Payload("é", "assistant", "😀".repeat(400000))
        val oversizedKey = engine.contentKey(oversized)
        val oversizedFamily = Family(root, oversizedKey, order(), listOf(Variant(oversizedKey, oversized, DateBits.fromDouble(100.0))))
        rejects("capacity_document_bytes") { engine.validate(State(families = listOf(oversizedFamily))) }
    }

    @Test fun seededMultipleFamiliesPreserveAlgebraAndCrossFamilyDeletionIsolation() {
        val random = Random(1947)
        val ids = listOf(root, origin, "7fffffff-ffff-ffff-ffff-ffffffffffff", "80000000-0000-0000-0000-000000000000")
        repeat(20) {
            val inputs = (0..2).map {
                val families = ids.filter { random.nextBoolean() }.map { id ->
                    val variants = listOf(variant(date = random.nextInt(1, 100).toDouble())) +
                        listOf("Y", "Z", "e\u0301").filter { random.nextBoolean() }.map { variant(it, random.nextInt(1, 100).toDouble()) }
                    family(variants, id = id, key = order(random.nextInt(0, 3).toULong(), random.nextInt(0, 3).toULong()))
                }
                var value = engine.validate(State(families = families))
                if (families.isNotEmpty() && random.nextBoolean()) value = engine.deleteFamilies(value, setOf(families.random(random).familyID)).state
                val rows = engine.project(value)
                if (rows.isNotEmpty() && random.nextBoolean()) value = engine.deleteVariants(value, setOf(rows.random(random).reference)).state
                value
            }
            val joined = laws(inputs)
            val deletedRoots = inputs.flatMap { it.state.familyDeletes }.toSet()
            val deletedVariants = inputs.flatMap { it.state.variantDeletes }.toSet()
            val expectedReferences = inputs.flatMap { it.references }.filter {
                it.familyID !in deletedRoots && it !in deletedVariants
            }.toSet()
            assertEquals(expectedReferences, engine.project(joined).map { it.reference }.toSet())
            for (row in engine.project(joined)) {
                assertFalse(row.reference.familyID in deletedRoots)
                assertFalse(row.reference in deletedVariants)
                val supplied = inputs.flatMap { input -> input.state.families.filter { it.familyID == row.reference.familyID }
                    .flatMap { it.variants }.filter { it.contentKey == row.reference.contentKey } }
                val minimum = supplied.minBy { it.dateBits.value }.dateBits
                assertEquals(minimum, row.dateBits)
            }
            for (input in inputs) {
                assertTrue(joined.state.familyDeletes.containsAll(input.state.familyDeletes))
                assertTrue(joined.state.variantDeletes.containsAll(input.state.variantDeletes))
                assertTrue(joined.state.chatTombstones.containsAll(input.state.chatTombstones))
            }
        }
    }

    @Test fun defaultTenThousandLiveAndTwentyThousandMarkerLimitsAreInclusive() {
        val many = (0 until 10000).map { variant(if (it == 0) "X" else "v$it") }
        val full = engine.validate(State(families = listOf(family(many))))
        assertEquals(10000L, full.usage.liveVariants)
        rejects("capacity_live_variants") { engine.observe(full, root, payload("one too many"), DateBits.fromDouble(1.0)) }
        val recordsFull = Engine(Limits(otherRecords = 20000)).validate(full.state)
        assertEquals(10000L, recordsFull.usage.liveVariants)
        rejects("capacity_records") { Engine(Limits(otherRecords = 20001)).validate(full.state) }
        val ids = (0 until 20000).map { UUID(0L, it.toLong()).toString() }
        val deleted = engine.validate(State(familyDeletes = ids, chatTombstones = ids))
        assertEquals(20000L, deleted.usage.tombstones)
        val extra = ids + UUID(0L, 20000L).toString()
        rejects("capacity_tombstones") { engine.validate(State(familyDeletes = extra, chatTombstones = extra)) }
        val descriptorEngine = Engine(Limits(maximumTombstones = 30001))
        val roots = (0 until 30000).map { UUID(0L, it.toLong()).toString() }
        assertEquals(30000L, descriptorEngine.validate(State(familyDeletes = roots, chatTombstones = roots)).usage.retainedRoots)
        val overflow = roots + UUID(0L, 30000L).toString()
        rejects("capacity_families") { descriptorEngine.validate(State(familyDeletes = overflow, chatTombstones = overflow)) }
    }

    @Test fun seededCompatibleStatesObeyJoinLawsWithDeletesAndDateOrderObservations() {
        val random = Random(947)
        repeat(30) {
            val source = (0..2).map { index ->
                val variants = listOf(variant(date = random.nextInt(1, 100).toDouble())) +
                    listOf("Y", "Z", "é", "e\u0301").filter { random.nextBoolean() }.map { variant(it, random.nextInt(1, 100).toDouble()) }
                var value = state(variants, order(random.nextInt(0, 50).toULong(), (index + 1).toULong()))
                if (random.nextInt(4) == 0) value = engine.deleteFamilies(value, setOf(root)).state
                else if (random.nextBoolean()) value = engine.deleteVariants(value, setOf(engine.project(value).random(random).reference)).state
                value
            }
            val result = laws(source)
            for (input in source) {
                assertTrue(result.state.variantDeletes.containsAll(input.state.variantDeletes))
                assertTrue(result.state.chatTombstones.containsAll(input.state.chatTombstones))
            }
            var repeated = result
            repeat(5) { repeated = engine.join(repeated, source[it % 3]) }
            assertEquals(result, repeated)
        }
    }
}
