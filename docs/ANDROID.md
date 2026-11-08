# Asterion Veyra for Android

Native Kotlin **offline memory companion**, Android 8.0 / API 26 and newer. The dark navy, cyan and violet interface provides project-scoped notes, search (text and source), provenance timestamps, confirmed deletion, and explicit JSON backup import/export through Android's system file picker.

## What works in the implementation

- Create local notes with a project and source. Search is scoped to the selected project; existing project names are listed above the editor.
- Persist validated state in app-private storage using Android `AtomicFile`. Failed startup reads disable writes/imports rather than replacing unreadable data. Android OS backup is disabled; screenshots and recent-app snapshots are protected with `FLAG_SECURE`.
- Export all projects and preserved chat records to a user-picked JSON file. Export confirmation explains that backups are plaintext and cloud-backed document providers may upload them.
- Import only after parsing, validation, collision checks and a second explicit confirmation. Cancellation changes nothing. Existing IDs cause the entire import to fail, including identical records; there is no silent overwrite or deduplication.
- Preserve iOS chat records in backups, without providing an Android chat UI.

**Not implemented:** model inference, sending chat, remote companion connection, automatic sync, continuous background activity, autonomous cross-app/device control, encrypted backup files. The manifest has no network permission or broad storage permission. Input-method software and selected document providers are controlled by the user; app-private storage is not a custom encrypted vault.

## Backup contract

UTF-8 JSON matches iOS `SavedState`: `{"version":1,"notes":[{"id":"UUID","project":"...","text":"...","source":"...","savedAt":0}],"chats":[{"id":"UUID","project":"...","role":"user","text":"...","date":0}]}`.

Dates are numeric seconds since **2001-01-01 00:00:00 UTC**, not Unix timestamps. Note IDs are UUID strings. Chat roles accepted: user, assistant, system. Android preserves imported chats for round-trip export but does not display them.

Validation rejects unknown/missing fields, unsupported version, invalid UUIDs, duplicate IDs across notes and chats, non-numeric/out-of-range dates, blank fields, oversized strings, known credential patterns and trailing data. Limits: 2 MiB UTF-8, 2,000 combined records, 120 project characters, 16,000 text characters, 500 source characters. Incoming data and the entire merged state are validated. UUID collision checks are case-insensitive. Known-secret detection is incomplete: never save passwords, tokens, private keys or payment credentials.

## Build (debug only)

Requirements: JDK 17, **Gradle 8.9**, Android SDK platform 35 and build tools, network access to Google Maven, Maven Central and the Gradle plugin portal. Versions are pinned in the build files: AGP 8.7.3 and Kotlin 2.0.21. No external runtime SDKs are used. JUnit and `org.json` are JVM-test-only dependencies.

From the repository root:

```sh
cd android
gradle --no-daemon :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
```

Expected APK: `android/app/build/outputs/apk/debug/app-debug.apk`. The parent CI workflow must provision Gradle 8.9 (for example, `gradle/actions/setup-gradle`) and Android SDK 35. No Gradle wrapper binary is checked in, and no signing credentials are needed for the debug APK. Debug APKs are development builds, not Play Store releases or production-signed distribution. Download only the artifact for a verified successful CI commit. Android installation of downloaded APKs is a user-controlled step.

## Verification status and local limits

In the implementation environment, Java 21 is present, but `gradle`, `kotlinc`, Android SDK/platform tools and a device/emulator are unavailable. No toolchains or credentials were downloaded. Consequently Android compilation, JUnit, lint, APK assembly, emulator and physical-device testing **have not been run locally**. Source review and XML parsing are not substitutes for those checks. CI must pass before claiming this build is installable.

JVM tests cover backup round trips and Apple epoch conversion, collision/no-overwrite behavior, new-note merges and chat preservation, credential checks, unknown fields/trailing data, record/text/byte limits, invalid dates and cross-type duplicate IDs.

Manual device acceptance checklist after CI:

1. Save notes in two projects, change project/search, confirm isolation and visible provenance.
2. Relaunch and rotate; confirm persistence and retained drafts/search. Verify keyboard and edge-to-edge insets on API 26 and 35.
3. Cancel deletion and import/export pickers; confirm no changes. Delete one note and verify it stays deleted after relaunch.
4. Export, import on another empty installation, and export again. Confirm iOS can decode notes and chats with unchanged timestamps.
5. Reject same-ID reimport, malformed/oversized files, unsupported version, credentials in every field, and unavailable document providers. Confirm existing data survives.
6. Simulate unreadable local state and disk-write failure; verify no automatic reset. Test TalkBack, large font sizes and long notes.

File operations and rendering run on the main thread and are bounded, but large allowed backups/record lists may pause the UI on low-end devices. There is no background job or claim of performance testing.
