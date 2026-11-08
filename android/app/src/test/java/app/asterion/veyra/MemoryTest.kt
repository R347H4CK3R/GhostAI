package app.asterion.veyra

import org.junit.Assert.*
import org.junit.Test

class MemoryTest {
    private val note = Note("11111111-2222-3333-4444-555555555555", "Launch", "Read the project brief", "Manual note", 800000000.25)
    private fun rejects(block: () -> Unit) { try { block(); fail("Expected rejection") } catch (_: IllegalArgumentException) {} }
    @Test fun swiftCompatibleRoundTrip() {
        val state = SavedState(listOf(note), listOf(Chat("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "Launch", "assistant", "Preserve this history", 800000000.5)))
        assertEquals(state, Memory.decode(Memory.encode(state)))
        assertEquals(978307200000L, Memory.unixMillis(0.0))
    }
    @Test fun rejectsUnsupportedVersion() { rejects { Memory.decode(Memory.encode(SavedState()).replace("1", "2")) } }
    @Test fun rejectsDuplicateIds() { rejects { Memory.decode(Memory.encode(SavedState(listOf(note, note)))) } }
    @Test fun rejectsExistingIdWithoutOverwrite() {
        val existing = SavedState(listOf(note))
        rejects { Memory.merge(existing, SavedState(listOf(note.copy(text = "Changed")))) }
        assertEquals("Read the project brief", existing.notes.single().text)
    }
    @Test fun addsNewNotesAndPreservesChatHistory() {
        val chat = Chat("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "Launch", "user", "History", 800000000.0)
        assertEquals(SavedState(listOf(note), listOf(chat)), Memory.merge(SavedState(chats = listOf(chat)), SavedState(listOf(note))))
    }
    @Test fun checksSecretsInSourceAndProject() {
        rejects { Memory.decode(Memory.encode(SavedState(listOf(note.copy(source = "password=hunter2"))))) }
        rejects { Memory.decode(Memory.encode(SavedState(listOf(note.copy(project = "github_pat_example"))))) }
        assertFalse(Memory.safe("api_key = abcdef"))
    }
    @Test fun rejectsTextAndCountLimits() {
        rejects { Memory.decode(Memory.encode(SavedState(listOf(note.copy(text = "x".repeat(16001)))))) }
        rejects { Memory.decode(Memory.encode(SavedState(List(2001) { note }))) }
        rejects { Memory.decode(" ".repeat(Memory.MAX_BYTES + 1)) }
    }
    @Test fun rejectsUnknownFieldsAndTrailingData() {
        rejects { Memory.decode("{\"version\":1,\"notes\":[],\"chats\":[],\"surprise\":true}") }
        rejects { Memory.decode("{\"version\":1,\"notes\":[],\"chats\":[]} trailing") }
    }
    @Test fun rejectsOutOfRangeDates() {
        rejects { Memory.decode(Memory.encode(SavedState(listOf(note.copy(savedAt = -978307201.0))))) }
    }
    @Test fun rejectsCrossTypeIds() {
        rejects { Memory.decode(Memory.encode(SavedState(listOf(note), listOf(Chat(note.id, "Launch", "user", "history", 0.0))))) }
    }
}
