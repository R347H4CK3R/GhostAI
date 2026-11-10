# Editable Luma checklist copies

## Intent
Move the combined iPhone assistant beyond immutable Luma references without replacing original snapshots or turning imported prose into permission. One explicitly selected Luma task row can become one editable Jarvis checklist copy: goal, step and completion status. There is no scheduling, execution, model call or new network destination.

## Chosen approach
The implementation choice is an opt-in typed, versioned checklist payload carried inside an existing MemoryNote. This is not a generic note editor: the app validates and edits only the three checklist fields, and retains immutable source snapshot ID, text and provenance. It uses the existing v1 canonical, backup, encrypted-transfer and private-sync paths without introducing fields older clients would silently omit. Older clients can preserve and display the plain-text envelope. Unknown or invalid envelopes remain visible as ordinary notes.

Alternatives considered: a new SavedState.tasks collection would require a coordinated schema migration across every sync, backup and recovery consumer; parsing old snapshot strings would be ambiguous because original fields can contain line breaks and delimiters. Neither is needed for this bounded increment. Existing imported snapshots are not converted implicitly. Select the original plain Luma backup again to create editable copies from validated structured fields.

## Product behavior
- Luma import has a separate default-off “Create editable checklist copies” option. Supported original snapshots are still imported unchanged. The review shows exactly which tasks will also receive copies; explicit acknowledgment and import confirmation remain required.
- Deterministic copy identities include workspace, original snapshot ID, exact source provenance and the original structured goal, step and Boolean. Legacy snapshot bodies are ambiguous when fields contain separators, so they alone cannot identify an editable version. Reimport cannot overwrite a live edited copy. Deliberately restored copies use existing deletion-history handling.
- Memory offers checklist rows and a native editor. Goal is 1–300 UTF-16 units, step is 1–400 UTF-16 units; original whitespace and Unicode are retained. Completion is a Boolean. Possible credentials and unsafe controls are rejected. No silent truncation.
- Edits remain local until explicit Save. Cancel, Close and interactive dismissal make no change. An immutable original note and workspace epoch guard Save; source deletion, changed content/provenance/date, or workspace round trips invalidate stale editors. A successful atomic canonical save precedes UI success. Outer savedAt remains creation/import time on edits, not a last-modified timestamp.
- Original Luma snapshot content and provenance never change. Typed copies carry their original source for review. No source path, credential, bookmark, permission, account, setting or job is migrated.

## Data and sync constraints
Keep SavedState version 1, note/chat schemas, encrypted-transfer keys, bundle ID, paths and release gates unchanged. Every import/edit preflights the merged 5 MB / 10,000 note / 10,000 chat budget. Included copies follow the user's already approved encrypted-sync scope; UI must disclose this. No automatic eviction.

Exact same typed-copy bytes and provenance with different local creation/import dates may reconcile to the earlier date. Genuine edits retain existing three-way merge behavior, with concurrent versions preserved as separate notes. Do not treat user text as authenticity or authority. Permanent tombstones and explicit restore identities remain unchanged. Strict wrapper recognition rejects unsupported versions, unknown fields, malformed or duplicate keys and unsafe values without hiding the original note.

## Non-goals and gates
No full Luma parity, background task runner, task dependency graph, reminders, repository-write expansion, Android work or physical-device claim. Public release still requires all existing exact-head PR and release gates, independent asset verification, and truthful unsigned-device limitations.
