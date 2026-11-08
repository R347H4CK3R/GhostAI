# Asterion Veyra

A separate personal iPhone coding assistant with a dark cyan/violet interface, public GitHub project workspaces, Apple on-device AI, and user-controlled offline memory.

**Status: source prototype. No iOS compilation, simulator run, signed installation or device inference has been verified.** This is not dot, ChatGPT, or a copy of their models/accounts. No generated IPA is included.

## Implemented in source
- SwiftUI conversation, projects, memory and capability screens.
- Public repository discovery with pagination, directory browsing and text preview pinned to the selected commit.
- Apple Foundation Models chat when the system model is available, explicit cancellation and project-scoped context.
- Persisted chat and notes in Application Support using atomic writes and iOS complete file protection.
- Offline keyword-ranked retrieval of saved notes. Save selected source excerpts with repository/path/commit provenance. A saved excerpt remains available offline; browsing uncached source still needs network.
- Reviewable suggestions and answer/note export. No automatic execution or remote writes.
- Read-only anonymous GitHub requests, redirect rejection, streamed response limits, and text-file size checks.
- Twelve XCTest cases for scope/budget, validation, secret warnings, persistence and corruption behavior, backup validation and import deduplication.

## Requirements
An Apple Intelligence-capable iPhone or iPad, iOS/iPadOS 26+, and Apple Intelligence enabled with the system model available. Local inference availability depends on device settings, language, region and downloaded assets. The app displays unavailable states instead of pretending it generated an answer.

## Build
Use a Mac with Xcode 26 and XcodeGen:

```
brew install xcodegen
xcodegen generate
open AsterionVeyra.xcodeproj
```

Choose a simulator and run the `AsterionVeyra` scheme's tests. For an actual device, set your own development team and signing settings in Xcode. The supplied project disables signing for reproducible unsigned builds; enable signing for your device build.

The `.github/workflows/ios.yml` workflow selects Xcode 26, runs XCTest on an available iOS 26 simulator, compiles for device, and uploads `AsterionVeyra-unsigned-IPA` only if those stages succeed. It is configured but has **not been run**. An unsigned IPA cannot install directly on ordinary stock iOS. Use your own valid signing/provisioning process. No signing credentials are supplied or collected.

## Try it
1. Open Projects, type your GitHub username, and load public repositories.
2. Select a repository, browse a text file, and use **Attach to next question**.
3. Switch to Assistant and ask a focused question. It only uses a limited excerpt of the attached file, and never silently runs commands.
4. Select **Save excerpt for offline use** to persist source context, or add a note under Memory. Review source for credentials first.
5. Test with airplane mode: saved project names, notes, conversations and available local AI remain usable. Switch to a saved workspace from Projects.

## Resource and data limits
The prototype's context budget is deliberately small: up to 3,000 characters of retrieved notes, 3,000 attached source characters, four recent conversation turns shortened to 500 characters each, and a 2,000-character question. These are character budgets, not tokenizer guarantees. Model context errors are reported; narrow the question or source if needed. Text files are limited to 60 KB and saved notes/excerpts to 20,000 characters. These limits bound resource use, not daily usage.

Notes retain their creation date and source; they are not automatically refreshed. Storage can grow until device space is exhausted, at which point writes report an error. Retrieval scans the saved notes in memory; SQLite FTS is a future migration for large collections. No unlimited capacity, perfect recall or permanent model training is promised.

Data is stored locally, but OS device backups may include it. Notes and conversations may be lost on uninstall. Individual note/answer export and full JSON backup/import are supported in source. Backups are unencrypted: keep them private. Full backup export currently supports up to 5 MB and 10,000 records per collection, and fails visibly above those limits rather than producing an unrestorable file. Export individual notes/answers for larger collections. Imports merge without overwriting matching IDs and reject invalid records and detected credentials. Note editing, migrations and cross-device sync are not implemented. Secret detection is a warning heuristic, not a guarantee: do not save credentials or sensitive source blindly. Exported content is under the user's control.

## Runnable offline desktop companion

`companion/` is a Python 3.9+ standard-library CLI for Windows/macOS/Linux. It provides SQLite project memory and deterministic execution of explicitly supplied JSON plans: bounded list/read/hash/JSON-validation tools and narrowly authorized new draft writes. It does not plan with an LLM, run arbitrary shell commands, control apps or connect to the iPhone. See [setup and security boundaries](docs/COMPANION.md). Eleven Python tests pass on the authoring Linux environment; Windows/macOS behavior needs direct validation.

## Not implemented
Private GitHub authentication, GitHub modifications, model-directed autonomous planning, structured patch application, online models, voice, native Windows/Android graphical clients, sync, remotely paired runners, permanent model learning, or control of arbitrary installed apps. These are follow-on milestones, not current capabilities. See `docs/CROSS_PLATFORM.md`.

## Verification in the authoring environment
The environment has neither Swift nor Xcode. XCTest was authored before implementation but could not execute; there is no red/green execution claim. Static checks for project references, workflow structure and secret literals can run here; they cannot establish type correctness, UI quality, runtime safety or installability. Device testing remains required.
