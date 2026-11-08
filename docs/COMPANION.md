# Offline desktop companion

The companion runs on Windows, macOS and Linux with Python 3.9 or newer, using only the standard library. No package install, API key, account, network or model download is needed. Run commands from the repository root; on Windows use `py -3` instead of `python` if needed.

This is a **deterministic executor of explicit JSON plans**, not an LLM or unrestricted autonomous agent. It cannot interpret natural-language requests, operate apps, execute shell commands, access phones, synchronize devices or contact anyone. The native Apple app and this CLI currently have separate memory stores. Python portability is intended; automated execution here was verified on Linux, not on Windows/macOS hardware.

## Local memory

Choose a database outside the task workspace. Its parent directory must already exist.

```sh
python -m companion --db ./veyra-memory.sqlite remember --project demo --source "user:2026-11-08" --text "Use a local-first design."
python -m companion --db ./veyra-memory.sqlite search --project demo --query local
python -m companion --db ./veyra-memory.sqlite forget MEMORY_ID
python -m companion --db ./veyra-memory.sqlite history
```

Entries retain project, source/provenance, creation time and ID. Search is literal substring matching, scoped to a project, returning at most 100 entries. SQLite's built-in case folding is primarily ASCII. Memory persists between executions and works offline. Nothing is automatically imported from personal files or conversations. Keep credentials and sensitive information out of memories. A heuristic rejects recognizable GitHub token prefixes, PEM private-key headers and password/API-key/access-token/secret assignments in all memory fields. It is not comprehensive secret detection or encryption. The SQLite file is plaintext, protected only by your OS account permissions and any disk encryption. Delete removes the entry from this database using SQLite secure-delete, but cannot erase external backups or filesystem snapshots. Back up the database while the CLI is closed. Copying it between computers is manual; there is no concurrent multi-device sync or merge.

## Execute a plan

Create a dedicated workspace directory first. Use explicit paths suitable for your OS:

```sh
python -m companion --db ./veyra-memory.sqlite run --workspace ./my-workspace --plan companion/examples/inspect.json
python -m companion --db ./veyra-memory.sqlite run --workspace ./my-workspace --plan companion/examples/draft.json --allow-writes
```

The entire plan schema is validated before any task tool runs. Unknown fields, tools, versions, duplicate JSON keys, non-finite numbers and malformed arguments are rejected. All four top-level fields are required:

```json
{
  "version": 1,
  "write_paths": ["draft.txt"],
  "budgets": {"max_steps": 4, "max_bytes": 65536, "max_entries": 100, "max_seconds": 10},
  "steps": [
    {"tool": "list_files", "path": "."},
    {"tool": "read_file", "path": "input.txt"},
    {"tool": "write_draft", "path": "draft.txt", "content": "Explicit draft text"}
  ]
}
```

Registered tools:

- `list_files`: immediate names only, no recursive traversal.
- `read_file`: bounded UTF-8 text.
- `validate_json`: checks a UTF-8 file for strict JSON syntax; returns `valid: true`, or fails. No external schema fetch.
- `sha256`: SHA-256 digest of bounded file content.
- `write_draft`: creates a new direct child of the workspace with literal content. Requires both `--allow-writes` and the exact path in `write_paths`. Never overwrites an existing file or creates directories. No template execution or substitution.

Limits default to 32 steps, 1 MiB cumulative input/output content and listed-name bytes, 1,000 entries per listing, and 30 seconds. Hard ceilings are 100 steps, 8 MiB, 10,000 entries and 120 seconds. Plan files themselves cannot exceed 1 MiB. JSON validation also limits its input to 1 MiB. Limits must be positive integers. Byte budgets are payload budgets, not an exact cap on process RAM or JSON output framing. The deadline is cooperative, checked between operations and directory entries; blocking OS calls cannot be forcibly interrupted by it. Use only local disks, not network mounts.

Ctrl+C cancels a running plan at the current Python interruption point. The Python API also accepts a `threading.Event` cancellation signal. Execution stops on the first failure. Prior completed drafts are retained: a plan is not a transaction. Results and task IDs print as JSON; failure/cancellation returns exit code 1. An audit row records status and completed-step count, without storing file contents. A killed process may leave a `running` audit row or `.veyra-` temporary file; inspect it manually before cleanup. Schema/tool failures are audited; CLI errors before a runner starts (such as unreadable or malformed plan files) are reported to stderr but are not task audit rows.

## Safety boundary

Paths must be relative and canonical; `..`, absolute paths, backslashes, drive/stream syntax, symlinks and Windows reparse points are rejected. Reads reject special files and multiply linked files. Writes use a flushed temporary file followed by an atomic hard-link create-if-absent, preventing partially published drafts and overwrites. Filesystems without hard-link support fail closed. Draft writes are limited to direct workspace children.

Use a dedicated local directory containing only files you intend the plan to read. Do not point at a home directory, credential store, shared folder, or directory writable by an untrusted process. This is application-level path validation, **not an OS security sandbox**. Cross-platform path checks cannot guarantee containment against a separate process racing to rename directories or replace ancestors during execution. Protect the workspace from concurrent mutation and run with ordinary, non-administrator privileges. There is no network tool, arbitrary shell, dynamic plugin loading, credential access tool, background scheduling or implicit approval mechanism.

## Tests

```sh
python -m unittest discover -s companion/tests -v
```

The tests cover offline memory persistence/search/provenance/deletion, CLI operation, registered tools, scope and flag requirements, no overwrite, traversal/symlink rejection, byte and step limits, cancellation, audit outcomes and fail-closed validation.
