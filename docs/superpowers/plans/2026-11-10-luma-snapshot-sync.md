# Luma Snapshot Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Avoid false conflict copies when identical Luma checklist snapshots differ only by import time.

**Architecture:** Identify current-format Luma checklist records in the importer-owned policy, then reconcile their date before generic three-way conflict handling. Preserve every other merge rule.

**Tech Stack:** Swift, Foundation, XCTest; no new dependencies.

**Spec:** ../specs/2026-11-10-luma-snapshot-sync-design.md

## Global Constraints

- No schema, encryption, sync scope, credential, acknowledgment, UI or permission changes.
- Only same UUIDv8 and byte-for-byte equal UTF-8 project, text and source records with the exact Luma checklist/import-time markers qualify.
- Choose the earlier of the two device import times; preserve every other field.
- Do not remove prior conflict copies or weaken any verification gate.

## Review Focus

- Restored IDs differ from original import IDs and must still converge.
- Filename/source differences must remain visible, even with the same original ID.
- Tombstones must precede reconciliation and never be removed.
- UUIDv4 ordinary notes and UUIDv5 legacy conflict copies retain existing semantics.
- Imported provenance text must never confer execution or sharing authority.

## Task 1: Reconcile otherwise identical checklist import times

**Files:** Tests/LumaSnapshotSyncTests.swift (new), App/LumaBackupImport.swift, App/PrivateMemorySyncModels.swift, docs/PRIVATE_MEMORY_SYNC.md.

**Interfaces:** Add `LumaBackupImport.usesChecklistImportTime(_ note: MemoryNote) -> Bool`; consume it only within the same-ID MemoryNote merge branch. No public wire interface changes.

- [x] Add synthetic real-import regressions for single-copy convergence, reversed/stale merges, restoration, deletion dominance, changed content/source/project, unrelated notes/legacy copies, distinct IDs, delimiter-containing fields, and changed completion status.
- [x] Publish test-only draft PR and observe expected native duplicate-count failure before implementation.
- [x] Add the narrow classification and merge rule; update sync documentation without changing import output.
- [ ] Run 106 Python script tests and whitespace checks; obtain fresh independent whole-branch review.
- [ ] Require exact-head native unit/UI, transfer, upgrade, TLS, Android and desktop CI success before integration.
- [ ] Publish through the existing release workflow only after its full gates; independently verify public asset hashes and identity.

## Verification record

Native test-first run 42820350313 at d25eef1 compiled and reproduced the expected duplicate-count failures in three new cases, with five failed assertions. All 442 existing unit tests, five new preservation cases, and all 25 UI tests passed, with the existing skip in each suite. TLS, Android and desktop jobs passed. Implementation requires fresh full native verification.

Independent review identified an Important Unicode convergence issue in the initial implementation: Swift String equality allows distinct canonical-equivalent UTF-8 sequences. A ninth regression exercises real NFC/NFD filenames plus text/project variants before replacing those comparisons with exact UTF-8 equality. This review fix needs its own observed native failure and a fresh full pass.
