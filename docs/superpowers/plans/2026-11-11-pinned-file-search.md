# Pinned file search implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Find useful pinned source evidence beyond prefix excerpts without widening read authority.

**Architecture:** Reuse RepositoryQuestionTools for validation, retrieval, cancellation and all shared budgets. A small deterministic formatter selects bounded literal-match windows. Register one additional FoundationModels tool and its compiled policy declaration.

**Tech Stack:** Swift, FoundationModels and XCTest. No new dependencies.

**Spec:** ../specs/2026-11-11-pinned-file-search-design.md

## Global constraints

- Query at most 128 UTF-8 bytes; first three matching-line anchors; one context line each side; at most 240 scalars per displayed line and up to 56 before its match.
- Existing eight-call/twelve-request/120,000-byte/4,000-character budgets, full-file screening, selected repository and immutable commit remain authoritative.
- No data-format, write-permission, credential, protocol, release-gate or Android feature changes.

## Review focus

- A long line must expose the match rather than only its unrelated prefix.
- A secret elsewhere in the file must withhold even an innocuous matching excerpt.
- Partial output must not imply all matching lines or files were shown.
- Concurrent search/read operations must not double-spend budgets or disclose after revocation.
- Unicode and CRLF must retain accurate line identities without normalization or unsafe scalar cuts.

## Task 1: Scoped search capability

Files: App/RepositoryTools.swift, App/RepositoryTextSearch.swift (new), App/AssistantStore.swift, App/IntegrationAdapters.swift, Tests/RepositoryTextSearchTests.swift (new), Tests/IntegrationRegistryTests.swift, docs/REPOSITORY_TOOLS.md, README.md.

Interfaces:
- `RepositoryQuestionTools.search(path: String, query: String) async throws -> String` uses the same private verified-file reader as `read(path:)` and final output accounting.
- `SearchRepositoryTextTool` exposes only path/query and fixed safe errors.
- `RepositoryTextSearch` validates the query and formats deterministic bounded line excerpts; it performs no I/O.
- Compiled operation `github.read/search_text` requires the same exact repository/path/commit/recipient/data scope as `read_text` and a distinct grant.

- [ ] Add a compile-compatible failing test through the existing IntegrationRegistry approve/validate API. Publish test-only draft PR against build12 and verify failure specifically because `search_text` is absent.
- [ ] Write deterministic actor/formatter tests before implementation for each contract and review-focus case.
- [ ] Implement shared verified-file extraction, search formatter/tool, registration and catalog; update read-boundary documentation.
- [ ] Run 118 script tests and source checks, obtain independent whole-change review, resolve important findings with regressions.
- [ ] Run complete exact-head native CI including all unchanged preservation and package gates. Distinguish synthetic tests from physical model/device evidence.
- [ ] Only after verified gates, promote once and verify prerelease assets and opt-in feed; preserve stable and existing data.
