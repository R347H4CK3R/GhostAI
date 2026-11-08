package app.asterion.veyra

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.util.AtomicFile
import android.view.View
import android.view.WindowManager
import android.widget.*
import java.io.File
import java.text.DateFormat
import java.util.Date
import java.util.UUID

class MainActivity : Activity() {
    private val cyan = Color.rgb(88, 231, 223)
    private val muted = Color.rgb(163, 174, 201)
    private var state = SavedState()
    private var writable = true
    private lateinit var project: EditText
    private lateinit var search: EditText
    private lateinit var noteText: EditText
    private lateinit var source: EditText
    private lateinit var list: LinearLayout
    private lateinit var summary: TextView
    private val disk by lazy { AtomicFile(File(filesDir, "memory-v1.json")) }
    private val importCode = 10
    private val exportCode = 11

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Avoid exposing notes in recent-app snapshots and screenshots.
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        var loadError: String? = null
        try {
            if (disk.baseFile.exists() || File(filesDir, "memory-v1.json.bak").exists()) {
                state = disk.openRead().use { Memory.decode(readBounded(it)) }
            }
        } catch (e: Exception) {
            writable = false
            loadError = "Local memory could not be read. Writes and imports are disabled to preserve it. ${e.message.orEmpty()}"
        }
        val scroll = ScrollView(this).apply { setBackgroundColor(Color.rgb(9, 14, 28)); isFillViewport = true }
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(22), dp(22), dp(22), dp(30)) }
        scroll.addView(root)
        scroll.setOnApplyWindowInsetsListener { view, insets ->
            view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop, insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
            insets
        }
        root.addView(label("✦   ASTERION / VEYRA", 14, cyan).apply { letterSpacing = 0.16f })
        root.addView(label("A quiet place\nfor your next idea.", 32).apply { setTypeface(typeface, Typeface.BOLD); setPadding(0, dp(20), 0, dp(16)) })
        root.addView(label("OFFLINE MEMORY COMPANION", 12, cyan))
        root.addView(label("Local notes · Project search · JSON backups\nNo model inference, remote connection, chat or autonomous device actions.", 14, muted))
        root.addView(label("01  /  YOUR WORKSPACE", 12, cyan).apply { setPadding(0, dp(28), 0, dp(6)) })
        project = input("Project name", savedInstanceState?.getString("project") ?: "Personal", 120)
        root.addView(project)
        search = input("Search this project's memory", savedInstanceState?.getString("search") ?: "", 200)
        root.addView(search)
        summary = label("", 13, muted); root.addView(summary)
        root.addView(label("02  /  CAPTURE A THOUGHT", 12, cyan).apply { setPadding(0, dp(24), 0, dp(6)) })
        noteText = input("What should you remember? No passwords or API keys.", savedInstanceState?.getString("draft") ?: "", 16000).apply { minLines = 3; setSingleLine(false); inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE }
        root.addView(noteText)
        source = input("Source / provenance", savedInstanceState?.getString("source") ?: "Manual note on Android", 500)
        root.addView(source)
        root.addView(button("＋  Save to this project") { saveNote() }.apply { isEnabled = writable })
        root.addView(label("Notes stay in app-private storage. Backups are plaintext; choose a destination you trust. Credential detection is a warning layer, not a guarantee.", 12, muted))
        root.addView(label("03  /  MEMORY STREAM", 12, cyan).apply { setPadding(0, dp(24), 0, dp(8)) })
        list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }; root.addView(list)
        root.addView(button("Export JSON backup") {
            if (!writable) { alert("Export unavailable", "Unreadable local data must not be replaced by an empty backup."); return@button }
            AlertDialog.Builder(this).setTitle("Export all projects?").setMessage("This plaintext file includes all saved notes and preserved chat history. A cloud-backed file provider may upload it. Choose a private destination.")
                .setNegativeButton("Cancel", null).setPositiveButton("Choose destination") { _, _ ->
                    startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply { type = "application/json"; addCategory(Intent.CATEGORY_OPENABLE); putExtra(Intent.EXTRA_TITLE, "asterion-veyra-backup.json") }, exportCode)
                }.show()
        })
        root.addView(button("Import JSON backup") {
            if (writable) startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply { type = "*/*"; addCategory(Intent.CATEGORY_OPENABLE); putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", "text/plain")) }, importCode)
            else alert("Import unavailable", "Existing local data could not be read. Nothing will be overwritten.")
        })
        root.addView(label("BACKUP FORMAT  /  iOS-compatible v1\nChat history is preserved in backups only. Android chat is not implemented. No automatic sync.", 12, muted))
        setContentView(scroll)
        val watcher = object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) { render() }
            override fun afterTextChanged(s: Editable?) {}
        }
        project.addTextChangedListener(watcher); search.addTextChangedListener(watcher)
        render()
        loadError?.let { alert("Memory protected", it) }
    }
    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString("project", project.text.toString()); outState.putString("search", search.text.toString())
        outState.putString("draft", noteText.text.toString()); outState.putString("source", source.text.toString())
        super.onSaveInstanceState(outState)
    }
    private fun saveNote() {
        try {
            val note = Note(UUID.randomUUID().toString(), project.text.toString().trim(), noteText.text.toString().trim(), source.text.toString().trim(), Memory.now())
            val next = Memory.merge(state, SavedState(listOf(note)))
            persist(next); noteText.setText(""); render(); toast("Saved on this device")
        } catch (e: Exception) { alert("Could not save", e.message ?: "Storage unavailable.") }
    }
    private fun persist(next: SavedState) {
        check(writable) { "Local data is protected from overwrite." }
        val raw = Memory.encode(next)
        Memory.decode(raw)
        val output = disk.startWrite()
        try { output.write(raw.toByteArray(Charsets.UTF_8)); disk.finishWrite(output) }
        catch (e: Exception) { disk.failWrite(output); throw e }
        state = next
    }
    private fun render() {
        val selected = project.text.toString().trim()
        val query = search.text.toString().trim()
        val all = state.notes.filter { it.project == selected }
        val matches = all.filter { query.isEmpty() || it.text.contains(query, true) || it.source.contains(query, true) }.sortedByDescending { it.savedAt }
        val projects = state.notes.map { it.project }.distinct().sorted()
        summary.text = "${all.size} notes in this project · ${state.notes.size} total\nProjects: ${projects.joinToString(", ").ifEmpty { "none yet" }}"
        list.removeAllViews()
        if (matches.isEmpty()) list.addView(label(if (query.isEmpty()) "Nothing here yet. Give an idea a place to land." else "No notes match this search.", 15, muted))
        matches.forEach { note ->
            val card = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL; setPadding(dp(16), dp(14), dp(16), dp(10))
                background = GradientDrawable(GradientDrawable.Orientation.TL_BR, intArrayOf(Color.rgb(24, 35, 54), Color.rgb(30, 25, 53))).apply { cornerRadius = dp(18).toFloat(); setStroke(dp(1), Color.rgb(58, 64, 89)) }
                layoutParams = LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(12) }
            }
            card.addView(label(note.project.uppercase(), 11, cyan))
            card.addView(label(note.text, 17).apply { setTextIsSelectable(true); setPadding(0, dp(8), 0, dp(10)) })
            card.addView(label("Source: ${note.source}\n${DateFormat.getDateTimeInstance().format(Date(Memory.unixMillis(note.savedAt)))}", 12, muted))
            card.addView(button("Delete note") {
                AlertDialog.Builder(this).setTitle("Delete this note?").setMessage("Remove it from “${note.project}” on this device? This cannot be undone. Exported backups are unchanged.")
                    .setNegativeButton("Keep", null).setPositiveButton("Delete") { _, _ ->
                        try { persist(state.copy(notes = state.notes.filterNot { it.id == note.id })); render() }
                        catch (e: Exception) { alert("Could not delete", e.message.orEmpty()) }
                    }.show()
            })
            list.addView(card)
        }
    }
    @Deprecated("Framework activity result API retained to avoid runtime dependencies")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (resultCode != RESULT_OK) return
        val uri = data?.data ?: return
        try {
            if (requestCode == exportCode) {
                val bytes = Memory.encode(state).toByteArray(Charsets.UTF_8)
                val stream = contentResolver.openOutputStream(uri, "wt") ?: error("File provider did not open the destination.")
                stream.use { it.write(bytes) }
                toast("Backup exported")
            } else if (requestCode == importCode) {
                val incoming = contentResolver.openInputStream(uri)?.use { Memory.decode(readBounded(it)) } ?: error("Cannot read selected file.")
                Memory.merge(state, incoming) // Validate collisions and combined bounds before asking.
                AlertDialog.Builder(this).setTitle("Import this backup?")
                    .setMessage("Add ${incoming.notes.size} notes and preserve ${incoming.chats.size} chat entries across ${incoming.notes.map { it.project }.distinct().size} projects? Chat entries are backup-only. Existing notes will not be replaced. Only import files you trust.")
                    .setNegativeButton("Cancel", null).setPositiveButton("Import") { _, _ ->
                        try { persist(Memory.merge(state, incoming)); render(); toast("Backup imported") }
                        catch (e: Exception) { alert("Nothing imported", e.message.orEmpty()) }
                    }.show()
            }
        } catch (e: Exception) { alert(if (requestCode == importCode) "Nothing imported" else "Export failed", e.message ?: "File access failed. A partial export may need deleting.") }
    }
    private fun readBounded(input: java.io.InputStream): String {
        val bytes = java.io.ByteArrayOutputStream()
        val chunk = ByteArray(8192)
        while (true) { val count = input.read(chunk); if (count < 0) break; require(bytes.size() + count <= Memory.MAX_BYTES) { "Backup exceeds 2 MiB." }; bytes.write(chunk, 0, count) }
        return Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes.toByteArray())).toString()
    }
    private fun dp(n: Int) = (n * resources.displayMetrics.density).toInt()
    private fun label(value: String, size: Int, color: Int = Color.rgb(237, 241, 255)) = TextView(this).apply { text = value; textSize = size.toFloat(); setTextColor(color); setPadding(0, dp(5), 0, dp(5)) }
    private fun input(hintText: String, value: String, max: Int) = EditText(this).apply {
        hint = hintText; setText(value); textSize = 16f; setTextColor(Color.WHITE); setHintTextColor(muted); setSingleLine(true)
        filters = arrayOf(android.text.InputFilter.LengthFilter(max)); setPadding(dp(10), dp(12), dp(10), dp(12))
        // Do not send note fields to autofill services. Keyboard apps remain user-controlled.
        importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
    }
    private fun button(value: String, action: () -> Unit) = Button(this).apply { text = value; isAllCaps = false; setTextColor(cyan); minHeight = dp(48); setOnClickListener { action() } }
    private fun alert(title: String, message: String) { AlertDialog.Builder(this).setTitle(title).setMessage(message).setPositiveButton("OK", null).show() }
    private fun toast(value: String) { Toast.makeText(this, value, Toast.LENGTH_SHORT).show() }
}
