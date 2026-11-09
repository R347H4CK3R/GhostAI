# Unused chat-state v2 foundation

This increment follows the reviewed fixed-anchor, exact-byte variant and persisted-key
proposal. It does not change v1 merge, wire formats, credentials, storage, workflows,
fixtures, call sites or releases. Existing conflict/restoration IDs remain independent
family roots. The seed2 native export (SHA-256
`13f7fe96f94f4c95d5c985545189b66bda212d9c4452366b35d8738da3bf04af`)
proves the two grouping counterexamples; it is not a v2 success result.

## Implementation sequence

1. Author synthetic XCTest vectors and deterministic property tests before the helper.
2. Implement immutable values, byte identities, exact dates, validation and bounded joins.
3. Add pure projection, observations and explicitly typed deletions; no inferred imports.
4. Independently review, run existing local suites, report native execution separately.

## Deliberate boundaries

- No decoder, encoder, migration, CAS import plan/orchestrator, restore chain, mirrors,
  notes join or SavedState adapter. The complete-state values are in-memory only.
- No automatic legacy lineage inference. Establishing a family is an explicit input;
  unknown legacy IDs still need the reviewed CAS migration/import protocol.
- Projection returns immutable payload/date/reference rows, not live app ChatEntry values.
- Capacity uses a conservative JSON-size upper bound for this isolated component,
  including every retained descriptor/selector/marker. Caller-supplied reservations
  cover other records, note markers and bytes. Journal accounting reserves two chat
  snapshots. A future exact full-document codec and SavedState gate remain mandatory.
- Bounds, collisions and incompatible anchors throw; inputs remain immutable. No
  partial output, truncation, rekeying, timestamp rewrite or tombstone collection.

## Verification limits

The current Linux executor has neither Swift nor Xcode. Tests are authored first,
but their native red/green execution cannot be claimed here. Existing Python suites
and independent fixed-vector calculations are supporting checks, not Swift proof.

## Current check record

- Added 18 synthetic XCTest methods, including 48 deterministic-seed property rounds
  with all six permutations/both binary groupings, exact count ceilings, deletion
  replay, collision injection and cached reference projection. These are **unrun**.
- `xcrun swift --version` and the isolated `xcodebuild ...
  -only-testing:AsterionVeyraTests/ChatStateV2Tests test` attempt both exited 127
  because the commands are not installed. Native red/green and compilation are open.
- Existing script suite: 107 tests, 1 skip; companion suite with `TMPDIR=/dev/shm`:
  183 tests, 21 skips. Both baseline and post-change runs passed. They do not execute
  the new Swift helper.
- Four content-key/UUID fixture pairs independently recalculated with Python hashlib.
  Independent static review found no blocking issue; suggested cross-family collision
  and cached-reference tests were added. Static review is not native execution.

Before production use, review and test the complete wire codec, document byte limits,
SavedState projection, migration/restore/import CAS interleavings, mutation revisions,
mirrors, old-writer fencing and cross-language/native parity. None is enabled here.

## Synthetic native-to-Python projection evidence

The existing exact-vector XCTest now attaches `chat-state-v2-projection-evidence.json`
without adding a nineteenth test. Its distinct format is
`veyra-chat-state-v2-projection-evidence-v1`. It records five fixed synthetic source
scenarios and 44 results from the actual Swift `ChatStateV2.Engine`: NFC/NFD plus
NUL/emoji, source ordering, X100/X200/Y150 grouping, selective anchor deletion and
family deletion with stale replay/observation. The three join scenarios include all
six source permutations and both binary groupings. XCTest independently requires
every grouped result state and projection to equal the first result before export,
so a shared grouping bug cannot pass merely because both languages agree.

Inputs and result states include family/anchor/content identities, complete order
keys, orderClock, and typed family/variant/tombstone markers. Projections include
family/projected IDs, content keys, exact UTF-8 hex and binary64 date-bit hex. UInt64
facts are decimal strings. This is a fixed test-evidence schema, not a vault codec.

Run `python -m scripts.chat_state_v2_interop PATH_TO_XCTEST_ATTACHMENT.json` after
extracting the attachment from the gated native run. The comparator requires the
exact source corpus, replays the exported inputs through `companion/chat_state_v2.py`,
and compares every state/projection result without ignoring missing or extra fields.
Malformed JSON, duplicate keys, altered coverage, empty placeholders and divergent
outputs fail. Native provenance comes from that run and its xcresult, not a producer
label in JSON. Unit-test samples are Python-only gate plumbing, never native goldens
or parity evidence. Native compilation/execution remains a separate required gate;
neither comparator unit tests nor this attachment authorize production writers.
