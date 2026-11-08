# Cross-device direction and current milestones

The cross-platform goal is a shared assistant experience across iPhone, Windows and Android, with offline recall and bounded task execution. The first source prototype is native iOS, plus a runnable standalone Python desktop CLI for offline memory and explicit bounded plans. The CLI is not yet paired with the iOS app and uses a separate memory store. The 0.3.0 source adds manually transferred encrypted notes compatible between iPhone and desktop; this is not automatic sync. A practical next architecture does not assume SwiftUI or Apple Foundation Models work on Windows/Android.

## Shared protocol
Versioned envelopes for project identity, notes, source snapshots, task requests, approvals and tool results. Each note has a stable UUID, device ID, revision, source commit, creation/update timestamp and deletion tombstone. Conflict resolution retains both divergent edits until the user resolves them; wall-clock ordering alone must not silently discard work. Schema migration and full backup/export precede sync deployment.

## Clients
- iPhone/iPad: SwiftUI and Apple Foundation Models, local memory and explicit source attachment.
- Windows: a desktop companion with a local model backend suitable for available RAM/GPU and an isolated job runner.
- Android: a native or cross-platform client with local storage and an explicitly selected compatible local model. Model size, licensing and hardware support must be verified, not assumed.

## Sync
Opt-in pairing with authenticated devices, end-to-end encrypted note/task payloads, device revocation and recovery flow. Keep credentials out of the shared memory schema. Initial sync can be user-triggered; iOS background time cannot guarantee immediate continuous sync. Decide the transport and hosting with the user before introducing a cloud account or sending private code.

## Autonomous tasks
The desktop companion now implements a finite local plan/execute/observe/replan loop with immutable operator permissions, checkpoints, cancellation and fail-closed uncertain-write recovery. See [AUTONOMY.md](AUTONOMY.md). Live Ollama behavior and remote phone pairing remain unverified/unimplemented respectively.

The broader direction remains:
A visible queue stores goal, project/ref, allowed tools, resource budget, approval state and results. Read/inspect/search tasks can execute within the chosen project scope. Windows jobs run in isolated working copies, time out, and preserve logs. Proposed code changes produce a diff and test evidence before a reviewed branch is published. Never equate a model's claim of success with executed results. Destructive changes, external communication, purchases, credential grants and publishing need appropriate scoped approvals.

No unrestricted ambient shell, hidden signing access, unbounded execution, or remote command endpoint exposed without pairing/authentication. Only independently validated tool adapters receive access. Distinguish unsupported operation, permission required, queued, running, cancelled, failed and verified completion.

## Milestones
1. Compile/test iOS source; validate local inference, saved memory and cancellation on the user's phone.
2. Add robust SQLite-backed searchable memory, edit/export/import and migration tests.
3. Implement a Windows companion and protocol conformance tests, then opt-in encrypted pairing/sync.
4. Add Android client and offline model evaluation on the actual tablet.
5. Add individually tested tools and reviewed repository write operations; expand autonomy by capability, never by removing validation.
