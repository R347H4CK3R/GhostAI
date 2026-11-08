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
