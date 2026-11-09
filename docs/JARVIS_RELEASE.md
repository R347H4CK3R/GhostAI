# Jarvis unsigned release candidate

## Scope and baseline

The branch-only workflow is `.github/workflows/jarvis-release-candidate.yml` on
`feature/unified-assistant-planning` in public `R347H4CK3R/GhostAI`.
Package identity stays `dev.asterionveyra.assistant`, executable/module stays
`AsterionVeyra`, and storage must remain unchanged. The release verifier requires
Jarvis display name, version `0.4.0`, and build equal to this workflow's run number.
Run numbers are scoped to a workflow; they are not a global release counter.

The integration must preserve the complete live 0.3.6/build44 source tree at
`59aa7329efa87ce01b247ca309941c20b2e3dc8d`, including private-memory-sync and
library fixes, rather than replacing it with the earlier Jarvis base
`e751ed7aded50669a2b0f9fe501ead670ef62269`. The candidate workflow preserves the
additional private-memory-sync reference test gate found at the live commit.
The existing parent `ios.yml`, update feed, and default branch are not modified.
The older narrow native candidate workflow becomes manual-only to prevent
its push-triggered duplicate run.

## Gates and cost boundary

Six standard public verification runner executions are retained:

1. Desktop companion tests on Ubuntu.
2. Desktop companion tests on Windows.
3. Desktop companion tests on macOS.
4. Android unit tests, lint, and debug assembly.
5. Native pairing TLS preflight.
6. Native source icon validation and Python script tests, the complete unit/UI
   suite, screenshot export, encrypted Swift-to-desktop transfer, private-memory
   sync reference tests, retained simulator upgrades from both pinned releases, unsigned device compilation,
   IPA ZIP validation, and packaged app icon validation.

The native job depends on all five prerequisite executions. A seventh lightweight
Ubuntu finalizer waits for all six verification executions, including the native
job and its post-job cleanup, to complete successfully. The parent workflow's
verification commands are preserved. No test filtering is added to its full
native suite. The existing separately filtered TLS preflight remains additional.
The native job runs only on successful prerequisites, and only draft staging runs inside the native job. Public publication happens
only in the finalizer after the native job completes successfully. Release verification independently checks those
live GitHub job/step results for the same run attempt and commit. The finalizer
requires every verification job to be completed with success.

There are no Actions artifact uploads or Gradle cache writes. Releases hold only
`Jarvis-unsigned.ipa`, `SHA256SUMS`, and `VERIFICATION.md`. This avoids the existing
Actions artifact-storage limit and uses public standard runners, not paid larger
runners. This file is a plan/configuration, not proof that CI or a release ran.

## Publication safety

The publisher requires the original public repository, exact branch/workflow,
push or workflow-dispatch event, active run, run number, current attempt and
commit, all successful prerequisite jobs, and each completed native gate. It
checks the branch still points to the tested commit. It validates bounded ZIP
metadata, unique safe entries, no symlinks/traversal/extra apps/signing payload,
app identity/platform/version/build and executable presence, and ZIP CRCs.

Only the native draft-staging job and lightweight publication finalizer have
`contents: write`; `actions: read` permits independent job evidence checks. Every checkout disables persisted credentials. `GH_TOKEN`
is scoped to the explicit draft-staging or publication step. No saved credentials or new secrets
are created.

The tag `jarvis-v0.4.0-build-N` is atomically created at the tested commit, then
its exact commit identity is checked. Existing tags fail closed. `gh release
create --verify-tag --draft --prerelease --latest=false` refuses existing releases.
The three assets are downloaded from the draft and checked before staging
completes. Their hashes become native-job outputs. After the entire native job
succeeds, the finalizer downloads the draft again, checks all three hashes against
those trusted job outputs, rechecks IPA metadata, tag identity and draft status,
then publishes as a non-latest prerelease. No overwrite, force,
clobber, automatic retry, tag deletion, release replacement, update feed edit,
or default-branch edit exists in the publisher.

A failure after tag creation intentionally leaves a tag and possibly a draft.
Inspect manually; never automatically replace it or rerun publication with the
same build number. A workflow rerun keeps its run number and therefore fails if
that tag already exists. A new approved run has a new number.

The active native job creates only a draft, never a public release. A native
post-step or cleanup failure prevents the finalizer from running. Finalization
requires all six completed successful verification jobs and rejects missing hash
outputs, modified assets, existing public releases, or mismatched tags. The
workflow itself is still active during finalization; all verification jobs have
finished, but this does not claim that later finalizer cleanup already succeeded.

## Limits and required checks before use

The preserved simulator upgrade gate defaults to version 0.3.0 build17
(`8074b807a864a79e659200ee9521141c3c00df98`). An additional 20-minute bounded
`jarvis_verify_upgrade.py` gate pins live 0.3.6/build44 at `59aa7329efa87ce01b247ca309941c20b2e3dc8d`,
with a separate evidence directory. The underlying verifier accepts only exact
allowlisted commit/version/build tuples and checks real baseline app metadata;
the original defaults, no-uninstall behavior, fixture integrity and continuity
checks remain intact. Both gates are required before publication. These retain
synthetic canonical chat/note fixtures and a preference/continuity marker. They
do not prove actual private-sync keys, remote state, real user data, or physical
device persistence.

An unsigned IPA requires user-controlled signing and installation. Simulator
checks do not prove physical-device behavior, SideStore data retention, signing,
keychain continuity, voice/background behavior, external model access, or paired
desktop setup. Keep the old installation and signing account and export important
data before an upgrade. No provider credentials or online services are bundled.

Local checks: `python3 -m unittest discover -s scripts/tests -v`.
The publisher tests exercise real ZIP/metadata/checksum validation and mocked
GitHub command boundaries, including stale runs, failed/skipped/missing gates,
existing tag, wrong tag commit, upload failure and downloaded hash mismatch.
They never contact GitHub or publish. Full native/Android/desktop verification
must run in the appropriate runners against the final reconciled commit.

Runtime requirements: iOS 26+. Generative chat requires supported Apple Intelligence hardware, enabled Apple Intelligence and downloaded OS-managed assets, not embedded model weights. Local notes/templates work without available inference. No credentials, private histories or paid service entitlement are bundled.
