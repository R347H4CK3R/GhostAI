# Asterion Veyra

A personal assistant project with a native iPhone coding client, Android offline memory companion and desktop task tools with a dark cyan/violet interface, public GitHub project workspaces, Apple on-device AI, and user-controlled offline memory.

**Status: actively developed and undergoing CI verification. No signed iPhone installation or physical-device inference has been verified.** This is not dot, ChatGPT, or a copy of their models/accounts. No generated IPA is included.

## Implemented in source
- SwiftUI conversation, projects, memory and capability screens.
- Public repository discovery with pagination, directory browsing and text preview pinned to the selected commit.
- Apple Foundation Models chat when the system model is available, explicit cancellation and project-scoped context.
- Persisted chat and notes in Application Support using atomic writes and iOS protection until first user authentication, allowing background voice persistence after first unlock.
- Offline keyword-ranked retrieval of saved notes. Save selected source excerpts with repository/path/commit provenance. A saved excerpt remains available offline; browsing uncached source still needs network.
- Model-callable, read-only offline memory search constrained to the selected project.
- Reviewable suggestions and answer/note export. No automatic execution or remote writes.
- Read-only anonymous GitHub requests, redirect rejection, streamed response limits, and text-file size checks.
- Native XCTest coverage for scope/budget, validation, secret warnings, persistence and corruption behavior, backup validation and import deduplication.

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

The `.github/workflows/ios.yml` workflow tests desktop tools across Windows/macOS/Linux, tests/lints/builds the Android debug APK, selects Xcode 26 for iOS tests and device compilation, and uploads artifacts only after their relevant stages succeed. Check the actual [Actions results](https://github.com/R347H4CK3R/GhostAI/actions); source presence is not proof of a successful build. An unsigned IPA cannot install directly on ordinary stock iOS. Use your own valid signing/provisioning process. No signing credentials are supplied or collected.

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

`companion/` is a Python 3.9+ standard-library CLI for Windows/macOS/Linux. It provides SQLite project memory and deterministic execution of explicitly supplied JSON plans: bounded list/read/hash/JSON-validation tools and narrowly authorized new draft writes. An optional local Ollama model can now propose validated plans for review before separate execution. It does not run arbitrary shell commands, control apps or connect to the iPhone. See [setup and security boundaries](docs/COMPANION.md). Thirty-three Python tests pass on the authoring Linux environment, including model transport validation and real encrypted-transfer round trips. Live Ollama quality and actual target-device behavior need validation.

## Android offline memory companion

`android/` provides a native Kotlin app for Android 8+, with project notes, search, source provenance, confirmed deletion and user-selected JSON backup import/export compatible with the iOS schema. It clearly labels itself an offline memory companion; no Android chat model is included. See [Android build and scope](docs/ANDROID.md). The CI workflow produces a debug-signed APK when tests, lint and compilation succeed. It is a testing artifact, not a production-signed release.

## Optional model planning and encrypted transfer

See [local planning](docs/PLANNING.md) and [encrypted snapshots](docs/SYNC.md). Install the optional cryptography dependency for encrypted desktop memory transfer. Passphrases are entered through a terminal prompt, not command-line flags. This is manual desktop-to-desktop transfer, not background sync; native mobile apps do not yet decrypt that format.

## Not implemented
Private GitHub authentication, GitHub modifications, automatic plan/act/replan loops, structured patch application, hosted online models, a native Windows graphical client, automatic sync, remotely paired runners, permanent model learning, or control of arbitrary installed apps. These are follow-on milestones, not current capabilities. See `docs/CROSS_PLATFORM.md`.

## Verification in the authoring environment
The authoring Linux environment has neither Swift nor Xcode; native verification runs separately in GitHub Actions. XCTest was authored before implementation but could not execute; there is no red/green execution claim. Static checks for project references, workflow structure and secret literals can run here; they cannot establish type correctness, UI quality, runtime safety or installability. Device testing remains required.

## Strata

See [Strata packaging and runtime validation](docs/STRATA.md). The normal unsigned IPA shape matches the documented importer, but Apple-model operation in a guest must be tested on-device.

## iPhone voice test candidate

The iPhone source now includes microphone/speech permission handling, on-device-only transcription when available, spoken replies, explicit voice turn-taking, and an optional background-active-audio setting for directly signed installations. Speech/model interruptions stop the session; no silent audio keeps unrelated work running. See [voice behavior and device checks](docs/VOICE.md) and [Siri entry](docs/WAKE.md). No guarantee of all-day continuous operation or custom wake-word support is made. Test these additions on the signed phone, not just in a simulator.

## Diagnostics and automated verification

The iPhone build includes safe redacted diagnostics with a three-day foreground check, manual self-tests and an optional local-model greeting test. Reports omit private content and stay local until explicitly exported. Automatic public-repository uploads are not configured. See [diagnostics](docs/DIAGNOSTICS.md). CI includes native UI navigation, memory save/relaunch/delete checks and simulator screenshot attachments, in addition to unit tests. Successful simulation still cannot validate physical microphone quality, Apple model availability, all-day battery behavior or locked-screen background voice.
