# Proposal Change Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make one-file repository proposals easier to verify without expanding publishing authority.

**Architecture:** Store a pure deterministic comparison in each immutable prepared review. A shared review-content SwiftUI component shows a bounded changed-region preview followed by both existing complete files and destination disclosure. Preserve existing publication and lifecycle code.

**Tech Stack:** Swift 5, SwiftUI, XCTest, Xcode 26 / iOS 26.

**Spec:** `docs/superpowers/specs/2026-11-11-proposal-change-review-design.md`

## Global Constraints

- Existing 30,000-byte source/replacement policy and all publishing consent remain unchanged.
- Exact UTF-8 comparison, linear prefix/suffix scan; one changed region, not a minimal diff.
- At most 12 removed + 12 added preview rows; 240 rendered content UTF-8 bytes per row.
- Explicit endings, escaped controls/backslashes/trailing ASCII spaces, omitted and shortened row counts.
- Complete files remain authoritative; no new network, persistence, credentials or Android changes.

## Review Focus

- Canonically equivalent Unicode must not be hidden as identical; test byte-different composed/decomposed lines.
- Newline-only changes must remain visible; test LF/CRLF and absent final LF.
- Disjoint changes must not be described as minimal; test retained interior equal line in changed region.
- A long first line must not hide the opposite side; test independent per-side row budgets and shortening.
- UI fixture must not read real state or contact GitHub; route before ordinary app construction and use only synthetic verified-loader input.

### Task 1: Immutable change preview and complete-review integration

**Files:** New `App/RepositoryProposalDiff.swift`, `App/RepositoryProposalReviewContent.swift`, `Tests/RepositoryProposalDiffTests.swift`; modify `App/RepositoryProposalModels.swift`, `App/RepositoryProposalView.swift`, `Tests/RepositoryProposalTests.swift`; new DEBUG fixture and UI tests; minimal launcher route; update proposal docs.

**Interfaces:** `RepositoryProposalDiff(original: String, replacement: String)` exposes changed-region counts, omitted/shortened counts and rendered preview text. `RepositoryProposalReview.changes` stores the comparison at preparation. `RepositoryProposalReviewContent(review:)` renders comparison plus complete review fields.

- [x] Extract the unchanged complete-review display and add an isolated real-component UI regression requiring the missing change preview after complete-file assertions. Publish a test-first draft PR and observe expected native RED. Add an integrated canonical-equivalent Unicode regression before its corrective implementation.
- [ ] Add focused pure comparison and immutable approval-binding tests for every spec contract, then implement the linear comparison and immutable review property. Tighten no-op and draft matching to exact UTF-8 only after the integrated Unicode RED is verified.
- [ ] Extract current complete-review display into the component, preserving its text/identifiers; add bounded preview. Add isolated DEBUG UI host and tests for small and truncated synthetic changes, with screenshots and complete-file assertions.
- [ ] Run local `python3 -m unittest discover -s scripts/tests -v`, source/whitespace checks and independent review. Resolve findings without changing consent or publication mechanics.
- [ ] Publish reviewed source and require exact-head full native UI/unit, companion, transfer, upgrade and device gates. Inspect screenshots. Only then promote once to the existing prerelease branch and verify all final release gates, public hashes and preview source; stable/default remain untouched.
