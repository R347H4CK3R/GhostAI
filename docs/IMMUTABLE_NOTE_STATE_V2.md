# Unused immutable-note v2 join

This is an **unwired, in-memory foundation**, not a sync release or a migration.
Current app notes support add/delete/import, not in-place editing. This helper joins
that narrower model. It changes no adapter, writer, import, UI, storage or network flow.

## Facts and identity

- Each existing UUID, including legacy conflict copies and restoration IDs, remains
  independent. Equal content never merges or rekeys different note IDs.
- The immutable payload is exact UTF-8 project, text and source plus the original
  `Date.timeIntervalSinceReferenceDate.bitPattern`. No Unicode normalization,
  trimming, provenance replacement, date minimum, Unix conversion or regenerated date.
- Dates must be finite Foundation-reference seconds in [-978307200, 252423993599].
  Signed zero, subnormals and adjacent representable dates remain distinct. Project
  length is 1–300 Swift characters, text at most 20,000, source at most 2,000, matching
  legacy field ceilings. Byte reservations additionally bound combining sequences.
  Secret/scope policy is a future adapter obligation, never a reason to drop a fact.
- A binding permanently associates a known UUID with its payload hash, including
  after deletion. Every normalized live record has a binding. Bindings without either
  a body or a tombstone are invalid. Bindings are not an authenticity proof.
- A legacy tombstone without a known binding is opaque. It unconditionally suppresses
  valid incoming bodies; it does **not** prove or detect conflicts with unknown historical
  content. An observed body adds its binding before suppression, so later observations
  must agree with that binding. An opaque marker never erases an existing binding.

## Hash framing (not a document codec)

`SHA256(domain || TLV(1, project) || TLV(2, text) || TLV(3, source) || TLV(4, date))`.
The domain is exact UTF-8 `Veyra immutable note payload v2` followed by one NUL.
Each TLV is a one-byte tag, unsigned 64-bit big-endian byte length, then exact value
bytes. String values are UTF-8. The date value is its unsigned 64-bit IEEE-754 bit
pattern in big-endian order, with length 8. UUID is deliberately not part of the
payload hash; UUID ownership is checked separately and never derived from content.
Tests contain independently calculated framing and SHA-256 synthetic vectors.

## Join and rejection

All original metadata, bodies, bindings, duplicate facts and capacity are checked
before deletion normalization. Join unions compatible UUID→payload and UUID→hash
maps and the permanent tombstone set, then drops tombstoned bodies while retaining
bindings. Result arrays sort by the 16 UUID bytes, not source order, dates or hashes.

Across individually valid inputs, the same UUID with byte-unequal payloads or unequal
retained hashes raises a typed `immutableConflict`, even if tombstones hide the body.
Duplicate IDs inside one input are malformed and raise `duplicateRecord` first. Equal hashes with unequal
available payloads raise `contentCollision` (same-ID differences remain immutable
conflicts). A collision cannot be detected from hashes alone after all relevant bodies
are gone. No cryptographic hash promises mathematical collision impossibility.

Inputs are immutable values. Failure returns no partial state, never overwrites,
renames, truncates, strips provenance or evicts. Compatible normalized states have
associative, commutative and idempotent joins on the domain where all required joins
fit their budgets. Bindings survive normalization, so deletion does not erase facts
needed to reject later conflicting same-ID observations. This is not an ACI claim for
malformed/conflicting states, adversarial hash collisions or capacity errors.

An unequal imported same-ID candidate must become a future **durable, reviewable
proposal**, retaining the exact incoming data and existing state. It is not an edit,
automatic overwrite, conflict copy or rekey instruction. Proposal persistence,
resolution, explicit restoration and edit semantics are not implemented here.

## Bounds and remaining gates

Hard ceilings are 10,000 notes within 30,000 combined live records, a shared 20,000
note/chat tombstones, 8 MiB document reservation and 17 MiB journal reservation.
Callers may lower caps and must reserve other components' counts and bytes. A binding
can exist only for a live or tombstoned ID, so at most 30,000 distinct note bindings
can remain. Tombstones count once whether opaque or bound; bindings still cost bytes.
Original inputs and the complete normalized candidate must fit. No silent eviction.

The conservative component reservation is 512 base bytes, 256 per live body, 160 per
binding, 128 per tombstone, and six times the UTF-8 length of all payload strings.
The journal reserves twice that component plus the caller's other-journal reservation.
These are **reservation estimates only**, not actual encoded/encrypted byte sizes.
The future complete document/journal encoder must verify real sizes, metadata, all
other components, ownership and unknown-field handling before any write. The separate
5 MB backup/projection gate is also not implemented by this helper.

Unknown-field preservation/rejection, wire serialization, cross-platform vectors,
old-writer fencing, complete-vault shadows, CAS/receipts, migration, durable proposals
and production integration remain future work. The helper does not contact services
or read/write storage. Native XCTest was authored first but cannot run on this Linux
host without Swift/Xcode; structural review is not native verification.

## Authoring-host regression evidence

The script suite ran 126 tests with one explicit pending-native-golden skip. The
companion suite initially ran 208 tests with 2 failures, 59 errors and 21 platform
skips: the managed host's `/tmp/.git` marker triggered existing paired-identity
repository guards. Rerunning with `TMPDIR=/dev/shm python3 -m unittest discover -s
companion/tests -q` used a clean test temporary root and passed all 208 tests except
21 expected native-Windows skips. No guard or repository marker was changed. These
Python results do not verify the new Swift helper; its 22 XCTest methods and native
compilation remain unrun on this host.

## Unused Python reference and Unicode acceptance gate

`companion/immutable_note_state_v2.py` is a pure, unused reference for the same
payload framing, immutable UUID bindings, deletion union and reservations. It adds
no wire codec, storage/network access, migration, proposal persistence or production
adapter. Frozen values use tuples, canonical lowercase hyphenated UUID strings,
32-byte hash values and integer UInt64 date bits. Validation rejects coercions,
`bool` as an integer, malformed UUIDs, unpaired surrogates and invalid metadata.
`NoteStateError.code` identifies rejection; no partial state is returned.

There is deliberately **no grapheme segmentation dependency**. ASCII field limits
are counted exactly, treating CRLF as one Swift character. For non-ASCII, the
Unicode scalar count is only a conservative upper bound: a field is accepted when
that bound is at most the Swift ceiling. Otherwise the distinct
`unsupported_grapheme_boundary` failure identifies the field. That failure is
**not an invalid-record judgment**: e.g. 300 decomposed `e` + combining-accent
clusters fit Swift's project ceiling but need a compatible segmenter to prove it
here. The original candidate remains unchanged and must be retained for future
handling; it is never truncated, normalized or rewritten. A pinned,
native-compatible segmentation method and full accepted-domain equivalence are
still cross-device writer gates. Python scalar length is not claimed to equal
Swift character count.

The Python tests use fixed synthetic TLV/hash vectors, Unicode/date-bit cases,
signed zero, hidden candidates, retained/opaque tombstones, collision injection,
ACI permutations, hard/shared limits and immutable-input checks. Matching these
literals is not native-produced interoperability evidence; the Swift counterpart
and cross-device parity remain unrun on this authoring host.

The reference's authoring run passed all 29 new tests. With `TMPDIR=/dev/shm`, the
complete companion suite ran 237 tests with 21 expected platform skips, and the
script suite ran 126 tests with one existing pending-native-golden skip. Python
compilation and whitespace checks passed; no pairing guard or marker was changed.
