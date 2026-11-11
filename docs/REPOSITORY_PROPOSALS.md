# Reviewed repository proposals

## Integration

Present `RepositoryProposalView(repository:immutableCommit:readClient:)` from the selected repository screen only after a nonempty immutable commit has been loaded. Pass the current `Repository`, the pinned 40-character commit and that selection's `GitHubClient`. The view does not use environment credentials, start requests on appearance or create a write session from the read client.

The screen is self-contained. Existing files do not need to adopt a new shared store. `project.yml` includes all `App` and `Tests` files, so no source-list change is needed. Navigation integration is owned by the parent task.

## User flow

1. Choose one existing file by relative path and explicitly load it using the current read connection. Resolve each ancestor in the immutable Git tree, reject links/submodules, then compare the decoded original's size and Git blob SHA-1 to its pinned entry.
2. Enter a complete replacement and a PR title. The original and replacement are each capped at 30,000 UTF-8 bytes. No model changes or repository instructions are executed.
3. Prepare a review containing both complete files, their byte counts, the exact repository ID/name, base branch, pinned source commit, unique new branch, title/commit message and complete PR body. No excerpting or hidden patch hunk is used.
4. Confirm direct installation. Enter a separately created, fine-grained GitHub token restricted to the selected repository with **Contents: Read and write** and **Pull requests: Read and write**, with a short expiration. The app cannot inspect or reduce all of a supplied token's permissions. Never enter this token in Strata or another hosted app; reliable host detection is unavailable.
5. Acknowledge full content review and the exact destination, including possible public exposure and repository automation/notifications. Confirm a final publication alert before any write-token request is sent.
6. See the individual blob, tree, commit, branch and draft-PR outcomes. A verified PR URL is constructed locally from the selected repository and validated PR number. A minimal protected local recovery receipt is saved before every possible write and after every known result. It contains repository/base/branch identifiers and per-stage status, never credentials, source, file paths or titles. Save/share a report explicitly if desired.

Editing the path, replacement or title invalidates the prepared review. Changes to the credential or installation acknowledgment clear publication acknowledgment. The final action also checks the current source, replacement, title, review identity and credential against the displayed snapshot. A read-session check runs at preparation and immediately before publication. Background/dismissal clears the token and approvals and cancels active work. Repository, pinned-commit or read-client identity changes close the screen to new requests and cancel active work while preserving its eventual status ledger. Reopen the screen for the new selection.

## Local change preview

The prepared immutable review includes a local changed-region comparison before the two complete files. It removes only identical leading/trailing lines; equal lines between separate edits remain inside the region. This is explicitly **not a minimal diff**. Old/new region counts are not minimal edit counts.

Comparison and no-op detection use exact UTF-8 bytes, including line endings, without normalization. Canonically equivalent but byte-different replacements remain reviewable; any byte change to the live replacement or title invalidates the prepared review and cannot match its approval. Empty files have zero lines; a trailing LF terminates its preceding line. The preview distinguishes LF, CRLF and no final newline, and visibly escapes backslashes, tabs, standalone CR, Unicode line/paragraph separators and trailing ASCII spaces. Line numbers refer to the complete original or replacement.

The first 12 old and 12 new region lines are displayed, independently bounded so one long side cannot hide the other. Each displayed line contains at most 240 UTF-8 bytes after escaping, clipped only between complete Unicode scalars/escape tokens. The preview reports omitted rows and shortened displayed rows separately. Both complete files remain unchanged and authoritative, and the complete-file acknowledgment is still required. The preview is not an executable patch or an automatic edit.

No network request, credential, source persistence or publication is added by comparison. It uses the existing text eligibility checks. Native pure tests cover exact comparison, newline/Unicode distinctions, escaping and bounds; an isolated DEBUG UI fixture displays the real review component with synthetic source and no ordinary app stores, credentials or network.

## Write capability and consent boundary

`RepositoryProposalAuthorization` wraps a new `GitHubAuthSession` but exposes a separate, repository-ID-bound capability type. It cannot accept an existing `GitHubConnection` or read-session token. There is no Keychain access, saved-token restoration, credential-generation, permission change or server-side token revocation in this feature. Unused token entry expires after 15 minutes without editing, and the publication credential session expires locally after 15 minutes and is revoked locally after any attempt, cancellation, background or dismissal. Swift strings cannot guarantee complete memory zeroization.

`RepositoryProposalSource` has a private initializer and is only produced by the verified loader. `RepositoryProposalReview` is immutable and generates a new UUID-based branch for each review. `RepositoryProposalApproval` has a private initializer and carries that exact review. `RepositoryProposalPublisher.publish(approval:currentReview:)` rejects mismatched approval, review or write-repository ID before network access. The publisher is single-use, even after an error, so it cannot silently replay a mutation.

Repository visibility is not guessed from a name or model response. Until GitHub is queried using the explicitly authorized write capability, the review conservatively labels visibility unknown/potentially public. No visibility promise is made even for a previously private repository. The preflight repository ID, canonical name and default branch come directly from GitHub and must match the selected repository.

## Allowed operation sequence

Preflight uses fixed GitHub API routes to verify:

- Repository identity and selected default branch.
- Base reference head still equals the pinned commit.
- Pinned commit's root tree.
- Every path ancestor is a tree, and the leaf is exactly an existing `100644` regular blob with the reviewed SHA and size. Executable `100755` files, symlinks and submodules are refused. The existing read client does not preserve executable mode, so initial source loading can display such a candidate; this write preflight rejects it before any mutation.
- Original blob bytes still equal the displayed original and its Git object hash.
- Base reference head **again**, immediately before the first mutation. If it moved, stop and require a new source/review. A later concurrent base change is still possible; the new commit always has the approved pinned commit as its only parent and never updates the base ref.

Then exactly these operations are possible, sequentially:

1. `POST /repos/{owner}/{repo}/git/blobs`: replacement bytes, Base64 encoded. Verify the returned blob SHA against the replacement.
2. `POST /repos/{owner}/{repo}/git/trees`: approved root `base_tree` plus exactly one approved `100644` file entry.
3. `POST /repos/{owner}/{repo}/git/commits`: approved title, new tree and exactly one parent, the pinned commit. Verify returned tree and parent.
4. `POST /repos/{owner}/{repo}/git/refs`: create `refs/heads/veyra-proposal/<review-UUID>` directly at the confirmed new commit. Verify exact ref and commit.
5. `POST /repos/{owner}/{repo}/pulls`: approved title/body, generated head, approved base, `draft: true`, `maintainer_can_modify: false`. Verify draft/open state, both repository IDs, base/head and new head commit.

There are no branch update, force update, base/main write, merge, delete, cleanup, arbitrary URL or automatic retry methods. New Git objects may be orphaned if later steps fail. A branch may remain without a PR. Nothing is deleted to hide partial work. Draft PRs and new branches may still trigger existing repository automation and notifications.

## Failure and cancellation

Each mutation has `notStarted`, `inFlight`, `confirmed`, `rejected` or `uncertain` status. A definitive 4xx rejection (except timeout 408) stops the attempt. A timeout, cancellation during a sent write, lost/oversized/malformed success response, unexpected destination, 3xx or 5xx response is treated as uncertain and stops all subsequent steps. No success response is assumed from a transport error. HTTP 401 revokes the write session.

Cancellation before a write sends no mutation. Cancellation after a confirmed step retains that confirmation. Cancellation cannot promise rollback. The result shows the exact proposed branch, confirmed object IDs and whether the draft-PR request was sent/confirmed/unknown. The same publisher cannot retry, resume or replay. The user must inspect GitHub before deliberately preparing another attempt, especially when a result is unknown.

The write-ahead ledger is saved atomically to app-private Application Support, with complete iOS file protection and exclusion from backups. Every possible POST is preceded by a successful `inFlight` save. The first write uses an atomic claim under a process-wide store lock: it checks existing attempt IDs and unresolved repository receipts and persists ownership before returning. Separate coordinators and windows cannot claim the same attempt or an unresolved repository concurrently. Later updates require that process-local lease; the lease is released after the terminal outcome. Inspection uses compare-and-swap under the same lock and cannot overwrite a still-active or newer receipt. A failed save prevents that POST; a failed outcome save prevents the next POST. A process kill therefore leaves an unfinished/unknown receipt, rather than silently reopening publication. Files contain only repository ID/name, generated branch, base branch/commit, timestamps, result and per-stage statuses. Receipts are bounded to 16 KB each; invalid, unreadable or nonregular entries fail closed. The 501st attempt is refused before a write with an explicit local-receipt-capacity error; existing records remain readable. No automatic receipt deletion occurs.

On reopening, unresolved receipts for the selected repository block new publication and offer verified repository/branch/known-PR links. Saved `inFlight` means UNKNOWN, not a live background task. The user must inspect GitHub and explicitly record that inspection locally before starting a different review; this does not modify GitHub or delete the receipt. The same review ID is never replayable even after inspection, and there is no automatic recovery request. Completed receipts also prevent reuse of that attempt. A locked device may make protected receipt storage unavailable; publication then stays blocked. Uninstalling the app loses local receipts, so repository inspection is still necessary after reinstall or device-storage loss. The app does not guarantee physical power-loss durability beyond the OS atomic-write contract.

## Network and content restrictions

- HTTPS `api.github.com` only. Every URL is constructed from validated selected scope and fixed routes before attaching authorization. No caller/model/server-provided endpoint is accepted.
- No redirects, cookies, cached credentials or configured HTTP/SOCKS/PAC proxies. Ephemeral sessions use system TLS validation and reject other authentication challenges. This does not secure a compromised device, host or installed trust root.
- Per-response streamed cap of 180 KB, request/resource timeouts, finite path depth and request count. Initial source loading has separate byte/depth budgets. Error bodies are not consumed; upstream errors, raw requests and credentials are never displayed or logged.
- Files must have common source/document extensions. Hidden paths, URL/encoded/traversal/control syntax, deployment/CI/script directories, build manifests, credential files and likely security/auth/session/crypto/payment filenames are denied. Configuration formats such as YAML/JSON/plist are intentionally excluded.
- Original and replacement must be bounded UTF-8 text without binary/control/bidirectional hiding characters or detected credential patterns. These conservative checks can reject innocent text and cannot prove that arbitrary code is safe or secret-free. The complete user review remains necessary. Broader or security-sensitive edits must be made outside this narrowly scoped feature.

## Verification

`Tests/RepositoryProposalTests.swift` uses injected deterministic transports and synthetic public examples only. It covers path abuse, secret/binary/size filtering, pinned blob mismatch, direct-install/write-session separation, changed approval, cancellation before and during a write, atomic receipt reload after a simulated process kill, concurrent same-attempt claim, active/stale inspection acknowledgment, write-ahead ordering, failed first/outcome saves and corrupt recovery storage, the exact create-only sequence, base movement (including the last preflight read), executable/link/submodule rejection, partial branch/PR outcomes, unknown transport/response states, HTTP 401 revocation, no replay and network policy configuration.

No real credential or live GitHub mutation is used during development or tests. This Linux workspace has no Swift/Xcode toolchain. Native build/test execution must occur in the repository's existing macOS/Xcode CI; local whitespace/source checks do not establish that native tests pass. Test sources were written before their adapters, but the red/green native cycle could not be run locally.
