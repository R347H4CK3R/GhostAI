package app.asterion.veyra.sync

import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID

/**
 * Isolated v1 identity primitives. No document serializer, encryption, persistence or transport.
 * Callers of [conflictId] must supply the exact, independently verified Foundation canonical
 * record bytes. Generic JSON serialization is not a compatible substitute. These primitives
 * do not enable a sync writer or establish native Foundation/Android interoperability.
 */
object SyncCodec {
    private const val APPLE_UNIX_OFFSET = 978307200.0
    private const val MAXIMUM_UNIX_SECONDS = 253402300799.0
    private const val MAXIMUM_DOCUMENT_BYTES = 8 * 1024 * 1024
    private const val MAXIMUM_TOMBSTONES = 20000
    private const val MAXIMUM_PASSPHRASE_BYTES = 4096
    private const val RESTORATION_DOMAIN = "Veyra explicit import restoration v1"
    private const val UUID_PATTERN = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    private val uuidPattern = Regex(UUID_PATTERN)
    private val tombstonePattern = Regex("(?:note|chat):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
    private val bitsPattern = Regex("[0-9a-f]{16}")

    /**
     * Lossless storage of binary64 seconds since 2001-01-01, including negative zero.
     * Equality here is bit identity for storage, not Swift Date's chronological equality.
     * Never convert imported values through Unix seconds, milliseconds or Instant for storage:
     * adding and subtracting the epoch offset can discard an imported bit.
     */
    class FoundationDate private constructor(private val rawBits: Long) {
        val referenceSeconds: Double get() = Double.fromBits(rawBits)

        /** Fixed-width lowercase, most-significant-byte-first IEEE-754 hexadecimal bits. */
        val bitString: String get() = java.lang.Long.toHexString(rawBits).padStart(16, '0')

        override fun equals(other: Any?): Boolean = other is FoundationDate && rawBits == other.rawBits
        override fun hashCode(): Int = rawBits.hashCode()

        companion object {
            fun fromReferenceSeconds(seconds: Double): FoundationDate {
                // Match PrivateMemorySyncPolicy.validDate, but retain the original bits.
                val unixSeconds = seconds + APPLE_UNIX_OFFSET
                require(unixSeconds.isFinite() && unixSeconds >= 0.0 && unixSeconds <= MAXIMUM_UNIX_SECONDS) {
                    "Invalid Foundation date"
                }
                return FoundationDate(java.lang.Double.doubleToRawLongBits(seconds))
            }

            fun fromBitString(bits: String): FoundationDate {
                require(bitsPattern.matches(bits)) { "Invalid Foundation date bits" }
                return fromReferenceSeconds(Double.fromBits(java.lang.Long.parseUnsignedLong(bits, 16)))
            }
        }
    }

    /** Foundation UUID.uuidString representation for record serialization. */
    fun recordUuid(value: String): String = domainUuid(value).uppercase(Locale.ROOT)

    /** Canonical identity for hash domains and markers; reject Java UUID parser shortcuts. */
    fun domainUuid(value: String): String {
        require(uuidPattern.matches(value)) { "Invalid UUID" }
        return value.lowercase(Locale.ROOT)
    }

    fun tombstone(kind: String, id: String): String {
        validateKind(kind)
        return "$kind:${domainUuid(id)}"
    }

    /** Markers are already canonical on the wire; do not silently repair their case or shape. */
    fun isValidTombstone(value: String): Boolean = tombstonePattern.matches(value)

    /**
     * SHA-256(kind + ':' + lowercase original UUID + exact canonical bytes), truncated to 16
     * bytes with version-5 and RFC variant bits. This is NOT the standard namespace UUIDv5.
     * The caller's bytes must be nonempty and no larger than the remote document cap.
     * Returns a lowercase identity; use [recordUuid] when serializing a record UUID.
     */
    fun conflictId(kind: String, originalId: String, canonicalRecordBytes: ByteArray): String {
        validateKind(kind)
        val original = domainUuid(originalId)
        require(canonicalRecordBytes.isNotEmpty() && canonicalRecordBytes.size <= MAXIMUM_DOCUMENT_BYTES) {
            "Invalid canonical record size"
        }
        val hash = MessageDigest.getInstance("SHA-256")
        hash.update("$kind:$original".toByteArray(Charsets.UTF_8))
        val result = digestUuid(hash.digest(canonicalRecordBytes), 5)
        require(result != original) { "Conflicting sync identity" }
        return result
    }

    /**
     * Identity selection for an explicitly authorized restore, not a stale-device replay.
     * Follows only the requested kind's deleted generations. All deletion markers remain
     * permanent: this function never changes the caller's set or removes an old marker.
     * Validation and traversal both fail closed at the v1 20,000-marker limit.
     */
    fun restoredId(kind: String, originalId: String, tombstones: Set<String>): String {
        validateKind(kind)
        var current = domainUuid(originalId)
        require(tombstones.size <= MAXIMUM_TOMBSTONES) { "Sync tombstone capacity exceeded" }
        require(tombstones.all(::isValidTombstone)) { "Invalid sync tombstone" }
        val visited = HashSet<String>()
        while ("$kind:$current" in tombstones) {
            require(visited.add(current) && visited.size <= MAXIMUM_TOMBSTONES) {
                "Sync restoration capacity exceeded"
            }
            val preimage = "$RESTORATION_DOMAIN\u0000$kind\u0000$current".toByteArray(Charsets.UTF_8)
            current = digestUuid(MessageDigest.getInstance("SHA-256").digest(preimage), 8)
        }
        return current
    }

    /**
     * Import/decryption validation only: preserve exact original UTF-8, whitespace and NULs,
     * reject empty/oversized input and malformed UTF-16 instead of silently replacing it.
     * This is NOT new-vault passphrase validation (Swift counts grapheme clusters there),
     * key derivation, or proof of PBEKeySpec's Unicode behavior on supported Android versions.
     * Callers own the returned sensitive bytes and their lifecycle.
     */
    fun importPassphraseUtf8(passphrase: String): ByteArray {
        // Every valid UTF-16 code unit contributes at least one UTF-8 byte. Bound allocation.
        require(passphrase.isNotEmpty() && passphrase.length <= MAXIMUM_PASSPHRASE_BYTES) {
            "Invalid passphrase"
        }
        val encoder = Charsets.UTF_8.newEncoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        val encoded = try {
            encoder.encode(CharBuffer.wrap(passphrase))
        } catch (_: CharacterCodingException) {
            throw IllegalArgumentException("Invalid passphrase")
        }
        require(encoded.remaining() <= MAXIMUM_PASSPHRASE_BYTES) { "Invalid passphrase" }
        return ByteArray(encoded.remaining()).also { encoded.get(it) }
    }

    private fun validateKind(kind: String) {
        require(kind == "note" || kind == "chat") { "Invalid sync record kind" }
    }

    private fun digestUuid(digest: ByteArray, version: Int): String {
        val bytes = digest.copyOf(16)
        bytes[6] = ((bytes[6].toInt() and 0x0f) or (version shl 4)).toByte()
        bytes[8] = ((bytes[8].toInt() and 0x3f) or 0x80).toByte()
        val buffer = ByteBuffer.wrap(bytes)
        return UUID(buffer.long, buffer.long).toString()
    }
}
