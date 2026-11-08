# Bundled integrations

Asterion Veyra has a compile-time integration catalog and a standalone SwiftUI
`IntegrationsView`. These declare existing features; the catalog does not execute
an action, connect an account, probe a network, fetch credentials or load plugins.
It is not dot or ChatGPT and does not inherit their plugins, accounts, tokens,
subscriptions, models or permissions.

## What is bundled

| Stable adapter ID | Version | Implemented feature | Recipient and setup |
| --- | --- | --- | --- |
| `apple.local-model` | 1.0.0 | Apple Foundation Models answers in Assistant | On-device inference. Requires available Apple Intelligence on supported hardware. |
| `local.memory` | 1.0.0 | Project note search and user-selected note saving | App-local storage. Backups/exports remain separate explicit flows. |
| `github.read` | 1.0.0 | Pinned directory listing and text-file reads | `https://api.github.com:443`. Public reads need no token; private reads use the separate read connection. |
| `openai.hosted` | 1.0.0 | An explicitly reviewed Responses request in Hosted | `https://api.openai.com:443/v1/responses`. Existing user-provided API key, direct installation and separate API billing. |
| `github.proposals` | 1.0.0 | One reviewed file on a new branch with a draft PR | `https://api.github.com:443`. Separate write session and exact diff/destination review. No merge or automatic publication. |

Only these five adapters are registered. A built-in descriptor is not evidence of
a configured account or successful runtime test. Hosted and proposal features
remain opt-in. Nothing in the registry acquires or saves a credential.

## Data boundary

Each operation declares an access category (`read`, `send` or `write`), typed data
categories, a fixed recipient, a resource kind and a consent policy. Descriptions
in the UI explain both outgoing data and setup boundaries. GitHub read credentials
are optional: public reads do not send one. Hosted input is the explicitly entered
question/context and model ID, never automatically appended memory, history or
repository attachments. Proposal input is the reviewed file and PR metadata.

The existing transports still own endpoint and route validation, redirect
rejection, request/body limits, cancellation and session checks. The GitHub
recipient is a fixed HTTPS API origin; the selected repository, commit and path
are exact resource fields, not unrestricted hosts or URL templates. No credential
value, request body, file contents or arbitrary URL is stored in the catalog.

## Immutable policy grants

`IntegrationRegistry.approve` creates a memory-only immutable grant for an exact
invocation, only when called as a trusted user action. There are **no default
grants**, including read grants, and no inherited write permission. Each grant
is bound to the registry instance, adapter, operation, resource, recipient and
exact declared data categories. It cannot authorize a different project,
repository, pinned revision, path or review ID. Wildcards, traversal, likely
credential paths, mutable branch names and unknown tools are rejected.

`validate` is a policy preflight only. It never dispatches or executes an action.
A model cannot create grants or expand scopes, and can only validate an already
granted operation specifically marked as a read tool. Hosted sending and draft
PR publication are never model-callable. Network operations fail closed when the
snapshot is offline **or network availability is unknown**. Local features require
a positive app-supplied availability state before policy approval.

For remote sends/writes, `approve` also requires the exact reviewed invocation.
This does not independently prove that a person reviewed anything. The caller
identity and reviewed invocation must come from trusted app UI, never model text,
server responses or deserialized tool arguments. Neither is exposed as a model
tool. A hosted/proposal review UUID identifies the existing immutable preview,
not a free-form payload supplied by a model.

The policy layer deliberately does **not** replace the existing live session,
credential expiry/revocation, single-use consent or exact-payload checks in
`HostedAuthSession` and `RepositoryProposalPublisher`. A grant is not an executor
capability or reusable approval to send a paid request. Execution is not wired to
this registry: the existing explicit feature screens continue to own all actions.
An integration must not be routed through these declarations until those runtime
checks are preserved and reviewed end to end.

## Runtime state and navigation

`IntegrationRuntimeSnapshot` accepts app-owned network, local-model, local-memory
and optional session flags. Its defaults do not assert a network connection,
model readiness or hosted/write session. No state here performs a network probe.
The UI distinguishes available, bundled-but-unverified, setup-required,
offline-unavailable and unavailable-on-device states. Even an available state is
not proof of billing entitlement, provider authorization or a successful request.
A stale snapshot is not allowed to replace the adapter's live session checks.

The parent UI can construct:

```swift
IntegrationsView(
    runtime: IntegrationRuntimeSnapshot(
        localModelAvailable: modelAvailable,
        memoryAvailable: !store.loadFailed
    ),
    navigation: IntegrationNavigation(
        openAssistant: { /* navigate to Assistant */ },
        openMemory: { /* navigate to Memory or Knowledge */ },
        openProjects: { /* navigate to Projects */ },
        openHosted: { /* navigate to Hosted */ },
        openProposals: { /* open selected repository's proposal review */ }
    )
)
```

The view owns a `NavigationStack` and is suitable as a tab or presented sheet.
All hooks are optional. If a proposal hook is absent but Projects is available,
the proposal row offers project selection. No hook runs on appearance. Hooks
must navigate only, not transmit data, publish, sign in or grant permission.
No dependency on a Knowledge screen's types is required.

## Adding an adapter

1. Implement `IntegrationAdapter` in the reviewed app source with a stable ID,
   explicit semantic version, truthful data disclosure and immutable descriptors.
2. Declare every operation's exact resource/data/recipient/consent requirements.
   Do not add raw URL, shell or downloaded-code execution hooks.
3. Register it in `bundled()` and add explicit runtime availability checks. Unknown
   adapter IDs never acquire availability just because a descriptor exists.
4. Build a user-owned setup/review flow with an appropriate credential boundary.
   Runtime validation, cancellation, bounded responses and safe diagnostics belong
   in the transport adapter, not in model prompts.
5. Add tests for unknown operations, scope widening, recipient changes, offline
   behavior, absent/expired consent and redaction before wiring any execution.

Registration rejects duplicate integration/operation IDs, invalid versions/IDs,
model-callable writes and remote sends/writes without per-request review policies.
`redactedMetadata` emits only stable adapter ID/version, operation count and
availability. Grant/invocation descriptions and reflection omit private scopes.
No provider error, repository path, account name, prompt or credential is logged.

## Future MCP interoperability, not current support

Remote MCP servers, third-party OAuth and plugin installation are **not
implemented**. A future MCP adapter may map an explicitly allowed MCP tool name
and versioned JSON schema to a compiled descriptor. Server-advertised tools and
schemas are untrusted input, not permission grants. The adapter must reject
unknown tools and scope changes, pin the approved server recipient, enforce
bounded results and validate output. Setup must obtain appropriate user consent
for account access; neither a manifest nor a model can provision credentials,
expand scopes or silently select a new recipient.

The registry intentionally has no MCP discovery request, OAuth flow, downloaded
code loader, arbitrary shell, auto-install action or inherited dot connector.
Documenting this boundary does not make a remote plugin available.

## Verification

`Tests/IntegrationRegistryTests.swift` covers duplicate IDs, unknown operations,
missing grants, exact project/repository/commit/path and recipient/data scopes,
model permission escalation, offline and unknown-network denial, offline memory,
write/review restrictions, session-state changes and metadata redaction. Tests do
not call live services. Xcode 26 is required to execute native XCTest and verify
SwiftUI behavior. This Linux authoring environment has no Swift/Xcode, so native
tests and simulator interaction are not claimed as locally executed.
