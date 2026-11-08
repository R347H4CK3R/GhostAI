# SideStore updates

About → App updates shows the installed version and offers an explicit update check.
The check reads the public GhostAI latest GitHub release, with no account token or
application content. Only a non-draft, non-prerelease tag named ios-build-N with
one exact AsterionVeyra-unsigned.ipa asset in this repository is accepted.
Only a numerically newer build is offered. Metadata is limited to 256 KiB,
timeouts are finite, and metadata redirects are rejected. Offline/error/empty
release states do not modify local app data.

After a separate confirmation, the app opens SideStore using its documented
sidestore://install?url= scheme. SideStore downloads, signs and installs the IPA.
The app does not report that opening SideStore means installation succeeded.
If SideStore cannot open, the screen explains the manual Releases route.

## Release preparation

The initial updater-bearing IPA must still be installed through SideStore once.
Keep the installed app and signing account; do not uninstall before upgrading.
Export important chats/notes first. The bundle ID is unchanged by this feature.
The existing simulator upgrade gate and physical SideStore upgrade testing are
both needed; a simulator cannot establish signing-account or device retention.

The current build workflow creates CI artifacts, not public install URLs.
This change adds a manually dispatched Publish verified SideStore update workflow.
After integrating on feature/paired-execution-protocol, run the existing full
iOS workflow. Publish using that successful workflow run ID. GitHub requires a
workflow_dispatch workflow to exist on the default branch before it can receive
dispatches; install the reviewed publication workflow/script/tests there as well,
then dispatch with the release branch selected. Do not merge unrelated preview
features into main just to enable this workflow.

The publisher checks the original repository, exact source branch, workflow path,
push/manual event, complete success, and all required platform jobs. It downloads
the existing IPA artifact and verifies its bundle identifier, iPhoneOS platform,
and embedded build number against the verified run. It refuses replacement or
downgrade of published build tags. Publication creates a public latest release
with a build-specific URL and links back to exact CI and commit evidence.
Publication is deliberately separate from normal pushes and PR tests. The
publisher atomically creates the build tag at the verified commit before creating
the Release with --verify-tag. Any existing tag blocks publication rather than
being reused or overwritten. If publication stops after tag creation, inspect
its exact commit and the partial Release manually before deciding how to recover;
the publisher never automatically deletes or replaces either.

## Verification

AppUpdateTests covers newer/equal/older build handling, exact SideStore URL
construction, unrelated/invalid release tags, draft/prerelease rejection,
foreign/mismatched asset URLs, bad sizes, malformed data and metadata bounds.
Python publication-policy tests cover run validation, artifact identity and
orchestration: failed jobs, existing releases, mismatched IPA builds and existing
tags all stop before publication. These tests run locally without calling GitHub.
Native XCTest also covers repeated check starts, cancellation, missing/duplicate
IPA assets, and temporary or credential-bearing URL rejection. A UI test records
the update screen and verifies entering/re-entering it never starts a network
check or installation automatically. Swift/Xcode execution and these screenshots
require native CI; Linux authoring checks are not a native pass.
Device checks must include SideStore missing/present, cancelled handoff,
offline/timeout, and installing over the prior build with chats/notes retained.

Reference: https://docs.sidestore.io/docs/advanced/url-schema

## Stable SideStore source

The planned source URL is:

`https://raw.githubusercontent.com/R347H4CK3R/GhostAI/sidestore-source/source.json`

**Do not advertise this as live until publication and anonymous readback succeed.**
No placeholder source file or placeholder app entry is committed to the app branch.
The source branch is created only for an already public, byte-verified IPA. Its
initial commit contains only `source.json` and public build `provenance.json`.
Later updates atomically replace both in one non-forced fast-forward commit.
This route does not require Pages setup and is independent of GitHub's mutable
latest-release selection, which an unrelated release could change.

The source uses the AltStore Classic schema supported by SideStore. It includes
one app with exact Info.plist version/build, bundle ID, minimum OS, privacy usage
descriptions, released IPA URL, byte size and SHA-256. The icon URL is pinned to
the verified app commit. No marketplace identifier is included. The current
single unsigned ARM64 app advertises no entitlements; signed executables,
provisioning profiles, extensions, nested apps, symlinks and noncanonical ZIP
paths fail closed pending explicit support. App content, credentials, pairing
material and signing identities are never copied into the source/provenance.

### Activation

1. Install the reviewed workflow and its Python dependencies/tests on the default
   branch so GitHub can dispatch it, and on the selected release branch so that
   checkout executes this version. This does not require rebuilding or changing
   the previously verified app binary. Keep default-branch activation separate
   from unrelated preview features.
2. Dispatch `Publish verified SideStore update` on
   `feature/paired-execution-protocol` with the successful original iOS `run_id`.
   Default `source_only=false` first publishes the exact existing artifact with
   the existing release publisher, then independently verifies and publishes the
   source. Never replace an existing tag or release.
3. If that exact release is already public, `source_only=true` skips release/tag
   creation entirely. This is also the explicit recovery path after a partial
   release/source workflow. It still repeats every verification check. Inspect
   uncertain outcomes before invoking it; equal/older source builds are refused.
4. Verify the canonical source anonymously, confirm its exact build-specific IPA
   URL, download and compare the IPA bytes/hash, and verify the commit-pinned PNG.
   The source branch's `provenance.json` must match the original run/attempt,
   packaging attempt, artifact, commit, release/asset IDs, size/hash and source.
   Check SideStore import on a device before claiming device compatibility.

The source step checks the successful original repository/branch/workflow/run,
latest job results and the artifact's timestamp against the successful iOS
packaging job. Previously successful latest jobs may come from an earlier
attempt of the same unchanged run. The run and packaging attempts, artifact and
release identity are checked again immediately before source publication.
Downloads are anonymous, bounded and restricted to HTTPS GitHub asset hosts.
Tag, source identity, asset URL/size/hash, stale-attempt, rollback and concurrent
branch changes stop publication rather than silently choosing another artifact.
Ordinary release download counters do not invalidate an otherwise exact match.

A failed source step leaves the existing source branch unchanged. A GitHub ref
write whose response is uncertain must be read back before any further action.
The publisher never retries writes, forces refs, or deletes/rewrites releases.
Raw GitHub caching can temporarily serve the preceding valid feed; allow cache
refresh and verify the returned bytes rather than claiming instant availability.

Once verified live, add the HTTPS URL above under SideStore Sources. The optional
add-source deep link is `sidestore://source?url=` followed by the percent-encoded
HTTPS URL. It is distinct from the existing `sidestore://install?url=` app action.
Keep the installed app and same signing account, export important data first,
and never treat a source refresh as evidence that an update installed or retained
user data.

### Source references

- https://docs.sidestore.io/docs/advanced/app-sources
- https://faq.altstore.io/developers/make-a-source
- https://faq.altstore.io/developers/updating-apps
- https://faq.altstore.io/release-notes/altstore (buildVersion, SHA-256 and permission verification)
