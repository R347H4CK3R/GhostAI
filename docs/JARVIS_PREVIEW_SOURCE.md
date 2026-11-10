# Jarvis preview source

The opt-in SideStore source is https://raw.githubusercontent.com/R347H4CK3R/GhostAI/jarvis-preview-source/source.json. Stable feeds and release selection remain unchanged. The preview intentionally shares Asterion Veyra's bundle identifier, so it can replace an existing installation. Export important notes and chats before updating, retain the installed app and signing account, and do not assume physical-device retention from simulator checks.

## Publication design

Publish a separate feed only after the existing Jarvis prerelease finalizer succeeds. Reuse all existing native and companion gates. Check exact commit, run/attempt, public tag/release, native-job hashes and anonymously downloaded IPA bytes. Extract version, build, minimum OS and privacy permissions from the IPA. Reject unsigned-package surprises, stale attempts, changed release assets and non-monotonic updates. Update only the dedicated preview branch with a non-forced fast-forward, keeping the prior source intact on failures before the atomic branch update. After that update, verification failures leave the new commit in place for inspection; never roll it back or blindly retry the write. Anonymous source verification makes three bounded read-only attempts with a commit-keyed cachebuster and exact branch readback. No releases, app identity, stable feeds or default-branch data are changed by this publisher.

## Implementation and verification plan

1. Write failing tests for exact preview rendering, release/context rejection, previous-source validation and atomic publication behavior.
2. Implement the isolated preview publisher using the existing package validation and anonymous-download helpers.
3. Append a publisher step after successful prerelease finalization in the existing workflow, with the native job's exact output hashes.
4. Run all Python script and desktop companion tests. Review source branch mutations and failure paths independently. Integrate with the next authorized Jarvis candidate rather than trigger a duplicate device build.
5. Verify the public JSON and IPA after the next complete native CI run. Physical signing, installation, background voice and retained user data still require device validation.
