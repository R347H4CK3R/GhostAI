# Synthetic native chat-state v2 evidence

`native-chat-projections.json` is the unchanged XCTest attachment emitted by
`ChatStateV2Tests` on a real iOS Simulator run, not Kotlin/Python-generated output.
Every field was inspected before inclusion: payloads are only fixed synthetic
`General`, `user`, `assistant`, `X`, `Y`, `Z`, NFC/NFD café, emoji, NUL and newline
fixtures; identifiers, date bits and hashes are synthetic test facts. No user
content, credentials, device state, or private configuration is included.

Provenance:

- Repository: https://github.com/R347H4CK3R/GhostAI
- Source: `8e32980a745a24b9df91bed38c55a63a7c51ff1a`
- Tree: `65f7d92cfc00557c44e3a46a6a4a28f52d950f98`
- Run: https://github.com/R347H4CK3R/GhostAI/actions/runs/42543836823/attempts/2
- Native job: `128925472897`; artifact: `13643805593`
- Artifact ZIP SHA-256: `31bfdd641820be6c1db911690ee99da0cbdf4fa33f1e9569facc713ecbda1ab0`
- Original xcresult attachment: `29189621-9741-41E6-9969-C1022D7D0AA3.json`
- Fixture bytes: `158421`
- Fixture SHA-256: `e799774a7f823224779cb7fadefa1a3952563a36369e23f15c0210a859f768ca`
- Native chat tests: 18 passed, 0 failed, 0 skipped. Exact-source provenance
  records were clean. The independent Python comparator matched all 44 results.

The corpus has five fixed scenarios: Unicode, established source order and
same-family date grouping each have six permutations and two binary groupings;
selective deletion replay and family deletion replay each have four stages.
The Kotlin replay compares every input, result label, complete normalized state,
ordered projection, exact UTF-8 hex field, date bit pattern, ID, order tuple,
selector and tombstone. Resource integrity is tested separately from adversarial
comparison tests so a changed checksum cannot substitute for replay coverage.

This is a bounded **test-evidence schema**, not a production vault codec,
serialization-size proof, migration implementation, or writer authorization.
It does not approve or replace the still-divergent v1 legacy golden evidence.
Build 44, production callsites, storage and networking are unchanged.
