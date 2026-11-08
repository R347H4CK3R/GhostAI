# Bounded offline knowledge

## What this increment provides

`KnowledgeCache` is a separate, durable local SQLite/FTS5 library. It does not replace `SavedState`, synchronize an account, crawl the web, read other apps, monitor a microphone, or scan folders. No third-party package is required. Its built-in indexed chunks support local search even when network access and on-device language generation are unavailable.

Automatic capture is **off by default**, separately for conversations, fixed app-action summaries, and successfully read research text. Enabling conversation capture indexes eligible existing saved conversations in the selected workspace and future successfully persisted messages. Turning capture off stops additions but leaves existing copies searchable. Deletions in the canonical chat are still reconciled while capture is off. Canonical notes remain in their existing store/search tool and are not copied here.

This library survives ordinary app restarts. **Canonical chat/note backups do not include it.** No cache export/migration is implemented in this increment. Uninstall, device replacement, or loss of the device can lose imports/action history. The UI states this explicitly. It is excluded from device backup to avoid implying that it is synchronized or portable.

## Data, provenance, and scopes

- `KnowledgeScope(accountID:project:repository:)` requires an explicit stable account identity and canonical workspace. Use `device-local` for local-only conversations; use the authenticated GitHub account's stable numeric ID for GitHub workspaces. Never use a token, account display name, or the same scope for different accounts.
- `repository` is optional, but required for repository research capture. The research source's repository must match it exactly. The app must provide the canonical selected repository name. A scope does not confer authorization to read a repository.
- SHA-256 of the identity/workspace tuple selects a separate database directory under one shared application-support `Knowledge` root. Metadata is checked against the expected scope on every open. A persisted optional repository binding rejects a different nonnil repository for the same workspace; repository:nil reopens offline copies without granting permission to capture new repository research. Search SQL has no route into another scope's database.
- Each record retains type, exact bounded text, source label, immutable revision/content fingerprint where available, source date, cached date, and UTF-8 source byte count. All sources are visibly **saved copies, not live**.
- Conversations use `chat:<canonical UUID>`. File imports use content SHA-256. Research uses source-label plus content SHA-256, so repeat reads deduplicate and cannot resurrect a deleted version. Refreshing changed source content creates a new immutable copy with its own provenance.
- Action content is generated exclusively from `KnowledgeActionKind` and `KnowledgeActionStatus`, plus source/date. There is no raw argument, error, header, credential or arbitrary action-summary field.
- A web source must be HTTPS without user-info, query or fragment. This intentionally rejects URLs carrying access keys and prevents preserving URL queries as provenance. No network request is made by the cache.

## Exact integration hooks

All model/cache methods are main-actor confined. Root integration owns account authentication, cancellation and selection changes.

```swift
// Reuse the SAME root for every account/project so the global quota is shared.
let scope = try KnowledgeScope(
    accountID: stableAccountID,
    project: canonicalWorkspace,
    repository: selectedRepositoryFullName // nil for local/non-repository work
)
let knowledge = KnowledgeLibraryModel(
    root: applicationSupportRoot.appendingPathComponent("Knowledge", isDirectory: true),
    scope: scope
)
```

Open the standalone view from Memory (inside an existing navigation stack):

```swift
KnowledgeLibraryView(model: knowledge, savedState: saved)
```

Pass the **full, successfully loaded canonical `SavedState`**, not just visible messages. If canonical disk loading failed, do not supply an empty placeholder as if it were a valid snapshot; that would reconcile away existing cache conversations.

After each successful canonical persistence, including chat/note saves, chat deletion, backup import/recovery, and on initial successful load:

```swift
try disk.save(next)
saved = next
knowledge.captureSavedState(next)
```

The hook catches cache failures independently. Never undo or report failure of a successful canonical save because optional indexing failed. Do surface the library's published status (for example, a Memory badge/status label), so full or unavailable indexing is not silently mistaken for complete coverage. The view also exposes rejected/suppressed counts and quota state.

Capture a successfully completed app action after its authoritative result is known:

```swift
knowledge.captureAction(
    id: stableActionID,             // reuse across retry/status callbacks
    kind: .repositoryRead,
    status: .succeeded,
    expectedScope: capturedScope,
    date: eventDate
)
```

An action ID identifies one immutable event/status, not an evolving task. Use another event ID if a later status represents a new event. Do not pass provider raw errors or request arguments. Permitted kinds are question, repositoryRead, sourceSaved, proposalReviewed, proposalPublished and fileImported; statuses are succeeded, cancelled, failed and uncertain.

After a successful, authorized source read (not after an error) and immediately after rechecking current account/session/project:

```swift
let source = try KnowledgeSource.repository(
    selectedRepositoryFullName,
    path: validatedRelativePath,
    commit: pinnedFortyCharacterCommit
)
knowledge.captureResearch(
    text: successfulValidatedSourceText,
    source: source,
    expectedScope: capturedScope,
    date: readDate
)
```

For an authorized research source read outside GitHub, use `try KnowledgeSource.web(url)` under the same explicit account/workspace lifetime. The cache never fetches a URL. If a source read exceeds the maximum text size, it is rejected, not silently truncated into a claimed full copy. Only text actually supplied is cached. Listing a repository does not cache its unread files.

### Offline model recall

Use either/both a bounded prompt excerpt and a read-only tool. Canonical notes can remain in `ProjectMemoryTool`; they are deliberately not duplicated.

```swift
let excerpt = knowledge.context(query: question, maximumCharacters: 1_500)
// Label excerpt as untrusted, possibly stale reference data in the model prompt.
let memoryTool = KnowledgeSearchTool(library: knowledge, maximumCharacters: 3_000)
// Add this fresh tool to this question's FoundationModels Tool array.
```

`context` is synchronous on MainActor (and can be awaited from another actor). It caps output at 6,000 characters. `KnowledgeSearchTool.call` is async, caps each call at 3,000 characters and a question's lifetime at three calls/6,000 characters. The budget is reserved before awaiting so concurrent calls cannot overspend it. Always instantiate a fresh tool for a new question. Search produces at most six bounded excerpts for model context, including source/date/offline warnings; it has no internet or write capabilities.

Before switching account/project, signing out, or revoking access:

```swift
knowledge.invalidate()
// Cancel in-flight question/source operations and discard their tools.
// Construct a new KnowledgeLibraryModel for the newly authenticated scope.
```

Invalidation closes that model's access and clears its displayed entries. Old tools cannot switch into the new scope. Every capture rejects an expected-scope mismatch and invalidated models ignore late callbacks. Root must still revalidate selection/session immediately before accepting any generated answer, as it already does for repository output: no retrieval API can retract text already returned to a running model.

## Selected files

Only the view's system document picker calls `importSelectedDocument`. It acquires/relinquishes security-scoped access, coordinates the read, opens a descriptor with O_NOFOLLOW/O_NONBLOCK, uses fstat to verify a regular file and its size, and streams at most **256 KiB + one sentinel byte**. Only UTF-8 text and an explicit text/source extension allowlist are accepted. The filename is stored, not the provider URL/full local path, access bookmark, or future permission. Hidden/credential-like filenames and known secret patterns are excluded. The descriptor is checked again after reading for size/mtime changes. No directory enumeration occurs outside the app's own cache quota bookkeeping.

Secret checks build on `MemorySearch.canSave`, with common provider tokens, JWTs, Authorization/Cookie headers, bearer values, credential URLs and hidden controls also rejected. These heuristics are not a guarantee and the UI warns accordingly. The caller must never feed raw request/response headers, login material, API keys, error bodies or failed provider results to research capture. Normal app actions avoid these categories by construction.

## Durability, quota, corruption, deletion

- Database/index/metadata writes are SQLite `BEGIN IMMEDIATE` transactions with `synchronous=FULL` and a DELETE rollback journal. Successful canonical deletions are committed separately from new capture so a later quota failure cannot restore deleted chats.
- Scope directories and database files use iOS complete file protection. This is device file protection, not a separate user-password vault. The directory also protects SQLite's temporary rollback journal. Opening a locked/inaccessible database fails without wiping it.
- **50 MiB total persistent SQLite database bytes across all scope directories under the shared root**. The allowance is recomputed for every transaction and enforced via SQLite page limits. Each database may contain at most 10,000 entries; source-text bytes are conservatively capped at about 12.4 MiB and may stop earlier due to the other scopes, indexes, or reserved deletion capacity. An additional bounded rollback journal can temporarily require up to the affected database's size during a write. No backup copies are made silently.
- There is no automatic eviction. Quota failure preserves existing items and displays a full status. SQLite FULL auto-vacuum reclaims freed database pages on commit; `secure_delete` is enabled. This is logical deletion, not a forensic-erasure guarantee on flash storage or external backups.
- Opening verifies `quick_check`, format version, scope, and required metadata. Corrupt/unsupported storage is preserved and blocked. There is no silent reset or destructive recovery button.
- Delete/clear/retention cleanup all require a confirmation dialog. Cache deletion leaves canonical chats, notes, original files and remote repositories unchanged.
- Deletion markers contain only stable hashed/UUID source IDs. Markers are retained across restart and reindex. Clear also advances an automatic-capture time cutoff, so enabling capture later cannot bring back old uncached history. Markers count toward the quota; capacity is reserved for them, and a hard marker limit blocks further additions instead of deleting suppression history.
- Retention is a **review threshold**, not automatic expiry. Users can choose keep-until-deleted, 30, 90 or 365 days and explicitly confirm deletion of eligible automatic captures. Intentional file imports never expire automatically.

## Validation

Native tests are in `KnowledgeCacheTests.swift` and `KnowledgeLibraryTests.swift`: opt-in/off behavior, durable reopen, account/project/repository isolation, safe literal FTS search, bounded excerpts, imports/secret filtering, corruption preservation, immutable research/deduplication, action schema, global quota/no eviction, retention, deletion tombstones, canonical deletion under quota failure, and late tool/model invalidation.

This Linux environment has no `swift` or `xcodebuild`, so native compile/XCTest/device protection/UI execution **has not run** here. Available SQLite SQL smoke checks and repository Python checks are reported separately; they do not substitute for iOS tests. Before release, run the repository iOS CI/unit/UI suite and on a device verify offline search after restart, enable/disable capture, cancellation of file picking/deletion, quota failure, screen dismissal on account change, and locked-device access behavior.
