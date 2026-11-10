# Paired Result Receipts Implementation Plan

> For agentic workers: Use superpowers:executing-plans to implement and verify each task.

**Goal:** Retain a truthful bounded desktop observation after app relaunch.

**Architecture:** One optional receipt lives inside each existing saved job. Response parsing, identity validation and transition checks precede the same atomic Keychain update as job status. Preflight capacity prevents new network requests that cannot be retained.

**Tech Stack:** Swift, Codable, CryptoKit, Keychain, SwiftUI, XCTest.

**Spec:** ../specs/2026-11-10-paired-result-receipts-design.md

## Global Constraints

- Keep 96 KiB record limit, 20 jobs, passcode-bound device-only Keychain and all existing release gates.
- Keep read-only wire protocol and current grants unchanged.
- Preview at most 256 UTF-8 bytes; full response at most 524288 bytes; summary at most 262144 bytes; error code at most128 UTF-8 bytes.
- Never evict history, reconstruct legacy intent/results or claim independently verified execution.

## Review Focus

- Terminal cancellation flag changes must not be mistaken for result corruption.
- JSON escaping must not exceed reserved receipt capacity.
- Old near-full records must not send before the capacity failure is known.
- Paused/failed requests must preserve the previous observation and timestamp.
- Legacy jobs and revoked grants must retain history without granting new authority.

## Task 1: Persist bounded response observations

Files: App/PairedDesktopResultReceipt.swift (new), App/PairedDesktopState.swift, App/PairedDesktopClient.swift, Tests/PairedDesktopClientTests.swift.

- [x] Add a regression expecting a terminal receipt after a real Codable relaunch without networking.
- [ ] Observe that regression fail in native CI before production implementation.
- [ ] Add negative/transition/capacity/Unicode regression coverage described in the spec.
- [ ] Implement validated receipt parsing and optional job persistence. Reserve worst-case receipt encoding before submit/read/cancel. Preserve sequence/outbox ordering and save-before-display.
- [ ] Verify native tests and full repository gates; independently review before integration.

## Task 2: Present saved observations honestly

Files: App/PairedDesktopView.swift, docs/JARVIS_AUTONOMY.md.

- [ ] Show saved preview, truncation, observation time, counters and response fingerprint with explicit limits.
- [ ] Preserve full transient response display where available and make missing historical receipts explicit.
- [ ] Verify final Swift compilation and UI suite; publish only after exact-commit release verification.
