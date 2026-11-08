# On-device diagnostics

`DiagnosticsController` is a main-actor observable object. Connect `runIfDue()` to app foreground activation, `runChecks()` to a Run checks button, and `Task { await diagnostics.runModelCheck() }` to a separate optional model-test button. `reportURL` can be offered using `ShareLink`; `status` explains report creation and `isRunning` prevents overlapping checks.

## Cadence and export

Basic checks run when the app is next foregrounded at least three days after the last successfully written basic report. This is opportunistic, not a guaranteed background schedule. A device clock moving backward also makes a check due. Manual checks can run sooner. Optional model generation is never automatic.

The latest report replaces `Diagnostics/diagnostics.json` in the local app cache, protected while the device is locked. iOS may purge cached files. The scheduler stores only the last successful basic-report time in local preferences; that timestamp is not exported. The report contains app version, iOS version, a schema version and fixed-name check statuses. Review the file before choosing its destination in the share sheet.

**Nothing automatically uploads to GitHub or any other service.** Public-repository upload would publish diagnostic metadata. It requires an explicitly approved destination and a separately designed authenticated upload workflow. Do not embed a repository write token in the app, source, diagnostics, or build configuration. Prefer an authenticated restricted backend with a narrow ingestion endpoint if automatic upload is added later. iOS still cannot promise an upload every few days while the app is not running.

## Checks and limitations

- Storage: actually writes and reads a synthetic note through `DiskStore` in a unique disposable directory, then removes it. A cleanup failure is a failed check. Does not open the user's saved state.
- Serialization: round-trips a synthetic `SavedState` and checks equality.
- Backup: round-trips synthetic data through backup helpers and rejects an unsupported version. Does not export or restore real memory.
- Credential filter: checks known synthetic credential patterns and an ordinary note. This is not a complete secret-detection audit and does not inspect Keychain or credentials.
- Foundation Models: reads availability. A separate user-initiated model check sends only a fixed greeting prompt to a fresh tool-free session. Generated text is discarded. Completion only establishes that this tiny request succeeded, not correctness or reliability of other answers.
- Speech: reads recognizer availability, on-device recognition support and existing speech/microphone permission. Never requests permission, starts recording, or starts recognition.
- Recording and repository upload: always `not_run` because they are not exercised.

Statuses are `pass`, `fail`, `not_run`, or `unavailable`. Permission not yet requested is `not_run`; denial/restriction or unsupported capabilities are `unavailable`. Unavailable is not proof of an app bug. No transcripts, real notes, repository contents, tokens, device/account identifiers, device names, raw errors, local paths, microphone audio, or generated model answer are included. This deliberately limited smoke test does not “test everything,” validate real data health, prove network access, or replace simulator/device tests.

## Validation

`Tests/DiagnosticsTests.swift` covers three-day timing including clock rollback, synthetic helper checks, real disposable storage and cleanup, storage failure without modifying the target, the report's top-level allowlist/status-only checks and repeated-foreground behavior. Run the iOS XCTest scheme on macOS with Xcode and an iOS 26 simulator. Physical-device validation is also required for Foundation Models and speech availability. Swift/Xcode tests were not executable in the Linux authoring environment.
