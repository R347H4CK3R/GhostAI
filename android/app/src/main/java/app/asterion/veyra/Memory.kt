package app.asterion.veyra

import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.util.UUID

data class Note(val id: String, val project: String, val text: String, val source: String, val savedAt: Double)
data class Chat(val id: String, val project: String, val role: String, val text: String, val date: Double)
data class SavedState(val notes: List<Note> = emptyList(), val chats: List<Chat> = emptyList())

/** Portable, strict v1 backup codec. Dates are seconds since 2001-01-01, matching Swift Codable. */
object Memory {
    const val MAX_BYTES = 2 * 1024 * 1024
    const val MAX_ITEMS = 2000
    private const val APPLE_EPOCH_SECONDS = 978307200.0
    fun now() = System.currentTimeMillis() / 1000.0 - APPLE_EPOCH_SECONDS
    fun unixMillis(value: Double) = ((value + APPLE_EPOCH_SECONDS) * 1000).toLong()
    private val credentials = listOf(
        "gh[pousr]_", "github_pat_", "-----BEGIN .*PRIVATE KEY", "sk-[A-Za-z0-9_-]{12,}",
        "(?i)(password|api[_ -]?key|access[_ -]?token|secret)\\s*[:=]\\s*\\S+",
        "(?i)bearer\\s+[A-Za-z0-9._-]{12,}"
    ).map(::Regex)
    fun safe(value: String) = credentials.none { it.containsMatchIn(value) }
    private fun field(obj: JSONObject, key: String, max: Int): String {
        val value = obj.get(key)
        require(value is String && value.isNotBlank() && value.length <= max) { "Invalid $key or length." }
        require(safe(value)) { "Possible credential found in $key. Remove secrets before importing or saving." }
        return value
    }
    private fun id(obj: JSONObject): String {
        val value = field(obj, "id", 36)
        require(Regex("[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}").matches(value)) { "Invalid UUID." }
        return UUID.fromString(value).toString()
    }
    private fun date(obj: JSONObject, key: String): Double {
        val raw = obj.get(key)
        require(raw is Number) { "Dates must be numeric Apple reference seconds." }
        val value = raw.toDouble()
        require(value.isFinite() && value >= -978307200 && value <= 7258118400.0) { "Date out of bounds." }
        return value
    }
    private fun keys(obj: JSONObject, expected: Set<String>) {
        require(obj.keys().asSequence().toSet() == expected) { "Unexpected or missing fields." }
    }
    fun decode(raw: String): SavedState {
        require(raw.toByteArray(Charsets.UTF_8).size <= MAX_BYTES) { "Backup exceeds 2 MiB." }
        val tokenizer = JSONTokener(raw)
        val root = tokenizer.nextValue() as? JSONObject ?: error("Expected a JSON object.")
        require(tokenizer.nextClean() == '\u0000') { "Unexpected trailing data." }
        keys(root, setOf("version", "notes", "chats"))
        val version = root.get("version")
        require(version is Number && version.toDouble() == 1.0) { "Unsupported backup version." }
        val notes = root.getJSONArray("notes")
        val chats = root.getJSONArray("chats")
        require(notes.length() + chats.length() <= MAX_ITEMS) { "Backup exceeds 2000 total records." }
        val ids = mutableSetOf<String>()
        val parsedNotes = (0 until notes.length()).map {
            val n = notes.getJSONObject(it)
            keys(n, setOf("id", "project", "text", "source", "savedAt"))
            val nid = id(n); require(ids.add(nid)) { "Duplicate record ID." }
            Note(nid, field(n, "project", 120), field(n, "text", 16000), field(n, "source", 500), date(n, "savedAt"))
        }
        val parsedChats = (0 until chats.length()).map {
            val c = chats.getJSONObject(it)
            keys(c, setOf("id", "project", "role", "text", "date"))
            val cid = id(c); require(ids.add(cid)) { "Duplicate record ID." }
            val role = field(c, "role", 30)
            require(role in setOf("user", "assistant", "system")) { "Unsupported chat role." }
            Chat(cid, field(c, "project", 120), role, field(c, "text", 16000), date(c, "date"))
        }
        return SavedState(parsedNotes, parsedChats)
    }
    fun encode(state: SavedState): String {
        val notes = JSONArray(); state.notes.forEach { n -> notes.put(JSONObject().put("id", n.id).put("project", n.project).put("text", n.text).put("source", n.source).put("savedAt", n.savedAt)) }
        val chats = JSONArray(); state.chats.forEach { c -> chats.put(JSONObject().put("id", c.id).put("project", c.project).put("role", c.role).put("text", c.text).put("date", c.date)) }
        return JSONObject().put("version", 1).put("notes", notes).put("chats", chats).toString(2)
    }
    /** Existing IDs are never overwritten, even when content is identical. Reject the entire merge. */
    fun merge(existing: SavedState, incoming: SavedState): SavedState {
        val ids = (existing.notes.map { it.id } + existing.chats.map { it.id }).map { it.lowercase() }.toSet()
        require((incoming.notes.map { it.id } + incoming.chats.map { it.id }).none { it.lowercase() in ids }) { "Backup contains IDs already on this device. Nothing was imported." }
        val merged = SavedState(existing.notes + incoming.notes, existing.chats + incoming.chats)
        return decode(encode(merged))
    }
}
