package app.asterion.veyra.sync

import org.junit.Assert.*
import org.junit.Test

/**
 * Pure primitive tests, not native Foundation golden vectors or proof of JSON/KDF compatibility.
 * Literal bit patterns and hash IDs were independently calculated from the Swift algorithms.
 */
class SyncCodecTest {
    private val mixedId = "aBcDeFaB-cDeF-4aBc-8DeF-aBcDeFaBcDeF"
    private val lowerId = "abcdefab-cdef-4abc-8def-abcdefabcdef"
    private val upperId = "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF"
    private val original = "12345678-1234-4234-8234-123456789012"

    private fun rejects(block: () -> Unit) {
        try { block(); fail("Expected rejection") } catch (_: IllegalArgumentException) { }
    }

    @Test fun preservesReferenceSecondsWithoutRoundingOrUnixConversion() {
        val cases = listOf(
            0.0 to "0000000000000000",
            -0.0 to "8000000000000000",
            -978307200.0 to "c1cd27e440000000",
            -0.125 to "bfc0000000000000",
            Double.MIN_VALUE to "0000000000000001",
            -Double.MIN_VALUE to "8000000000000001",
            Math.nextUp(1.0) to "3ff0000000000001",
            721692800.0 to "41c5821440000000",
            Math.nextUp(721692800.0) to "41c5821440000001",
            252423993599.0 to "424d62d23c7f8000"
        )
        for ((seconds, bits) in cases) {
            val value = SyncCodec.FoundationDate.fromReferenceSeconds(seconds)
            assertEquals(bits, value.bitString)
            assertEquals(java.lang.Double.doubleToRawLongBits(seconds),
                java.lang.Double.doubleToRawLongBits(value.referenceSeconds))
            val restored = SyncCodec.FoundationDate.fromBitString(bits)
            assertEquals(value, restored)
            assertEquals(bits, restored.bitString)
        }
    }

    @Test fun distinguishesSignedZeroAndNearbyDatesInStorage() {
        val positiveZero = SyncCodec.FoundationDate.fromReferenceSeconds(0.0)
        val negativeZero = SyncCodec.FoundationDate.fromReferenceSeconds(-0.0)
        val nearby = SyncCodec.FoundationDate.fromReferenceSeconds(Double.MIN_VALUE)
        assertEquals(3, setOf(positiveZero, negativeZero, nearby).size)
        assertEquals(positiveZero, SyncCodec.FoundationDate.fromBitString("0000000000000000"))
    }

    @Test fun importedDateSurvivesAnOtherwiseLossyUnixRoundTrip() {
        val value = SyncCodec.FoundationDate.fromBitString("41c5821440000001")
        val unixRoundTrip = (value.referenceSeconds + 978307200.0) - 978307200.0
        assertEquals("41c5821440000000", SyncCodec.FoundationDate.fromReferenceSeconds(unixRoundTrip).bitString)
        assertEquals("41c5821440000001", value.bitString)
    }

    @Test fun rejectsInvalidReferenceDatesAtBothBoundaries() {
        for (seconds in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY,
            Math.nextDown(-978307200.0), Math.nextUp(252423993599.0))) {
            rejects { SyncCodec.FoundationDate.fromReferenceSeconds(seconds) }
        }
        for (bits in listOf("7ff8000000000000", "7ff0000000000000", "fff0000000000000",
            "c1cd27e440000001", "424d62d23c7f8001")) {
            rejects { SyncCodec.FoundationDate.fromBitString(bits) }
        }
    }

    @Test fun requiresExactlySixteenLowercaseHexDigitsForDateBits() {
        for (bits in listOf("", "0", "00000000000000000", "+000000000000000",
            "000000000000000g", "C1CD27E440000000", " 0000000000000000", "0000000000000000\n")) {
            rejects { SyncCodec.FoundationDate.fromBitString(bits) }
        }
    }

    @Test fun separatesFoundationRecordCaseFromDomainCase() {
        assertEquals(upperId, SyncCodec.recordUuid(mixedId))
        assertEquals(lowerId, SyncCodec.domainUuid(mixedId))
        assertEquals(upperId, SyncCodec.recordUuid(lowerId))
        assertEquals(lowerId, SyncCodec.domainUuid(upperId))
        // Foundation's UUID identity does not require one particular version or variant.
        assertEquals("00000000-0000-0000-0000-000000000000",
            SyncCodec.domainUuid("00000000-0000-0000-0000-000000000000"))
    }

    @Test fun rejectsUuidParserShortcutsAndNoncanonicalShapes() {
        for (value in listOf("1-1-1-1-1", lowerId.replace("-", ""), "{$lowerId}",
            "urn:uuid:$lowerId", " $lowerId", "$lowerId\n", lowerId.replace('a', 'g'),
            "abcdefab-cdef-4abc-8def-abcdefabcde", "abcdefab-cdef-4abc-8def-abcdefabcdef0")) {
            rejects { SyncCodec.recordUuid(value) }
            rejects { SyncCodec.domainUuid(value) }
        }
    }

    @Test fun tombstonesRequireExactLowercaseCanonicalIdentity() {
        assertEquals("note:$lowerId", SyncCodec.tombstone("note", mixedId))
        assertEquals("chat:$lowerId", SyncCodec.tombstone("chat", upperId))
        assertTrue(SyncCodec.isValidTombstone("note:$lowerId"))
        assertTrue(SyncCodec.isValidTombstone("chat:$lowerId"))
        for (value in listOf("note:$upperId", "note:$mixedId", "Note:$lowerId", "note:1-1-1-1-1",
            "knowledge:$lowerId", "note:$lowerId:", "note: $lowerId", "note:$lowerId\n",
            "note:", ":$lowerId", lowerId)) {
            assertFalse(value, SyncCodec.isValidTombstone(value))
        }
    }

    @Test fun rejectsUnknownKindsBeforeDerivingIdentities() {
        for (kind in listOf("", "Note", "CHAT", "knowledge", "note:", "note\u0000", " note")) {
            rejects { SyncCodec.tombstone(kind, original) }
            rejects { SyncCodec.conflictId(kind, original, byteArrayOf(0x7b, 0x7d)) }
            rejects { SyncCodec.restoredId(kind, original, emptySet()) }
        }
        rejects { SyncCodec.conflictId("note", "1-1-1-1-1", byteArrayOf(0x7b, 0x7d)) }
        rejects { SyncCodec.restoredId("note", "1-1-1-1-1", emptySet()) }
    }

    @Test fun conflictIdsUseExactBytesAndLowercaseOriginalUuid() {
        // Opaque synthetic payloads exercise the hash contract, not record JSON validation.
        val bytes = byteArrayOf(0x7b, 0x7d)
        val before = bytes.copyOf()
        assertEquals("1a9881e6-ec43-55d6-906a-4fc263803eee", SyncCodec.conflictId("note", mixedId, bytes))
        assertEquals("1a9881e6-ec43-55d6-906a-4fc263803eee", SyncCodec.conflictId("note", upperId, bytes))
        assertEquals("b61c63f3-14d2-543f-8615-064737a5ad9d", SyncCodec.conflictId("chat", mixedId, bytes))
        assertArrayEquals(before, bytes)
    }

    @Test fun conflictHashDoesNotNormalizeUnicodeOrReencodeCallerBytes() {
        val composed = "{\"text\":\"caf\u00e9\"}".toByteArray(Charsets.UTF_8)
        val decomposed = "{\"text\":\"cafe\u0301\"}".toByteArray(Charsets.UTF_8)
        assertEquals("6be4efe8-9523-5177-8165-b66c88a578c7", SyncCodec.conflictId("note", lowerId, composed))
        assertEquals("acd55439-acb0-5503-9f32-4ef66b98ad8b", SyncCodec.conflictId("note", lowerId, decomposed))
    }

    @Test fun conflictPayloadMustBeNonemptyAndWithinTheRemoteDocumentCap() {
        rejects { SyncCodec.conflictId("note", lowerId, byteArrayOf()) }
        rejects { SyncCodec.conflictId("note", lowerId, ByteArray(8 * 1024 * 1024 + 1)) }
        // Opaque bytes test the inclusive bound, not canonical JSON or document validity.
        val atLimit = ByteArray(8 * 1024 * 1024) { 0x78 }
        assertEquals("711f10aa-5492-552b-b3ba-9a0a38da2565", SyncCodec.conflictId("note", lowerId, atLimit))
    }

    @Test fun restorationKeepsAnIdentityWithoutItsOwnMarker() {
        assertEquals(lowerId, SyncCodec.restoredId("note", mixedId, emptySet()))
        assertEquals(original, SyncCodec.restoredId("note", original, setOf("chat:$original")))
    }

    @Test fun restorationFollowsDeletedGenerationsWithoutRemovingAnyMarker() {
        val note1 = "a9a06aa9-f85a-8bc8-a1c3-d5041d4c6d19"
        val deleted = mutableSetOf("note:$original", "note:$note1", "chat:$original")
        val before = deleted.toSet()
        assertEquals(note1, SyncCodec.restoredId("note", original, setOf("note:$original")))
        assertEquals("a38206d4-4d51-8fc4-b995-a858c259a973", SyncCodec.restoredId("note", original, deleted))
        assertEquals("a38206d4-4d51-8fc4-b995-a858c259a973", SyncCodec.restoredId("note", original, deleted))
        assertEquals(before, deleted)
    }

    @Test fun restorationDomainsSeparateNotesAndChats() {
        val chat1 = "48b5ccb6-18a3-8d9e-9530-565f84c4fd70"
        assertEquals(chat1, SyncCodec.restoredId("chat", original, setOf("chat:$original")))
        assertEquals("49ae0580-87c5-8427-951f-c40cf16dff38",
            SyncCodec.restoredId("chat", original, setOf("chat:$original", "chat:$chat1")))
    }

    @Test fun restorationRejectsInvalidMarkersEvenWhenUnrelated() {
        for (marker in listOf("note:$upperId", "Note:$original", "note:1-1-1-1-1", "knowledge:$original")) {
            rejects { SyncCodec.restoredId("note", original, setOf(marker)) }
        }
    }

    @Test fun restorationAllowsTwentyThousandGenerationsButNoExtraMarker() {
        val deleted = mutableSetOf<String>()
        var current = original
        repeat(20000) {
            val marker = "note:$current"
            assertTrue(deleted.add(marker))
            current = SyncCodec.restoredId("note", current, setOf(marker))
        }
        // Independently calculated, not an expectation derived by the implementation.
        assertEquals("2e32109b-ecb8-8e75-b4e0-256aebf8bdef", SyncCodec.restoredId("note", original, deleted))
        assertTrue(deleted.add("note:$current"))
        rejects { SyncCodec.restoredId("note", original, deleted) }
    }

    @Test fun importPassphraseKeepsExactUtf8IncludingWhitespaceAndSupplementaryScalars() {
        assertArrayEquals(byteArrayOf(0x20, 0x09, 0x63, 0x61, 0x66, 0xc3.toByte(), 0xa9.toByte(),
            0xf0.toByte(), 0x9f.toByte(), 0x98.toByte(), 0x80.toByte(), 0x00, 0x0a),
            SyncCodec.importPassphraseUtf8(" \tcaf\u00e9\ud83d\ude00\u0000\n"))
        assertArrayEquals(byteArrayOf(0x65, 0xcc.toByte(), 0x81.toByte()),
            SyncCodec.importPassphraseUtf8("e\u0301"))
        assertArrayEquals(byteArrayOf(0xc3.toByte(), 0xa9.toByte()), SyncCodec.importPassphraseUtf8("\u00e9"))
        // Import accepts the exact original passphrase, even if too short for new-vault setup.
        assertArrayEquals(byteArrayOf(0x20), SyncCodec.importPassphraseUtf8(" "))
    }

    @Test fun importPassphraseRejectsMalformedUtf16RatherThanReplacingIt() {
        for (value in listOf("\ud800", "\udfff", "x\ud800y", "\udc00\ud800")) {
            rejects { SyncCodec.importPassphraseUtf8(value) }
        }
    }

    @Test fun importPassphraseEnforcesNonemptyAndUtf8ByteLimit() {
        rejects { SyncCodec.importPassphraseUtf8("") }
        assertEquals(4096, SyncCodec.importPassphraseUtf8("a".repeat(4096)).size)
        rejects { SyncCodec.importPassphraseUtf8("a".repeat(4097)) }
        assertEquals(4096, SyncCodec.importPassphraseUtf8("\u00e9".repeat(2048)).size)
        rejects { SyncCodec.importPassphraseUtf8("\u00e9".repeat(2049)) }
        assertEquals(4096, SyncCodec.importPassphraseUtf8("\ud83d\ude00".repeat(1024)).size)
        rejects { SyncCodec.importPassphraseUtf8("\ud83d\ude00".repeat(1025)) }
    }
}
