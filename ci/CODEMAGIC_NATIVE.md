# Manual Codemagic PR9 evidence plan

This control branch adds only a manual root configuration, command manifest,
minimal runner, its tests and this document. It never changes the candidate.
Each invocation clones the local configuration checkout into a new candidate
checkout, checks out 486686fbca2ee13f61039261c87ba01c75bf8d22, verifies tree
10b36d1d87aed2bb967f7c37003bd0016f45b083 and clean tracked files, and repeats
that verification after execution. Configuration commit/tree and tested
commit/tree are distinct fields in native-evidence/result.json.

Run pr9-tls, then pr9-native, then pr9-package manually on the same reviewed
configuration commit. The operator must inspect actual success, result.json,
stages.json and logs from the previous workflow before starting the next. No
automatic prerequisite enforcement or external receipt import is claimed.
Do not start another workflow on failure, timeout, missing evidence, source
mismatch, skipped required gate, unsupported infrastructure or depleted free
minutes. Confirm the personal free plan and disabled billing before each run.

All workflows select mac_mini_m2 and Xcode 26.2; no integration, credential,
signing, publishing or automatic trigger is configured. The runtime listing
is independently capped at 60 seconds; owned boot at 6 minutes; native compile
25; lifecycle 8; interactions 12; privacy 8; unfiltered suite 45; destination
120 seconds; per test 120/180; parallel testing NO. The TLS test allows the
release contract's 25 minutes and therefore the TLS workflow permits 40 minutes.
Both upgrade scripts retain their 1080-second internal budgets with 20-minute
outer deadlines and exact publicly fetched allowlisted build17/build44 commits.
Only these scripts' owned simulators/process groups are cleaned up.

The native workflow allows 120 minutes and package workflow 60 minutes.
Their aggregate worst-case command caps plus setup can exceed the provider
workflow cap: a slow run must FAIL, never shorten a test, omit a gate or treat
incomplete output as passing. Hard provider termination can prevent final
artifact/status writes; missing evidence is failure. Logs are written during
each command; ordinary failures and SIGTERM retain stage failure and attempt
owned cleanup, including diagnostics after earlier test failure. Candidate Python
entry points that own nested process sessions run through a control-only signal
wrapper. It converts the first SIGTERM/SIGINT into KeyboardInterrupt so the
unchanged candidate Runner and finally blocks can clean up. Subsequent signals
are ignored during cleanup. The outer wrapper permits up to 180 seconds of
cleanup grace after cancellation, beyond the unchanged gate deadline. This
covers bounded nested termination, diagnostics, simulator deletion and attachment
export. Cleanup receipts require completed child exits, no cleanup warnings,
and confirmed deletion when an upgrade created a simulator. Missing or incomplete
receipts fail closed; provider hard kills still cannot guarantee cleanup.

The test manifest copies pinned ios.yml native commands and the release
workflow TLS, live upgrade and package commands. Adaptations are local
simulator environment file (not GITHUB_ENV), source checkout pinning, explicit
deadlines, retained evidence, owned TLS simulator, and verification-only build
9009 with version 0.4.0. Build9009 is not a reserved publication build number.
ZIP CRC, icon and jarvis_release.validate_ipa checks run without calling its
stage/finalize methods or providing GitHub environment variables. All evidence
is synthetic app test output and source. Artifacts remain in the private
Codemagic account. Do not publish their links or add user data/secrets.

This is native evidence only, not a release authorization or substitute for
Linux/Windows/macOS companion and Android gates. jarvis_release.py still
requires genuine GitHub context and checks; external success must never be
passed to its finalizer or represented as a GitHub run. Publication needs a
separately reviewed path after all required evidence actually succeeds.

Local validation: python3 -m unittest discover -s scripts/tests -v.
No macOS gate has been run by preparing this branch.
