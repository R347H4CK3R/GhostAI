# Saved-reference planning implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Continue planning from explicitly selected saved Luma or other notes without changing the source or granting execution.

**Architecture:** Keep immutable selection and bounded question construction in a small native policy value. Add a local picker and review display to the existing planning screen; reuse ChatView submission unchanged.

**Tech Stack:** Swift, SwiftUI, XCTest. No new dependencies.

**Spec:** ../specs/2026-11-10-saved-reference-planning-design.md

## Global constraints

- Final complete question ≤2,000 characters. Reference excerpt ≤800 UTF-8 bytes; source excerpt ≤120 UTF-8 bytes, scalar boundaries.
- No canonical, backup, sync, permission, credential or protocol changes.
- No automatic sends, source mutation, or reference transfer to desktop jobs.

## Review focus

- Workspace switch-away-and-back must invalidate an old selection.
- Same-ID note replacement/deletion must invalidate a prepared question.
- Escaped Unicode must fit both preview and final request without silent goal truncation.
- Cancelling selection must not erase original notes or typed chat drafts.
- An imported source label cannot confer authority.

## Task 1: Explicit reference-to-question flow

Files: App/PlanningReference.swift (new), App/UnifiedPlanning.swift, App/UnifiedPlanningView.swift, App/ChatUITestFixture.swift, Tests/PlanningReferenceTests.swift (new), UITests/AssistantUITests.swift, docs/JARVIS_AUTONOMY.md.

Interfaces:
- PlanningReference captures MemoryNote and workspaceEpoch. validate(notes:project:workspaceEpoch:) rejects any changed/missing/foreign snapshot.
- PlanningReference.review(goal:kit:) returns PlanningReferenceReview with question, excerpt, sourceExcerpt, excerptTruncated and sourceTruncated, using UnifiedPlanning.question for unchanged base instructions.
- The composed review owns the actual included excerpt/source and truncation flags. Encode sorted keys and saved_at_ms deterministically; validate exact regenerated question before submission. The complete question also fits 8,192 UTF-8 bytes.

- [x] Add a synthetic fixture and UI regression requiring explicit current-workspace reference selection and exact question review; observe the missing feature fail in native CI before production implementation.
- [x] Add unit tests for escaping/Unicode size limits, unsafe content, stale/deleted/foreign snapshots, no implicit authority, unchanged source and no-reference compatibility.
- [x] Implement the policy value and picker/review state. Capture epoch, revalidate on preview/Ask, clear stale selection and review on changes. Keep original note/full disclosure and selected excerpt inspectable.
- [ ] Run script suite and whitespace checks, perform independent whole-change review, then complete exact-head native CI including UI and preservation gates.
- [ ] Integrate and publish only after all required gates pass. Verify public assets, identity and checksums; retain previous releases and disclose unsigned/device limitations.

## Verification record

- Native test-first run 42794998152 at 3ec940d compiled and failed exactly the new missing saved-reference UI control assertion. All 433 existing unit tests and the other 23 UI tests had zero failures, with one existing skip per suite. TLS, Android and all three desktop jobs passed.
- The implementation and expanded policy/UI regressions require fresh native verification. The Linux authoring workspace has no Swift/Xcode.
