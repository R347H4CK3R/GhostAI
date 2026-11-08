# Capability Expansion Implementation Plan

**Goal:** Add private project access, scoped repository tools, encrypted transfer and bounded desktop autonomy while preserving build 10.

**Architecture:** Native Swift security and tool adapters remain independent of stored model context. Desktop jobs reuse existing validated tools, and encrypted transfer uses authenticated versioned envelopes without a network transport.

**Tech Stack:** SwiftUI, FoundationModels, Security/Keychain, CryptoKit/CommonCrypto; Python standard library plus existing cryptography dependency.

**Spec:** NEXT_CAPABILITIES.md

## Global constraints
- iOS 26+, no embedded credentials, no automatic credential provisioning.
- Public repository contains source and synthetic fixtures only.
- Preserve the verified version 0.2.0 build 10 IPA as a separate candidate.
- Existing test suite stays enabled. No physical-device success claim from CI.

## Review focus
- Credentials must not follow redirects or appear in memory, backups, model prompts or errors.
- Account changes must revoke old clients and avoid mixing private workspace state.
- Wrong passphrases, malformed schemas and oversized imports must leave memory unchanged.
- Model-produced plans cannot widen operator permissions or replay uncertain writes.
- Cancellation and total budgets apply across tool calls, not just per individual request.

## Task 1: Private GitHub session
- [ ] Add failing request-boundary and session-revocation tests.
- [ ] Implement GitHubCredentialStore and client request injection with fixed-host validation.
- [ ] Add explicit connect/save/signout controls and account-scoped repository browsing.
- [ ] Run tests, review secret exposure and commit only owned files.

## Task 2: Scoped repository tools
- [ ] Test path restrictions, immutable repository/ref, shared request budget and cancellation with injected readers.
- [ ] Implement RepositoryTools.swift with provenance and bounded output.
- [ ] Integrate selected repository context into AssistantStore; never expose credentials to the model.
- [ ] Run native CI and review error/output bounds.

## Task 3: Encrypted transfer
- [ ] Test authenticated roundtrips, wrong password, tampering, strict bounds and independent cross-language fixtures.
- [ ] Implement mobile encrypted full backup and explicit notes-only desktop transfer.
- [ ] Integrate export/import sheet with clear passphrase lifecycle and confirmation.
- [ ] Run full native/desktop suites; distinguish format compatibility from actual device transfer.

## Task 4: Bounded desktop jobs
- [ ] Test real filesystem operations with deterministic injected model responses, exhaustion and denied writes.
- [ ] Implement finite job loop, cancellation-aware transport, durable checkpoints and fail-closed recovery.
- [ ] Expose opt-in CLI invocation without expanding existing defaults.
- [ ] Run all Python tests on Linux, Windows and macOS in CI.

## Integration and delivery
- [ ] Review combined changes and run aggregate checks.
- [ ] Publish authorized source, verify exact remote commit and all CI jobs.
- [ ] Inspect new IPA metadata/integrity and real simulator screenshots.
- [ ] Deliver the new test candidate with precise implemented and unverified capabilities.
