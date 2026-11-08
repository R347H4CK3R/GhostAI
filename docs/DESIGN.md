# Repository assistant for iPhone: proposed design

Status: original design direction. A narrower iOS source prototype is now written; see README.md for actual implemented scope. SQLite, private credentials, online models, voice and runner capabilities below are future work.

## Intent
A separate personal iPhone app that can switch between GitHub projects, explain code, propose changes and remember project decisions. It should feel like a capable personal assistant while accurately identifying itself as a separate application. It does not inherit dot's model, accounts, conversation or internal memory.

## Recommended foundation
Native SwiftUI, iOS 26, Apple Foundation Models on supported devices with Apple Intelligence available. Detect model availability at runtime and give actionable unavailable states; never substitute a canned response as model output. iPhone 16 Plus is hardware-compatible, but availability also depends on software, language, region, settings and downloaded model assets.

## Approaches requiring the user's choice
1. Phone-first assistant (recommended first milestone): inference and memories remain local. GitHub network access retrieves selected repository source. Explains code and exports proposed edits; cannot run Xcode or execute arbitrary system commands on iOS.
2. Phone plus development runner: same local app with an explicitly paired computer or narrowly authorized CI workflow for builds/tests and reviewed branches. More capable but requires another execution environment, credentials and separate setup approval.
3. Optional hosted model: improves difficult reasoning, but selected code and questions leave the device and metered charges may apply. Explicit opt-in and data preview required. Not needed for initial local version.

## First milestone
- Repository picker with pagination and search within loaded results. Public repositories work without credentials; authenticated private repositories require a separately approved connection. Existing chat GitHub access is not transferred to the app.
- Read-only branch and source-file browser, pinned to a commit SHA. Network requests only to GitHub API, validated path segments, bounded response sizes, binary/oversize rejection, clear rate-limit and connectivity errors. No recursive whole-account scrape.
- Project conversation with explicit attached source excerpts. Answers label attached paths and commit; imported repository instructions are data, not permission to execute actions.
- Apple on-device response generation with cancellation and an honest context-budget display. Oversize requests split into deliberate steps or request a narrower file selection.
- Persist conversations and user-approved project notes locally. Notes have UUID, repository identity, text, provenance, creation/update dates and optional stale-after date. Use SQLite full-text retrieval, not load all history into every model prompt. Keep global preferences separate from project notes.
- Memory search/edit/delete/export/import. Default no automatic saving of secrets or every source file. Surface storage usage and write errors. Database migrations and export backups protect longevity; no promise of infinite storage.
- Proposed changes remain local drafts. Export source or a unified patch with original commit references. Applying to GitHub, publishing, installing dependencies, or running builds belongs to a later permissioned tool milestone.
- Text-to-speech can read an answer on demand. Voice capture is opt-in and must disclose whether recognition is actually on-device. No always-listening or continuous-background promise.

## Tool contract
Every tool declares name, input schema, data destinations, scope and side effects. Deterministic app code validates requests; the model cannot bypass it. Read operations stay within the chosen repository and current allowed files. Mutations require a visible diff and exact target approval. An operation has a cancellation handle, bounded resource budget, result/error and audit record. Future runners execute isolated jobs, never unrestricted shell commands with ambient account credentials.

## Knowledge growth
Memory can accumulate within available disk capacity. Retrieval supplies only relevant evidence within the model's finite context. Refresh selected GitHub sources while foregrounded or under iOS-supported scheduling; retain commit/date provenance and distinguish stale notes. No automatic permanent training of Apple’s model, guaranteed perfect recall, unlimited context, or always-current offline web knowledge.

## Security and privacy
Use iOS data protection for local stores; Keychain for future credentials. Do not ship tokens or ask users to put them into chat. No private source transmitted to a hosted model without explicit choice. GitHub App or fine-grained credentials should be restricted to chosen repositories with read-only permissions initially. No signing credentials in source or CI logs. Existing connected accounts must be linked separately in the new app.

## Acceptance gates
1. Unit tests: repository identity/path validation, bounded context selection, source staleness, memory persistence/retrieval/deletion, corrupted import rejection and migration rollback.
2. HTTP tests: pagination, 401/403/404/429, timeout/cancel, malformed JSON, redirected credential leakage prevention, oversized/binary file handling.
3. iOS compile and simulator UI: list/navigation, unavailable model, switching projects during generation, cancellation, repeated send, memory edits and relaunch.
4. Physical iPhone: offline inference, airplane-mode memory retrieval, thermal/memory behavior, voice privacy, signed installation and backup/restore.
5. Signed-device test remains necessary even if unsigned IPA packaging succeeds.

## Investigation evidence
- PocketForge already uses local Apple model features, targets iOS 26 and contains public GitHub discovery: https://github.com/R347H4CK3R/PocketForge/blob/main/README.md
- OmniForge contains SwiftLlama inference and a bounded local workspace agent: https://github.com/R347H4CK3R/OmniForge/blob/main/App/LocalCodingAgent.swift
- OmniForge keeps local chat history but not the proposed indexed, provenance-bearing memory architecture: https://github.com/R347H4CK3R/OmniForge/blob/main/App/AssistantStore.swift
- Existing OmniForge repository instructions prohibit renaming its app/data container; a separate app avoids disturbing it.

## Current verification limit
The assigned cloud workspace has no Swift or Xcode executable. An iOS source prototype has been written. No iOS build, signing, deployment, or physical-device test has been performed. A Mac with Xcode 26 or an authorized GitHub macOS CI job is needed for native compilation.
