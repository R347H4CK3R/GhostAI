# Foreground paired desktop jobs: 0.3.3 preview

This source adds a reviewed desktop setup/approval console, a maintained HTTPS
adapter and an iPhone **About → Review paired desktop setup** screen. Nothing is
preconfigured. Development used disposable synthetic state and loopback tests,
not the user's devices, files, credentials, network or firewall.

**Device and broader release verification is still required.** Real-phone
URLSession/Keychain behavior and physical-device pairing are not established here.
Windows protected storage is enabled by default after native DACL/DPAPI and
synthetic lifecycle tests passed independent review. This enables the explicitly
approved setup flow; it does not create state or start a listener by itself.
There is no command-line/environment bypass. Each release candidate must verify
the enabled-default path in native Windows CI.

## Scope

- One exact, explicitly configured private IPv4 HTTPS origin. No discovery,
  public Internet listener, cloud account, relay, automatic startup or firewall edit.
- Explicit desktop approval grants a phone bounded **read-only** jobs in selected
  workspaces, using a trusted already-installed local model.
- Foreground iPhone submission, durable acceptance, result/status retrieval and
  cooperative cancellation. Closing the pairing screen stops phone networking.
  Desktop jobs can continue only while the foreground host remains running.
- No remote shell, workspace writes, downloaded executable tools, purchases,
  publication, arbitrary app control or automatic memory synchronization.
- Job grants share no existing notes implicitly. The paired executor supplies
  empty project-memory context and a separate private audit database.

This is separate from manual encrypted note transfer and the standalone companion's
operator-authorized local writes. Android pairing is not implemented. Laptop sleep,
network changes or a closed desktop console make the paired host unavailable.

## Reviewed desktop setup, after release gates

Use Python **3.11+** (CI uses 3.12), an isolated Python environment and the pinned
runtime requirements. `aiohttp` owns HTTP parsing; version pinning is not a security
certification. Review advisories and repeat native/parser/TLS tests on updates.

```sh
python -m pip install -r companion/requirements-pairing.txt
python -m companion.paired_server setup \
  --state /absolute/new-private-state \
  --origin https://192.168.1.20:8443 \
  --workspace /absolute/dedicated-workspace \
  --label "Selected project" \
  --model installed-local-model
```

The paths/address above are examples. Select a dedicated workspace rather than a
home directory. Setup previews the exact scope and persistent-access consequences.
Only typing `SET UP` creates the protected identity/configuration. Setup does not
listen or install/configure the model.

Keep state outside the selected workspace **and every Git working tree**, including
unrelated repositories. Never use cloud-synced or shared folders, including synced
Desktop/Documents, OneDrive, iCloud Drive or Dropbox. Cloud-sync status is not
reliably detectable by this setup flow.

The state directory and every ancestor are checked for a `.git` entry using
filesystem metadata only. Directories, worktree/submodule marker files and symlinks
are rejected without reading their contents or resolving a gitdir target.
Missing/inaccessible/replaced ancestry fails closed. Checks repeat after approval,
before credential creation and on protected state reads. Moving state under Git
prevents reopening it; this cannot undo an earlier upload. The owner must not
concurrently replace ancestry or create a repository around a running host.

Fixed generated key/state filenames are also ignored in this repository as defense
in depth. Ignore rules do not protect forced adds, already tracked files, arbitrary
backups or dynamically named job checkpoints. Never copy the private state tree
into source control or an app memory export.

Launch is a separate explicit review in a private interactive terminal:

```sh
python -m companion.paired_server serve --state /absolute/private-state
```

Typing `START` binds only the configured IP/port using existing network settings.
No listener starts on import or from merely opening the iPhone screen. Terminal
redirects are refused to avoid saving invitation secrets to logs.

Fixed local console commands:
- `projects`: show locally configured scope.
- `invite PROJECT_ID`: display a private ten-minute invitation.
- `pending` / `devices`: inspect enrollment and grants.
- `approve DEVICE_ID SAFETY_CODE`: compare both screens, review the exact workspace,
  model and budgets, then type `APPROVE` for persistent read-only access.
- `revoke DEVICE_ID`: explicitly revoke future access and request cooperative stop.
- `quit`: stop the foreground host.

No network route can create invitations, approve devices, change grants or revoke
another device. Invitations are memory-only; unapproved enrollment expires on host
restart. The local console is fixed commands, not a shell.

## iPhone flow and storage

Paste the descriptor from the trusted owner-controlled desktop display. Review its
exact origin, SHA256 leaf-certificate fingerprint and persistent-access warning;
confirm direct installation and that the desktop display was verified. Those
acknowledgments are bound to an immutable preview token, so another window cannot
silently replace the reviewed invitation. The installation acknowledgment is not
a technical detector of container/wrapper apps.

Only the explicit pairing button creates the phone signing key. Compare the safety
code before approving on the desktop. Approval does not grant arbitrary actions.
Select a granted project, exact goal and finite budgets before submitting each job.
Durable acceptance is not completion; model summaries are not independent proof.

The key, replay counter, small outbox and job references are one bounded 96 KiB,
non-synchronizing Keychain item using `WhenPasscodeSetThisDeviceOnly`. A device
passcode is required. Weak/unreadable records are rejected, never upgraded or
recreated silently. Removing the passcode can destroy the identity. Revoke the
old device locally before explicitly pairing again. Native passcode/backup/restore
behavior must be verified before release.

Each request burns and persists its counter before sending. Submission/cancellation
operation IDs and exact bytes survive retries; request IDs/counters are fresh per
attempt. The client cannot replace an unresolved submission silently. An explicit
warning allows retaining up to two immutable archived submissions after checking
the desktop, with same-ID reconciliation. Nothing is silently evicted. Twenty
saved job references is a hard limit, including restored submission retries; full
storage stops new submission before I/O.

Pending enrollment expires locally even offline. One App-owned client serializes
all windows; individual screens contribute visibility and foreground state. Polls
are throttled to five seconds. Backgrounding cancels networking but does not claim
an uncertain request never reached the desktop. Forgetting on the phone removes
local credentials/history only. Desktop revocation is authoritative; earlier reads
or information already received cannot be recalled.

## TLS and HTTP boundaries

The app pins SHA256 of the exact leaf DER and separately requires matching private
IP SAN, certificate dates, serverAuth EKU and platform SSL trust. Trust is app-local;
no CA is installed. Sessions are ephemeral, with no cookies, credential cache,
redirects, HTTP fallback or intended application-proxy use. No broad ATS exception
is added. Native tests must prove trust rejection sends zero HTTP/auth bytes and
that actual proxy/PAC behavior and reserved headers meet the contract.

The server accepts HTTP/1.1 fixed POST routes, exact origin authority, canonical
Content-Length and application/json. HTTPS 443 allows only equivalent IP or IP:443
Host spellings; other ports must match exactly. Duplicate security/Host headers,
Origin, transfer/content encoding, Expect, upgrades, aliases and query strings are
rejected. Requests/responses are not logged; parser errors never echo request data.

Bounds: eight accepted connections before TLS, five-second handshake deadline,
ten-second request deadline, 8 KiB headers, 4 KiB enrollment/256 KiB signed bodies,
120 attempts/minute, two outstanding requests/device and eight actual host workers.
Disconnecting cannot release a running worker's admission slot prematurely.
Canonical received-header-prefix and byte-count checks reject already-buffered
extra requests/content; later bytes cannot be predicted. Every response closes and
no second request is executed. Unexpected dispatcher failure refuses new jobs.

Identity certificates are self-issued P256 leaves for exactly the reviewed IP,
valid 30 days, with TLS 1.2 minimum and tickets disabled. No automatic identity reset,
rotation or repair occurs. Expiry/address changes require deliberate reconfiguration.
POSIX files/directories require owner-only permissions and reject links. Windows
candidate storage uses protected current-user/SYSTEM DACLs, held ancestry/file
handles and current-user DPAPI protecting the password for encrypted PKCS8. No
plaintext temporary key file is created. This does not defend against malware
running as the same local OS account; all private ancestry must remain trusted.

Windows storage also rechecks the protected state directory and every direct
state artifact before mutable operations, including registry/audit SQLite sidecars,
checkpoints, temporary files and locks. Mutable files require current-user ownership
and only current-user/SYSTEM full-control ACEs. New files have an explicit owner
and protected DACL from creation; inherited ACEs on safe existing files are also
allowed. Directory ACL inheritance alone does not inherit ownership: native CI
confirmed that an elevated token can otherwise create Administrators-owned locks,
temporary files, databases and journals. No token policy or privilege is changed.
Paired databases use explicitly precreated rollback journals and TRUNCATE mode,
which retains the owned journal file on commit/rollback. WAL database headers are
refused before SQLite can create shared-memory sidecars. Broad/null/unsupported DACLs, wrong owners, links and unexpected
subdirectories are refused without repairing permissions or resetting state.
A private parent alone is insufficient because Windows bypass-traverse privileges
can expose a known child with its own permissive DACL. Mutable-file checks use
metadata-only handles compatible with SQLite, byte-range locks and replacement;
they do not weaken the stricter identity reader. Short storage operations are
serialized, but model/tool execution does not hold the host lock, so cancellation
and status requests remain available. Same-account hostile concurrent changes are
still outside the protection boundary.

## Protocol and durable execution

App-facing routes:
- POST `/v1/pair/begin`: invitation proof + device-key signature.
- POST `/v1/pair/status`: signed approval/grant polling.
- POST `/v1/jobs/submit`: signed immutable read-only operation.
- POST `/v1/jobs/get`: signed own-job status/result.
- POST `/v1/jobs/cancel`: signed immutable cooperative cancellation request.

Strict schemas reject duplicate JSON keys, floats, unknown fields and ambiguous
UUID/base64/sequence encodings. Device names reject Unicode categoryC, including
private-use and unassigned scalars; runtime Unicode versions still need parity
checks. Keys use P256 X963 public encoding; signatures are fixed 64-byte low-S r||s.
Frames and shared public synthetic fixtures live in `paired_protocol.py`,
`PairedExecutionProtocol.swift` and `Tests/Fixtures/paired-execution-v1.json`.
The reconstructed frame domains are `VEYRA-PAIR-V1` and `VEYRA-REQUEST-V1`.

A signed frame binds host/device IDs, monotonic sequence, request UUID, POST route
and SHA256 of exact body bytes. The host commits the replay high-water mark and
accepted operation atomically before returning 202. Valid authenticated but invalid
requests still consume their sequence. Reusing an operation ID with different bytes
fails. Counter rollback causes refusal, never guessing a new counter.

Accepted jobs persist immutable workspace/model/permission/budget snapshots. Only
the existing `AutonomousJob` executor runs. Cancellation/revocation/reconfiguration
are checked at executor checkpoints. Durability includes bounded checkpoints,
immutable job IDs, private audit state and result recovery without replaying a
terminal checkpoint's effects. Persisted IDs/types are validated before filenames
or execution; malformed state fails closed. A crash leaving the initial checkpoint
hardlinked is deliberately refused, not recreated or reexecuted.

Bounds also include 64 device rows, 16 live invitations, 1000 retained jobs,
four queued/running jobs per device, one executing job, a ten-minute queue TTL and
a 32 MiB registry. Full stores fail visibly; automatic garbage collection and broader
lifecycle/recovery are separate work. Shutdown and file I/O are cooperative, not a
claim that cancelling a Python await forcibly terminates an OS operation.

## Verification and release gates

```sh
python -m unittest discover -s companion/tests -v
python -m unittest discover -s scripts/tests -v
```

Synthetic tests cover real loopback TLS, signatures, admission/framing bounds,
replay/revocation, durable jobs, actual bounded file reads, setup rejection and
Git-location/private-storage guards. Use a temporary directory outside Git; this
authoring runtime requires `TMPDIR=/dev/shm` because its normal temp/workspace roots
contain `.git` markers. No marker is removed or masked for testing.

Native Windows storage evidence: [run32, Windows job](https://github.com/R347H4CK3R/GhostAI/actions/runs/42496753893/job/128780637235)
tested preview `2df442265ca5095b99f53d13459cdc4b88cc3e69`, tree
`493d1a7fea7b9b95153623d03f3ce2d9471f77aa`: 170 tests, 152 passed and 18 expected
platform-specific skips. All nine native identity/DACL/DPAPI/TLS tests and all eleven
mutable-storage tests passed, including wrong-owner and symlink cases without
skips. Coverage includes approved setup → enrollment/approval → bounded synthetic
job → audit/checkpoint → close/reopen/result recovery, unsafe artifact ACLs,
directory weakening, retained journals and actual process-crash recovery.
Independent review found no remaining Windows protected-storage activation blocker.

The mutable-storage suite now exercises normal setup and the full lifecycle
without overriding the release flag. Release candidates must pass that unpatched
Windows suite too. A skipped wrong-owner or other required native case is missing
evidence, not a pass.

Separate native/device release gates include full Swift/XCTest verification,
actual Keychain/passcode/restore, TLS rejection before bytes, Host on
ports 8443/443, proxy/PAC/redirect handling, cancellation, multiple windows and
physical Python↔Swift pairing/jobs. Current synthetic evidence is not proof that
actual devices are paired or that the feature is production-ready.
