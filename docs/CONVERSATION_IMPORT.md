# User-selected conversation and memory imports

## What this feature does

The app can preview a user-selected **extracted ChatGPT conversation JSON file** and add chosen supported text to local canonical chat history. It can separately import memory text that the user supplies, or the exact Asterion memory-import JSON schema below. This is a bounded compatibility importer, not account synchronization, an account merger, or a promise to recover every conversation or memory.

Imported copies can be included in encrypted private GitHub sync only after that separate capability is explicitly configured and the workspace is within its approved scope. Import does not itself connect an account or grant a new network permission. New offline libraries capture eligible app conversations, research and fixed activity summaries automatically; previously saved capture preferences are preserved.

The importer does not sign into ChatGPT, use another assistant's accounts or private memory, request or download an export, enumerate folders, fetch links, or download assets. ZIP decompression is deliberately not implemented. Extract the export outside the app and select one JSON file. Nothing in an imported message grants permission to run tools or change app security settings.

## Obtain the source yourself

Official OpenAI instructions, checked 2026-11-08:

- [Exporting your ChatGPT history and data](https://help.openai.com/en/articles/7260999-exporting-your-chatgpt-history-and-data): request an eligible account export in Settings → Data controls → Export data, or use the Privacy Portal. OpenAI says processing can take up to seven days and the download link expires after 24 hours. Availability depends on account/workspace; self-service export is not available for Business, Enterprise, or Healthcare workspaces.
- [Transfer exported conversations between ChatGPT accounts](https://help.openai.com/en/articles/9106926-transfer-exported-conversations-between-chatgpt-accounts): extract the ZIP and locate `conversations.json`; larger exports may contain numbered JSON parts. OpenAI describes limitations of transferring conversation data, including that this does not transfer memories or other account settings.

These pages do **not** specify a stable JSON tree schema or establish that saved memories are present in every export. The conversation shape below is the app's explicitly supported compatibility profile, not a claimed OpenAI API contract. Review the extracted file yourself. Do not upload exports to the public source repository or issue tracker.

## Supported conversation profile

One UTF-8 JSON file containing a top-level array of conversation objects:

- `id` (or `conversation_id`) is a nonempty ASCII identifier, at most 200 bytes, containing only letters, digits, `_`, or `-`. If both exist they must match. Duplicate conversation identifiers reject the file.
- `title` is a string of at most 500 characters.
- `mapping` maps node IDs to objects containing matching `id`, `parent` (node ID or null), `children` (unique node IDs), and `message` (object or null).
- A nonempty `current_node` must name a node in that mapping. The importer never guesses a different leaf when it is missing.
- The entire tree must be connected through one root, free of cycles and missing links, and have reciprocal parent/child links. Duplicate message IDs within a conversation invalidate that conversation, including duplicates in omitted branches.
- Supported messages have a unique `id`, `author.role` of `user` or `assistant`, and `content.content_type` equal to `text` with nonempty string-only `parts`. Parts are joined with newlines. Mixed text/asset messages are skipped as a whole, not silently flattened.
- `create_time` is an optional finite, nonnegative Unix timestamp no later than year 9999. Invalid timestamps invalidate the conversation. An absent/null timestamp uses the explicit local import time and is visibly labeled as unavailable in provenance; it is not claimed to be an original message time.

Only the root-to-`current_node` **active branch** is imported. Alternate-branch node counts are shown, not copied. System/developer/tool messages, multimodal content, images, audio, video, attached documents, exported HTML, browsing assets, and unknown structures are not fetched or executed. Their message categories or malformed-record counts appear in the preview. A null-message structural root is not counted as a skipped message. Other metadata is ignored. For partial or malformed conversations the preview must not be interpreted as complete coverage.

`ChatEntry` currently has no provenance fields. Imported message text therefore begins with a plain-text header containing the source filename, conversation title and ID, message ID, selected branch ID and source timestamp. Role and known original timestamp remain in the existing canonical fields. Canonical merge preserves source sequence for equal timestamps (including absent source times assigned one import time), with existing records before additions on a tie. It does not alter timestamps to force ordering; different timestamps still use the store’s chronological ordering. Text is rendered with SwiftUI plain `Text`; no HTML/WebView or remote rendering is used.

## Explicit memory formats

### Plain text

Select a UTF-8 `.txt` or `.md` file containing only the memories you wish to retain. The **entire file becomes one note**, up to 20,000 characters. There is no automatic sentence splitting, summarization, extraction from a conversation, or claim that it came from ChatGPT saved memory. The source labels it user-provided. Markdown is stored as plain text.

### Asterion memory-import JSON v1

This is an app-defined schema, not an OpenAI saved-memory export format:

```json
{
  "format": "asterion-memory-import",
  "version": 1,
  "memories": [
    {
      "id": "my-memory-001",
      "text": "I prefer concise project updates.",
      "saved_at": "2025-01-01T00:00:00Z"
    }
  ]
}
```

The root keys are exactly `format`, `version`, and `memories`. Each memory allows only `id`, `text`, and optional `saved_at`. IDs use the same identifier rules and must be unique; keep them stable across reimports. `text` is nonempty and at most 20,000 characters. `saved_at`, when present, is an ISO 8601 Internet date-time without fractional seconds between 1970 and year 9999; when absent, the import time is used and counted in preview. Unknown root formats reject the file. Invalid or suspicious individual memories are skipped with fixed category counts; invalid/duplicate IDs reject the file. No undocumented `memories.json` shape is guessed.

## Review, selection, reimport, and deletion

The preview shows source item count, importable count, supported message/note counts, skipped categories, omitted alternate-branch nodes, missing timestamps, and the current local project destination. No item is selected by default. Each item has a full text/provenance review screen. The user can select a subset or all items, then explicitly acknowledge and confirm the import.

Stable UUIDv8 identifiers derive from a SHA-256 namespaced hash of project, record kind, conversation ID and message ID; memory JSON uses project plus stable supplied memory ID. Plain-memory text uses project plus complete text. Filenames/titles/content changes do not change conversation or memory-JSON IDs. Existing canonical IDs win, so reimport cannot overwrite edits or duplicate existing records. Conversation IDs are independent of the export filename, so numbered/repartitioned exports deduplicate.

Canonical `SavedState` has no deletion markers, but a configured private sync vault retains permanent markers. Every import still requires acknowledgment of intentional restoration. Before saving to a readable configured store, the importer checks already verified sync history, including local deletions not yet uploaded. Known deleted note/chat IDs receive stable, domain-separated restoration-copy UUIDs; old markers are never cleared. Repeating the same restoration deduplicates to the same live copy. If that copy is later deleted, another explicit restoration advances to a new identity. Ordinary first imports and existing live IDs are unchanged. Record content, source dates and conversation ordering are preserved.

If configured sync history is unavailable, no import is saved and the view explains how to reconnect/sync before trying again. The app does not report restoration success only to have its known deletion markers erase the result. Concurrent deletions not yet observed follow the vault's normal conflict/deletion rules. Knowledge-library suppression IDs and clear-before dates remain separate; restoring canonical text does not clear a previously deleted cached copy or reset retention settings.

Recovering an unreadable canonical store is different: before the confirmed backup recovery, any configured sync is durably paused and marked for review. The unreadable file and encrypted queue are preserved, and the backup becomes available locally. Automatic resume remains blocked. A separate explicit warning in Private memory sync explains that resuming the existing queue can remove recovered IDs already deleted from the vault and propagate omissions from the recovered backup. Cancel keeps recovery local. This applies to both JSON backup and encrypted-file recovery; local-only recovery without a configured vault keeps its prior behavior.

## Bounds and privacy

- Selected source: maximum **16 MiB**; one file at a time. A larger file must be split into complete valid JSON arrays, or a numbered export part selected. No silent truncation.
- JSON structural pass: depth 64, 300,000 value tokens, raw string token at most 800,000 bytes. Duplicate keys, including Unicode-escaped equivalent spellings, reject the file before Foundation can overwrite them.
- Conversation arrays: at most 2,000 conversations, 50,000 nodes total and 10,000 nodes per conversation. Oversized conversation records are reported as malformed/oversized skips. Oversized whole-file quotas reject the file.
- Supported message body: at most 98,000 characters, with a final 100,000-character canonical ceiling including provenance. Memories: 10,000 per file, 20,000 characters each.
- Final **merged canonical state**: at most **5,000,000 bytes**, **10,000 notes**, and **10,000 chat entries**, checked through `MemoryBackup.encode`. If the selected items do not fit, the app refuses them and asks for a smaller subset. A single conversation exceeding available capacity is not split automatically. Existing data is never evicted.
- Selected-file access holds system security scope and coordinated read, opens using `O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC`, uses `fstat` to require a regular file, reads at most the cap plus one sentinel byte, and checks size, mtime and ctime afterward. Symlinks, directories, FIFOs, excessive size and changed files fail closed. No source path, access bookmark or reusable permission is stored.
- Existing `KnowledgePolicy.isSafe`/`MemorySearch.canSave` credential heuristics protect stored titles and text. Suspected credential-containing conversations are rejected as a whole, and suspicious notes are skipped/rejected. Filename checks exclude credential-like names. This is not a complete secret detector; the UI instructs the user to review all private content.
- Cancelling a preview explicitly cancels both the UI awaiter and retained detached reader. Reader chunks, JSON lexical scanning, tree validation and message/memory iteration check task cancellation; cancellation is not converted into a skipped-record result. Bounded synchronous Foundation/provider operations cannot be forcibly interrupted mid-call, but cancellation is checked before subsequent parsing or publication.
- Errors and skipped categories are fixed safe strings. No source content, filenames, local paths, provider errors, token values or raw JSON snippets are logged. Preview content intentionally appears only in the user's local review UI.
- The local assistant may retrieve imported text under the existing memory/index settings. Hosted mode does not automatically read canonical chat or memory; it receives imported text only if the user explicitly includes and reviews it there. Explicit backup/transfer features follow their own authorization. This importer does not make a network request.

## Integration contract

Import code is isolated in `App/ConversationImport*.swift`; existing models are unchanged. `MemoryBackup.merge` has a narrowly scoped stable equal-date ordering fix so source branch order survives canonical persistence. In the current Memory navigation stack:

```swift
ConversationImportView(
    project: capturedCanonicalProject,
    savedState: store.saved,
    onImport: { additions in
        // Recheck active account/project identity and successful canonical state load.
        // Reject a changed identity even if the displayed project name is unchanged.
        let merged = MemoryBackup.merge(additions, into: store.saved)
        _ = try MemoryBackup.encode(merged)
        try disk.save(merged)
        store.saved = merged
        knowledge.captureSavedState(merged) // optional; indexing failure is independent
    }
)
```

The snippet is conceptual: use the store's actual persistence methods and access control. The closure receives **additions only** and must either commit successfully or throw. Validate against the latest canonical state, not only the preview snapshot. Bind view identity to the account/project session, and dismiss/invalidate it on sign-out, account switch, project change, or failed canonical load. The preview view rejects a changed project and late read completions, but cannot know the parent's account identity. Never permit a stale route to save into another account with the same project name. No separate cache import API or account synchronization is implied.

After a successful canonical save, use the normal `captureSavedState` hook if conversation capture is opted in. Canonical memories continue to use the existing note store/search. As documented in `KNOWLEDGE_CACHE.md`, optional indexing can reject/cap records independently and must expose that coverage without undoing a successful canonical save.

## Implementation and verification checklist

- [x] Define supported format and additive API without modifying canonical models.
- [x] Add synthetic XCTest cases for active branches, roles, provenance, dates, duplicates, cycles, dangling parents, unsupported modalities, credentials, explicit restore acknowledgment, canonical capacity, memory formats, strict ASCII identifiers, final equal/missing-date merge order, duplicate preservation, cancellable reader/parser tasks and safe selected-file reads.
- [x] Implement bounded lexical validation, parser, deterministic identities and local preview/selection UI.
- [x] Document official export path, unsupported data, finite limits and integration obligations.
- [ ] Run XCTest and full iOS build with Xcode 26 on macOS. The Linux implementation environment has neither `swift` nor `xcodebuild`; these tests have not been executed here.
- [ ] Exercise the native document picker, cancellation, per-item review/back navigation, subset import, duplicate reimport, deletion/reimport acknowledgment, and account switching on the simulator/device.

All checked-in examples are synthetic. Real user exports, private memory, credentials and source paths must never be included in public tests or commits.
