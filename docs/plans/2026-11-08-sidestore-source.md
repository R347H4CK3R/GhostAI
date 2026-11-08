# Verified SideStore source

## Design and route

Publish one real Asterion Veyra app entry, derived from a verified unsigned IPA,
to a dedicated `sidestore-source` branch. The planned canonical URL is
`https://raw.githubusercontent.com/R347H4CK3R/GhostAI/sidestore-source/source.json`.
It is not live until publication and anonymous verification succeed. This avoids
GitHub Pages configuration and unrelated releases moving a `/releases/latest/`
redirect. A source branch does need one extra atomic Git ref update. A source
asset on each release is simpler but its stable latest URL can change to an
unrelated release, so it is not the chosen route.

Source schema follows official SideStore App Sources and AltStore Make a Source
documentation. Include exact bundle, marketing/build version, download URL, byte
size, SHA-256, minimum iOS, privacy descriptions, and immutable icon URL. Never
include marketplace fields, app data, placeholder apps, signing identities or
credentials. The current unsigned single-app payload has no entitlements; fail
closed on signed executables, embedded provisioning, or extensions until explicit
permission extraction supports those layouts.

## Implementation

1. Add source generation and tests. Validate required IPA metadata, one top-level
   app, unsigned ARM64 executable, permissions and iOS >=26. Derive all version
   fields from IPA bytes and bind the download URL to `ios-build-N`.
2. Add a separate publication script that revalidates successful original CI,
   latest attempt jobs and exact artifact identity. Require an existing public
   release, exact lightweight tag commit and one exact asset. Download both CI
   and released IPA; compare SHA-256 and size before constructing the feed.
3. Read existing source/provenance at the source branch's exact commit. Reject
   identity changes, equal/older builds and mismatched feed/provenance. Create
   source and provenance in one commit and advance the branch without force.
   Recheck CI attempt and tag before the write. Concurrent changes fail closed.
4. Run this after the existing release publisher in the same serialized workflow.
   Update activation/recovery documentation, run all script/companion tests and
   obtain an independent review before publication.

## Activation and recovery

Release maintainers must review and activate the workflow/scripts on the default
branch and release branch before publication.
Publish only after full native, transfer, upgrade and IPA evidence is complete.
The new source step does not build or sign. A failed source step leaves the old
source intact. It never deletes tags, releases or source history. Inspect partial
publication before any rerun. A reviewed source-only run may finish an already
published exact release; the normal release step refuses replacement.

Verify anonymous source JSON, immutable icon and IPA access, exact bytes and
metadata, then test adding the source on SideStore. Never describe CI or source
HTTP checks as a device install or retention pass.

## Review focus

- Stale workflow attempts, foreign run/artifact and missing jobs.
- Tag/asset URL substitution, duplicate IPA assets and byte/hash disagreement.
- Same marketing version with a newer build, rollback and concurrent ref races.
- Privacy metadata, unsigned payload assumptions, malformed/duplicate ZIP entries.
- Source identity, atomic update, private data exclusion and partial failure.
