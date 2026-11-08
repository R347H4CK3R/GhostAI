# Simulator install-over-existing gate

The iOS CI job must pass `scripts/verify_simulator_upgrade.py` before packaging the new
unsigned device app. A successful ordinary unit/UI test run alone is not upgrade evidence.

## What actually runs

1. Select an available iOS 26 runtime and compatible iPhone type. Create a new, uniquely
   named simulator, independent of the main test suite and other jobs.
2. Build the old app from pinned commit `8074b807a864a79e659200ee9521141c3c00df98`
   (version 0.3.0, build 17). Fetch only that commit if the checkout is shallow.
   Build the candidate app and test bundles from the current checkout.
3. Install the old simulator app with bundle ID `dev.asterionveyra.assistant`. Before its
   first launch, write the harmless `Tests/Fixtures/upgrade-state-v1.json` to the actual
   data container's `Library/Application Support/AsterionVeyra/state.json`.
   This v1 file contains two project notes and two General conversation messages, with
   fixed identities and native Swift reference-date numbers.
4. Seed the prior release's real `diagnostics.lastSuccessfulReport.v1` preference in
   `Library/Preferences/dev.asterionveyra.assistant.plist`. Its synthetic recent UTC date suppresses
   automatic diagnostics during this isolated test; future dates trigger diagnostics and are
   deliberately not used. The exact per-run timestamp is passed to the native test and must
   survive unchanged. The old app has no persisted voice
   settings, so the test does not invent any. No credentials or permission grants are seeded.
5. Launch and terminate the old app, requiring the original state and preference to survive.
   Install the candidate **without uninstalling, erasing, or resetting**. Require the same
   data-container path, identical state bytes, and the same decoded preference. Launch the
   candidate normally and check again. Immediate startup crashes fail the run.
6. Execute exactly two selected native/UI tests on this same simulator. The native test uses
   production `DiskStore.load()` and checks every fixture identity, project, text, role and
   date, plus the real UserDefaults value. The UI test reads retained conversation and note
   text, checks project separation, captures the installed home-screen icon, checks its
   presence and tappability, opens the app from it, and relaunches it. The screenshot needs
   human visual review to verify refreshed artwork; this is not an automated artwork check. It never sends a model request or starts voice.
7. Require exactly two passing tests with no skips in the xcresult summary. Recheck the
   container and bytes after XCTest. Collect logs/screenshots/results and delete only the
   simulator created by this invocation.

The normal suite also runs the standalone prior-format DiskStore fixture test. The two
installed-upgrade tests explicitly skip outside the isolated run. A missing/incorrect
xctestrun environment cannot create a green upgrade gate because skipped tests fail its
summary validation. Test-run configuration is written beside the original `.xctestrun`
so Xcode's relative `__TESTROOT__` paths still resolve.

## Run and inspect

On a Mac with Xcode 26, an installed iOS 26 simulator runtime, and XcodeGen:

```sh
python3 scripts/verify_simulator_upgrade.py --output upgrade-results --budget-seconds 1080
```

Use a new output directory each time. `result.json` records the exact baseline/candidate,
versions, retained hash, container checks, selected runtime/device, per-command durations,
pass/failure stage and explicit untested capabilities. Candidate provenance always comes
from the local checkout HEAD, including outside GitHub, with a dirty-state boolean covering
tracked and untracked changes. It is sampled before this run creates evidence/build files;
pre-existing generated files can still make it dirty. No Git status paths or file contents
are included in provenance. A native run cannot pass with an unknown candidate revision. `Upgrade.xcresult`, exported XCTest
screenshots, a direct upgraded-app screenshot, and bounded application logs are uploaded
as **AsterionVeyra-simulator-upgrade**, including after failure.

Exit status `0` means this gate verified the upgrade. `1` means a build, install, content,
launch, XCTest, or timeout failure. `2` explicitly means unsupported infrastructure, such
as running on Linux or lacking an iOS 26 runtime. **Both nonzero statuses fail CI**; unavailable
infrastructure is not reported as an app failure or silently counted as success.

Each app launch has one bounded three-minute attempt, subject to the same total work
budget. A timed-out launch is uncertain and is not automatically retried. Failure evidence
includes a screenshot and app-related SpringBoard, runningboardd and launchd logs from
only the newly created simulator, before that simulator is shut down and deleted.

Host-only tests run on Linux/macOS without pretending to run an iPhone:

```sh
python3 -m unittest discover -s scripts/tests -v
```

They exercise prior-format fixture validation, destructive-seed refusal, deliberate changed
or missing state/preferences, simulator selection, actual app bundle metadata checks,
legacy/current xctestrun parsing, and rejection of skipped/empty XCTest results.

## Bounded CI cost

This adds one sequential macOS step, **two simulator builds**, **one new simulator**, and
**two selected XCTest methods**, not a second full suite. The current test build is separate
from the earlier suite so test artifacts/state cannot be confused. Limits are 7 minutes per
build, 3 minutes to boot, 3 minutes for each launch, and 6 minutes for selected tests, sharing an **18-minute total work
budget**. These are maxima, not additive allocations: the remaining total budget limits
each command, including the initial provenance snapshot. Cleanup/evidence commands have
90 seconds of combined timeout allowances, plus bounded process-group termination grace.
The workflow imposes a 20-minute hard timeout overall. Actual elapsed and per-command costs are in
`result.json`; no elapsed-time or dollar-cost claim is made before a native run.

Timeout signals target only the command group spawned by this invocation. A surviving
group receives SIGKILL after the bounded SIGTERM grace period even if its leader has
already exited. The host regression test exercises a descendant that ignores SIGTERM. No global
simulator shutdown, process kill, test-job cancellation, account access, or source
publication is performed. The fixture includes no user data. Future intentional storage
migrations need an explicit retained-data assertion update; do not weaken the byte check
just to make a failing upgrade green.

## Still requires a physical iPhone

This does not verify installation through a particular signing tool, matching signing-team
identity, preserved Keychain entitlements, device provisioning, or a hosted container such
as Strata. Preserve the bundle ID **and signing identity/install destination**, install the
new IPA over the current app, and back up important notes before a first device upgrade.
Uninstalling can remove app data and is not part of the normal update procedure.

Apple Intelligence generation, microphone/speech recognition, audio routing, locked-screen
background audio, Siri, thermal/battery behavior and permission prompts still need bounded
physical-device tests. The simulator never substitutes canned inference or voice success.
