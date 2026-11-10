# Combined Jarvis Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish one verified candidate that preserves editable checklist drafts while voice requests wait for actual dismissal.

**Architecture:** A scene-owned Boolean binding blocks root navigation and ChatView voice consumption while a checklist sheet is presented or dismissing. The existing shared pending request remains unchanged and is consumed once when routing becomes possible.

**Tech Stack:** Swift 5, SwiftUI, XCTest, Python release tools.

**Spec:** docs/superpowers/specs/2026-11-10-combined-jarvis-voice-design.md

## Global Constraints
- iPhone and iOS 26.0+, existing SwiftUI and data formats, no new dependencies.
- No implicit save, cancel, microphone activation, external request or permission expansion.
- Full exact-head PR and release gates remain required.

## Review Focus
- A request during dismissal animation must wait for actual onDismiss, not a nil route.
- Repeated requests must coalesce and must not reopen voice controls after Done.
- Failed Save must retain unsaved editor data and the pending request.
- Interactive dismissal must release the gate without saving the draft.
- Scene-owned state must not leak a global blocker on scene destruction.

### Task 1: Combine verified branches and reproduce interrupted editing
**Files:** App/AtlasApp.swift, new DEBUG-only App/ChecklistVoiceUITestFixture.swift, UITests/AssistantUITests.swift, design/plan docs, the five reviewed preview publisher patch files.
**Interfaces:** Existing VoiceEntryRequest.request(), consume(canPresent:), existing checklist editor accessibility controls, and standard six-job PR workflow.
- [ ] Verify exact PR5 and PR6 head gates. Merge their histories locally, retaining both parent commits, and apply the verified preview publisher patch.
- [ ] Add a gated DEBUG foreground fixture and native UI regressions for Save, Cancel and interactive dismissal. Assertions: unsaved goal remains visible after activation, no voice controls/mic permission before dismissal, expected edited/original data after reopening, voice controls once after dismissal.
- [ ] Run 118 script tests, diff checks and YAML parsing, then publish an isolated draft integration PR. Observe native failures at premature navigation/consumption before implementing the fix.

### Task 2: Defer navigation and consumption until actual editor dismissal
**Files:** App/AtlasApp.swift, App/MemoryView.swift, App/ChatView.swift.
**Interfaces:** MainView owns @State private var checklistEditorPresented = false; MemoryView accepts Binding<Bool>; ChatView accepts canPresentVoiceEntry: Bool = true. MemoryView sets the binding before constructing the route and clears only in sheet onDismiss. MainView checks the flag before tab routing. ChatView combines the flag with its existing activeSheet gate and consumes when the flag becomes true.
- [ ] Implement only after verified RED. Refuse a second editor while the dismissal flag is still true. Failed Save leaves the flag true.
- [ ] Run local script tests and publish. Verify all six exact-head jobs and every new UI regression.
- [ ] Obtain one fresh composition review, then fix Important/Critical findings with a failing regression and full green suite. Preserve each prior branch review.
- [ ] Promote only the final verified descendant to the existing release branch once. Verify all release jobs, published assets, checksums and preview feed. Report actual device limitations and remaining capability gaps.
