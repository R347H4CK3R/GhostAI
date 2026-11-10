# Editable Luma Checklist Copies Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Explicitly import editable Luma checklist copies and safely edit their goal, step and completion inside Jarvis.

**Architecture:** A strict versioned checklist envelope remains an existing MemoryNote, preserving all v1 storage, backup and sync consumers. Structured preview data creates copies only after a separate opt-in; editor commits revalidate exact canonical bytes and workspace epoch.

**Tech Stack:** Swift, SwiftUI, XCTest, existing native GitHub Actions and Python release tools.

**Spec:** docs/superpowers/specs/2026-11-10-editable-luma-checklists-design.md

## Global Constraints
- iPhone priority; no Android-specific implementation.
- Keep SavedState version 1, note/chat schemas, encrypted-transfer keys, bundle ID, paths and release gates unchanged.
- Goal 1–300 UTF-16 units, step 1–400 UTF-16 units; preserve originals and exact Unicode.
- Every import/edit preflights 5 MB / 10,000 notes / 10,000 messages.
- No automatic execution, scheduling, permission expansion, source mutation or eviction.

## Review Focus
- Multiline and delimiter-containing input must retain structured fields without parsing old snapshots.
- Mixed-version clients and malformed future envelopes must retain ordinary note bytes visibly.
- Concurrent completion/text edits must retain both versions; stale or deleted editor targets cannot be restored by Save.
- Independent imports and reimports must not duplicate identical copies or overwrite edits.
- Cancel, dismissal, repeated Save and workspace round trips must not write to the wrong destination.

### Task 1: Opt-in editable copies and editor
**Files:** Create App/EditableChecklist.swift, App/EditableChecklistView.swift, Tests/EditableChecklistTests.swift. Modify App/LumaBackupImport.swift, App/ConversationImport.swift, App/ConversationImportView.swift, App/MemoryView.swift, App/AssistantStore.swift, App/PrivateMemorySyncModels.swift, App/ChatUITestFixture.swift, UITests/AssistantUITests.swift. Update relevant user-facing documentation.

**Interfaces:** EditableChecklist holds version, goal, step, done and immutable origin; validates/encodes a MemoryNote and recognizes only strict current envelopes. ConversationImportGroup gains an optional default-nil structured checklist draft. ConversationImportPreview.selection gains includeEditableChecklists default false. AssistantStore.saveChecklist edits one exact reviewed note under expectedWorkspaceEpoch.

- [ ] Add a UI regression proving Luma import offers a default-off separate editable-copy option, reset on close/reopen; run unchanged app in full PR CI and observe the missing option failure.
- [ ] Write unit/integration tests for opt-in selection, precise fields/provenance, reimport, edited copies, capacity, strict envelopes, canonical disk/backup/encrypted round trips, independent imports, three-way concurrent edits, deletion/restore, exact editor staleness and successful store persistence.
- [ ] Implement strict envelope, structured import option, exact edit transaction and narrow same-payload date reconciliation.
- [ ] Add native checklist list/editor with cancel/save/disclosure/provenance; UI fixtures and tests cover edit/cancel/completion/reopen and original snapshot preservation.
- [ ] Run all 106 local Python tests and full native PR suite on the final source head; fix failures without weakening gates.
- [ ] Obtain one fresh whole-branch review; address Important/Critical findings with RED→GREEN tests and all-suite verification.
- [ ] Commit and promote only after exact-head PR gates; run unchanged release gates and independently verify public assets before reporting publication.
