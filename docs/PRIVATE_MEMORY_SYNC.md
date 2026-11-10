# Private encrypted memory sync

The iOS app includes an opt-in automatic sync client for an explicitly selected, user-owned private GitHub repository. Open **Memory → Private memory sync**. No repository, credential or encryption passphrase is provisioned by the application, and none is embedded in the public source or build.

## One-time setup on each device

1. Use a directly installed app. Do not enter credentials into Strata or another app host.
2. Enter the exact `owner/private-repository` destination. The app checks GitHub's authenticated account ID, repository ID, owner ID, private visibility, default branch and write permission. Public repositories and the public application-source repository are rejected.
3. Create a fine-grained GitHub token limited to that repository with **Contents: Read and write** and the required metadata read access. A token from the ordinary read-only repository browser is never reused.
4. Choose a strong shared recovery passphrase of at least 12 characters. Keep it somewhere safe outside the repository, and enter the same passphrase on every device. Existing encrypted content is checked before setup completes. The app cannot recover a lost passphrase and does not rotate a vault key by accepting a different passphrase.
5. Review the destination and included data. Private GitHub workspaces require a separate switch and must belong to the verified GitHub account. Then explicitly allow automatic transfers and saving the token and passphrase in this device's Keychain.

The encrypted queue and nonsecret configuration use the operating system’s default file-protection class plus owner-only permissions. They may be included in operating-system backups; the queue remains encrypted and still needs the recovery passphrase. POSIX permissions are not a promise of iOS Complete Data Protection or backup exclusion.

The token and passphrase are kept in a dedicated, nonsynchronizing, device-only Keychain item available while unlocked. They are not embedded in backups, documents, source code, status messages or diagnostics. Setup cancellation and failed verification do not enable unattended sync. Each network operation uses a revocable session and fixed `https://api.github.com` routes. Redirects, ambient cookies and proxy configuration are disabled. Error bodies are not read or displayed.

## Included and excluded data

The encrypted document contains:

- Canonical app notes and saved user/assistant chats, with their project names, source labels, IDs and dates.
- Eligible scoped offline-knowledge copies: captured conversations, saved research text and provenance, deliberately imported text-file copies, and fixed app-action summaries.
- Record deletion markers, per-library suppression IDs and clear-before markers needed to prevent old devices from restoring deleted copies.

Private GitHub workspace data is excluded unless separately enabled. Even when enabled, another GitHub account's workspace is excluded. A remote vault's private-workspace scope must match this device's explicit choice; the app does not silently replace a broader vault with a filtered snapshot. Disconnecting stops all transfers if the existing scope is no longer appropriate.

Credentials, settings, arbitrary device files, unimported attachments, background microphone recordings and detected secret-bearing content are excluded. Secret detection is only a warning layer, not a guarantee; do not save secrets. A selected text-file copy is included, not ongoing access to that file or its original device path.

New offline libraries capture eligible conversations, fixed activity summaries and successful research by default. Existing saved capture preferences, including disabled switches, remain unchanged. Sync cannot upload sources that were never captured. Legacy libraries that did not save a scope descriptor are discovered through known canonical project names; opening a legacy project registers its library for later discovery. Scope-denied, corrupt or locked libraries are not interpreted as empty deletion requests.

Manual chat/note JSON backups and manual encrypted transfer keep their existing formats and **do not include the separate knowledge library**. The private sync document is a separate format.

## Automation and safe failure

The app syncs on launch, foreground return, local changes, restored connectivity and a bounded foreground interval. Changes are debounced, and expensive key derivation/encryption runs off the main actor. A single coalesced encrypted queue is persisted before each write. Transient failures use bounded exponential backoff with jitter. Bounded `Retry-After` and `X-RateLimit-Reset` cooldowns are persisted and honored even for manual retries. Permanent validation, identity, scope, credential or capacity failures stop retries and display a reason.

iOS may suspend or terminate an application in the background. Continuous unattended background execution is not guaranteed. Open the app on each device and check the successful-sync timestamp before relying on a transfer or uninstalling an app. This implementation does not enable automatic sync in the Android or desktop clients.

Limits are deliberately finite:

- At most **8 MiB** of decoded sync JSON, including notes, chats, library copies and deletion history.
- At most **17 MiB** of decoded local queue JSON containing its baseline and one pending full snapshot.
- At most 30,000 total content records, 20,000 canonical note/chat tombstones and 256 knowledge scopes. Existing per-record, per-library and 5 MB canonical-backup validation limits also apply.

Nothing is silently truncated or evicted to fit these limits. If full, keep additional backups and reduce selected content only after reviewing it. Deletion history itself consumes space and is not automatically discarded. There is no automatic tombstone compaction or Git history rewrite.

The first setup writes the queue before enabling sync. If a configured device later loses its queue, syncing fails closed: an empty replacement baseline could resurrect deleted content. Reconnecting does not override that protection. Preserve the local canonical data and restore a verified queue/backup before recovery; there is no destructive one-tap reset. A newly configured device without prior configuration starts with an empty baseline and safely unions its local records with the verified remote vault.

A separate durable flag records that a remote vault has been seen. If that file subsequently disappears, including between setup and the first sync, the app stops instead of recreating it and discarding unseen deletion history.

## Merge, deletion and retention

Writes use GitHub's expected content SHA, never force overwrite. A conflicting update is fetched and merged before retry. An uncertain write is read back on the next attempt rather than blindly repeated. A three-way merge preserves simultaneous differing note/chat versions with stable conflict-copy IDs. Identical captured content converges while retaining provenance. Immutable knowledge-source conflicts fail closed rather than overwriting content. Library clear and suppression markers are merged monotonically, and canonical chat deletion also suppresses its cached mirror.

Identical Luma checklist snapshots imported independently on two devices keep one shared identity when only their import-time saved date differs. The merge retains the earlier import time and leaves text, provenance and workspace unchanged. Identity, workspace, text and source must match byte-for-byte in UTF-8; visually equivalent Unicode spellings with different bytes keep the normal conflict behavior. This narrow rule includes explicitly restored UUIDv8 snapshots; ordinary notes, source-dated Luma notes and existing UUIDv5 conflict copies retain their previous merge behavior. Different filenames are different provenance and are preserved. Previously created duplicate copies are not automatically removed. If reconciliation changes a reference that is already open in planning, review the question again before sending.

Deletion removes a record from the current synced view, not from all historical copies. Earlier encrypted versions can remain in GitHub commit history, clones and backups. Disconnect removes this device's sync credential but keeps local memory, the encrypted queue and remote history. The app never automatically rewrites or purges Git history.

The private repository is verified immediately before each write as well as before reads. GitHub has no atomic API combining a visibility assertion with a content write; a repository administrator changing visibility at that exact moment is a residual risk. Encryption is therefore required even for private repositories. Anyone with both the encrypted data and recovery passphrase can read it.

## Explicit imports and local recovery

A confirmed conversation or backup import into a readable store checks already verified sync deletion history. Known deleted note/chat IDs are restored with stable new UUIDs while their old tombstones remain. Repeating a restoration keeps the existing restored copy; deleting that copy and explicitly restoring again creates the next identity. Ordinary first imports retain their IDs. If configured history is unavailable, import stops with an explanation instead of reporting a false restoration. Newly arriving concurrent deletions still follow the normal sync conflict rules. Knowledge-library suppression and clear-before markers are not reset by a canonical import.

A confirmed recovery of an unreadable canonical file first durably pauses configured sync and records that recovery needs review. The unreadable file and encrypted queue remain preserved; recovered memory is available locally. Reopening the app or reconnecting credentials does not clear that review flag. The sync screen requires a separate explicit confirmation before resuming: the existing deletion rules can remove previously deleted recovered IDs, and omissions from the recovered backup can propagate to other devices. Keep another backup before proceeding, or cancel to leave the recovery local. No history is silently reset.

## Wire format and verification

`veyra-memory/v1.sync` is one authenticated encrypted file. Its 14-byte header is `VEYRA-SYNC` followed by three zero bytes and version byte `01`. The remaining envelope is 16 random salt bytes, 12 random nonce bytes, AES-256-GCM ciphertext and a 16-byte tag. PBKDF2-HMAC-SHA256 uses 600,000 iterations and a 32-byte key. The first 42 bytes, including the header, salt and nonce, are authenticated as additional data. Passphrase UTF-8 bytes are preserved without Unicode normalization.

The version-1 JSON document binds the immutable numeric repository ID and private-workspace inclusion flag. An explicit `chatOrder` UUID sequence preserves equal-date imported conversation turns. Independent source sequences are merged deterministically; same-ID, same-content fallback timestamp differences choose the earliest date rather than duplicate messages. Foundation JSON dates are seconds since 2001-01-01T00:00:00Z. No settings or credentials are schema members. The local queue uses the same domain-separated envelope but a different typed JSON schema and larger size cap. Manual transfer files have different authenticated headers and cannot be mistaken for sync documents.

GitHub metadata requests use the object media type. Large ciphertext is downloaded as a bounded raw immutable Git blob and verified against its Git object SHA, rather than following a download URL or mutable branch. The maximum upload is bounded before base64 encoding. On-device queue/configuration reads open the operating-system-provided app container directly, then walk only its descendants by no-follow descriptors. They do not read `/`, `/var` aliases, or other system ancestors that the iOS sandbox may deny even while allowing the app's own files. Paths outside the container and symlink descendants are rejected. Writes retain exclusive temporary files and descriptor-relative atomic rename, preventing app-controlled ancestor or leaf symlink redirection.

Storage failures identify configuration versus queue access and include only a fixed operation/stage label and, when available, a numeric POSIX error code. No path, repository, content, credential or underlying error text is retained in these diagnostics. An unreadable existing configuration still blocks fresh-history setup, and missing/corrupt configured journals still fail closed. This change does not reset, migrate or delete saved files or credentials.

A traverse-only-ancestor fixture exercises configuration reads, atomic replacement and encrypted-journal persistence separately. A POSIX reproduction demonstrates why reading each system ancestor is unnecessary; it is not a reproduction of a particular physical iOS sandbox. The signed-device startup and setup flow still need verification, and any remaining error should be investigated using its sanitized diagnostic code.

`Tests/Fixtures/private-memory-sync-v1.json` contains public synthetic data. `scripts/private_memory_sync_reference.py` is an independent, read-only format verifier, not a deployed desktop sync client. Its Python tests check interoperability, tampering, passphrase rejection and bounds. Native XCTest covers merge/deletion, scope/repository identity, storage, optimistic concurrency, uncertain-write read-back, cancellation and lost-history failures. Native build and simulator tests still need to run on Xcode 26; passing Python checks alone does not establish Swift type correctness, UI behavior or device security.

### Editable checklist copies

Jarvis's optional Luma editable copies are typed envelopes inside existing notes, so canonical/wire schemas and tombstone types do not change. The outer note UUID remains authoritative after a conflict copy or explicit restoration. Same-ID UUIDv8 copies with fully validated current envelopes, exact UTF-8 text/project/source and different creation/import dates reconcile to the earlier date. UUIDv5 conflict copies retain prior date-conflict handling. Edited payloads use the existing three-way comparison: one-sided changes survive, and distinct concurrent versions remain visible with separate IDs. No origin-based grouping hides either version. Reimport keeps existing live or restored edited copies. Editing preserves creation time, origin text, provenance, workspace and outer ID. It never rewrites the original snapshot or clears tombstones.
