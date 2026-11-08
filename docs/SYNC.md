# Manual encrypted memory transfer

This is a manual export/import feature for the Python desktop companion on macOS,
Windows and Linux. It is **not real-time sync**. The native iOS and Android apps
**cannot yet decrypt or import this format**. There is no remote service, account,
automatic upload, network connection, background synchronization or key exchange.

Install the optional encryption dependency in the companion's Python environment:

```sh
python -m pip install -r companion/requirements-sync.txt
```

Use the companion CLI's export/import commands when available. The passphrase must
be entered interactively with hidden input, not supplied in command arguments,
environment variables, task logs or saved configuration. Use a long, unique
passphrase and retain it securely yourself: there is no recovery mechanism. Share
the encrypted file between your own computers using a transfer method you trust.
Keep the passphrase separate from the file. No transfer is initiated by this module.

## Developer API

```python
from companion.sync import export_snapshot, import_snapshot, SyncError

count = export_snapshot(memory, "work.memory.enc", passphrase, project="work")
# Alternative, deliberately including every project:
# count = export_snapshot(memory, "all.memory.enc", passphrase, all_projects=True)
report = import_snapshot(other_memory, "work.memory.enc", passphrase)
```

`memory` is an existing `companion.core.Memory`. Export requires exactly one project
or explicit `all_projects=True`. Export creates a new file and refuses to overwrite
an existing file. Its return value is the exported record count. Import returns
`added`, `duplicates`, and `conflicts`, with each conflict containing `original_id`
and `imported_id`. Display that report to the user. The API never logs passphrases
or contents. The CLI must not print memory text as part of a transfer status.

Only memory records are included: ID, project, body, source, and original creation
time (Unix seconds). Original source/date provenance survives every import. Task
logs, application settings and credentials are not exported. Every exported and
imported record passes `Memory.add`'s existing credential heuristics, including IDs.
These are heuristics, not a reliable secret scanner: users must not store secrets
in memory or assume arbitrary sensitive text is safe to transfer.

## Format version 1

The binary envelope is:

1. Exact bytes `VEYRA-MEMORY\x00\x01` (14 bytes).
2. A fresh random 16-byte salt.
3. A fresh random 12-byte nonce.
4. AES-256-GCM ciphertext followed by its 16-byte authentication tag.

The entire prefix (header, salt and nonce) is authenticated additional data.
PBKDF2-HMAC-SHA256 derives a 32-byte key from the UTF-8 passphrase and salt using
exactly 600,000 iterations. Parameters are fixed, never controlled by the file.
Vetted primitives come from `cryptography`, pinned in the optional requirements.
Plaintext is UTF-8 JSON with exactly `version: 1` and `records`. Each record has
exactly `id`, `project`, `body`, `source`, and `created`. Duplicate JSON keys,
duplicate incoming IDs, unknown fields/versions, invalid types/dates and invalid
memory content are rejected. IDs are nonempty UTF-8 text of at most 128 bytes.
Project/body/source must each be nonempty and at most 64 KiB. A snapshot has at
most 10,000 records and an 8 MiB encrypted file limit, with decoded text also
bounded. Import reads regular files only and rejects symlink inputs.

## Merge and security limitations

Import authenticates and validates the complete snapshot before changing the
existing database. A SQLite savepoint makes the merge atomic, including rollback
on a later insert failure. No existing row is changed or deleted. Matching IDs
with exactly matching full records are duplicates. A matching ID with different
content is preserved under a deterministic derived ID and reported as a conflict.
Repeated imports deduplicate the conflict copy too. Identical text with independent
original IDs remains independent; imported data is never treated as instructions.
Deletion on one device is not propagated to another. Re-importing an old snapshot
can restore a locally deleted memory.

The destination SQLite database remains plaintext, as before. This format protects
only exported snapshot files, not an unlocked device, terminal malware, process
memory, swap, backups or local database access. Python cannot guarantee passphrase
or decrypted-buffer zeroization. Export requests owner-only file permissions on
POSIX; Windows access control depends on the destination folder. File length is
visible. Possession of the passphrase permits creating valid snapshots, so it does
not verify a particular person or device. Do not import untrusted snapshots.

## CLI commands

Install the optional dependency: `python -m pip install -r companion/requirements-sync.txt`.

Export one project: `python -m companion --db ./veyra-memory.sqlite export-memory --project demo --output demo.veyra`. Use `--all-projects` instead of `--project` only when intentionally exporting all memories.

Import: `python -m companion --db ./other-memory.sqlite import-memory --input demo.veyra`. The command prompts privately for a passphrase, merges records, and prints the added/duplicate/conflict report. No passphrase CLI flag is supported.
