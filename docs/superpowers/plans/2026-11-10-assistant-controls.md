# Assistant Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make local name/avatar, launch-screen preferences and assistant menu routes work on iPhone.

**Architecture:** A versioned value in a dedicated UserDefaults key and shared observable owner, separate from canonical user data. A draft sheet saves explicitly; MainView reads launch choice once and existing voice requests override navigation.

**Tech Stack:** SwiftUI, Foundation, XCTest, existing Xcode 26 CI.

**Spec:** docs/superpowers/specs/2026-11-10-assistant-controls-design.md

## Global Constraints
- iOS 26+, no dependencies, external accounts, new permissions or canonical data schema changes.
- Preserve Jarvis/sparkles/Assistant defaults; only presentation changes with the name.
- Name limits: 40 Characters, 160 UTF-8 bytes; reject empty, controls, line separators, bidi controls.
- Preserve release/native/UI/retained-upgrade gates and other active work.

## Review Focus
- Cancel, empty/oversized/control-heavy and valid multiscalar names leave saved state correct.
- Corrupt/future stored settings never silently replace bytes or affect unrelated preferences.
- Relaunch applies launch choice; foreground and settings Save never reset current navigation.
- Siri entry still opens voice controls from a non-Assistant launch tab without recording.
- Repeated sheet/menu actions preserve typed drafts, chat data and current project.

## Task 1: Persist and expose real controls
**Files:** Create App/AssistantPreferences.swift, App/AssistantPreferencesView.swift, Tests/AssistantPreferencesTests.swift, UITests/AssistantControlsUITests.swift. Modify App/AtlasApp.swift and App/ChatView.swift only. Add documentation.

**Interfaces:** AssistantPreferences is a MainActor ObservableObject with published read-only value and loadWarning, injected UserDefaults, validated save(name:avatar:startScreen:), and a test-isolated app factory. AssistantPreferenceValue has name, avatar and startScreen. AssistantAvatar and AssistantStartScreen are bounded enums. MainView(preferences:) initializes selectedTab once; ChatView reads shared preferences.

- [ ] Add one native UI regression using the existing synthetic chat fixture: open Chat options, edit name/avatar, save, verify header/composer, relaunch, verify persistence; cancel later edit; choose Memory launch tab, relaunch, verify it.
- [ ] Publish test-only draft branch and run unchanged full PR CI. Expected: native compilation succeeds, test fails at missing Edit name & avatar control. Do not implement before observing that failure.
- [ ] Write unit tests for defaults, exact Unicode preservation, valid save/reload, all invalid name classes, unknown/malformed persisted settings preservation and unrelated UserDefaults isolation. Add UI cancel/start/computer/Siri entry coverage.
- [ ] Implement the specified preferences value, local store and explicit draft sheet. Wire header, assistant labels/composer, launch initialization, menu routes and Assistant launch shortcut.
- [ ] Run all script tests locally; run unchanged complete native/UI/upgrade/device gates on exact remote head. Expected: all applicable gates green; physical-device checks remain unrun.
- [ ] Obtain independent whole-diff review, fix important findings with reproducing tests, then report exact commit, CI, gaps and limits. Integration/release is coordinated with the parent and the separate Luma branch.
