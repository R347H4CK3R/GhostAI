# Bounded desktop autonomy

The desktop companion can now run a **foreground, finite plan → execute → observe → replan job** using an already-installed, trusted local Ollama model. This is a narrow file assistant, not a general computer operator or a background service. It does not install a model, start a daemon, pair with a phone, execute shell commands, use a browser, contact GitHub, or run indefinitely.

The earlier `plan` command still proposes a reviewable plan without executing it. The earlier `run` command still executes only an explicitly supplied plan. The new `autonomy` command executes model proposals automatically, within the operator's fixed permissions and budgets.

## Trust and data boundary

- Every new or resumed job requires `--trust-local-model`. This authorizes the selected trusted local model to receive the goal, bounded notes from the selected project, and tool observations from the chosen workspace. Model names containing `cloud`, URLs, and slash-qualified remote names are rejected.
- The HTTP client connects only to `127.0.0.1:11434`, POSTs to `/api/generate`, ignores proxy configuration, rejects redirects, and does not download or pull models. There is no configurable remote endpoint.
- You must independently trust the local daemon/model and configure it for local/offline inference. A loopback URL alone cannot prove a daemon does not relay data elsewhere. This project does not attest to or firewall the daemon.
- Only `list_files`, `read_file`, `validate_json`, `sha256`, and `write_draft` exist. The core runner continues to enforce canonical workspace-relative paths, reject traversal/symlinks/reparse points, reject hardlinked/nonregular file reads, and atomically create drafts without overwriting existing files.
- Project notes, file text, prior model plans, and observations are explicitly untrusted reference content. They cannot add tools, grant permissions, enlarge budgets, or expand the operator's write scope. A model can still misunderstand a task or produce a wrong answer. `completed` means it returned a completion message, **not** that an independent evaluator proved the user's goal was fulfilled.

Use a small, dedicated workspace containing only files you intend to expose. Do not point it at your home directory, credentials, financial/medical documents, or an unreviewed repository containing secrets. The file tools do not classify sensitive content. Keep SQLite memory, job state, and other private application data **outside** the tool workspace.

## Run a read-only job

From the repository root, after preparing a workspace directory, a private state directory, and your trusted local Ollama installation:

```sh
python -m companion --db /absolute/private/memory.sqlite autonomy \
  --workspace /absolute/workspace \
  --state /absolute/private/inspect-job.json \
  --project demo --model qwen2.5-coder:7b \
  --goal "Read input.json, validate its JSON, and summarize the contents." \
  --trust-local-model
```

The state file must not exist for a new job, its parent must already exist, and it must be outside the workspace. Symlinked ancestors are rejected just like core workspace paths. On Windows use your actual absolute paths, quote paths containing spaces, and put the command on one line in PowerShell. `python` may be named `python3` on your computer.

The command prints the final JSON checkpoint. Exit code 0 means `completed`; other terminal outcomes return 1. Syntax errors return 2. A missing daemon, invalid response, or unavailable model fails visibly; the command does not substitute fake results or switch to a hosted model.

## Explicit draft preauthorization

Read-only is the default. To authorize model-written literal text at a specific new direct-child path, add one `--write-path` per allowed filename:

```sh
python -m companion --db /absolute/private/memory.sqlite autonomy \
  --workspace /absolute/workspace \
  --state /absolute/private/draft-job.json \
  --project demo --model qwen2.5-coder:7b \
  --goal "Read input.txt and create a concise summary in summary.txt." \
  --write-path summary.txt --trust-local-model
```

This grants permission to create `summary.txt` with model-selected content. It does not approve any other filename, a nested directory, overwrite, deletion, command execution, or sharing. Review the draft before using it. To review exact text *before* any write, use the existing separate `plan`/`run` workflow instead.

The full proposed plan is preflighted before any of its tools execute. Its declared `write_paths` must be a subset of the operator list, and each write must appear in both lists. Replanning never changes authorization. An existing target is refused; writes are never blindly replayed or overwritten.

## Finite budgets

All limits are positive integers and are fixed for the life of a job, including resume:

| CLI flag | Default | Maximum |
| --- | ---: | ---: |
| `--max-iterations` | 8 | 32 |
| `--max-tool-calls` | 32 | 100 |
| `--max-seconds` | 120 | 600 |
| `--max-io-bytes` | 1,048,576 | 8,388,608 |
| `--max-output-bytes` | 262,144 | 2,097,152 |

- An iteration is a model request, including the final completion/refusal request. A model request is charged before it starts. A plan larger than the remaining tool allowance is rejected before any of its effects.
- Tool attempts, successful or failed, count toward the job-wide tool limit. Tool I/O bytes are shared across iterations. Plan-specific byte/time/entry limits also apply and cannot enlarge job limits. The core may inspect one extra read byte or directory filename to discover that a limit was exceeded; the probe is discarded and the allowance is marked exhausted. Oversized draft content is rejected before file creation.
- Output accounting covers raw model response bytes plus serialized tool observations. Oversized content is not retained in the checkpoint or sent into another model turn. A small effect/status marker is retained if a tool completed before its result exceeded the output budget. Individual model responses have an additional 1 MiB transport cap; an over-budget response may be received up to that cap before being rejected. Checkpoint JSON metadata is separate from the output allowance and has a 16 MiB hard cap.
- Prompts are capped at 48 KiB; project notes at 6 KiB; recent history context at 24 KiB. Large or old history is explicitly omitted/truncated in model context, while bounded full plans/results remain in the state file. These are byte limits, not tokenizer guarantees. Model context failures remain possible.
- The job deadline is persisted, so downtime does not normally grant more time. Monotonic checks protect the current process against wall-clock changes. The system clock and local filesystem are trusted. Deadline checks occur before model/tool actions and inside core checkpoints, including before draft creation. A model request uses the lesser of 30 seconds and remaining job time; socket deadlines also interrupt slow response headers/bodies.
- Cancellation and filesystem deadlines are cooperative at core checkpoints. A stuck operating-system filesystem call, disk flush, or SQLite operation is not forcibly killed. Use a responsive, local filesystem, not an untrusted or stalled network mount. This is not a hard real-time sandbox.

## Cancellation, state, and recovery

Press **Ctrl+C** to cancel the foreground job. Library callers may supply a `threading.Event` as `cancel`. Cancellation is checked between steps and within core I/O loops. During an established model request, a small watcher closes the socket when the event is set. The initial loopback connection attempt remains bounded by its socket timeout. Closing a client connection does not guarantee immediate model-server compute cancellation.

Inspect status without model access or tool execution:

```sh
python -m companion --db /absolute/private/memory.sqlite job-status \
  --state /absolute/private/inspect-job.json
```

`--db` remains required by the shared CLI syntax, but `job-status` does not open or create the database.

The JSON contains immutable configuration, counters, deadline, proposed plans, ordered observations, a pending-operation checkpoint, final summary/error, and status. Every core tool attempt also uses the existing SQLite task audit. The overall job/history lives in JSON, not in the SQLite `history` command. Neither the checkpoint nor SQLite is encrypted. Files are created with restrictive POSIX permissions; Windows access also depends on the state directory's ACL. Keep that directory private and out of source control/backups you do not trust.

Checkpoint writes use a flushed temporary file and atomic replacement; POSIX also fsyncs the parent directory. Windows uses file flush plus atomic replacement because portable directory fsync is unavailable. An OS-held lock prevents cooperating processes from running the same checkpoint concurrently and releases after process death. The small `.lock` file can remain on disk; its existence alone does not mean the job is running. Do not delete a lock file while a job may be active.

To resume an interrupted process, repeat the **same command and all settings**, adding `--resume`. Goal, workspace, project, model, write paths, and all limits must match. Resume does not reset budgets or extend the original deadline.

- Completed, refused, exhausted, cancelled, failed, and awaiting-approval jobs are terminal. Resume only returns their saved state; it does not execute again.
- An interrupted read's plan is discarded. Its unconfirmed I/O reservation is conservatively charged, and a later model turn sees an interrupted observation. If there is budget and time remaining, it can replan. This may leave no I/O budget for another read.
- An interrupted model request is charged its reserved output allowance. With default settings that normally exhausts the output budget. No uncertain response is invented or replayed.
- A pre-tool intent is saved **before** executing any tool. If a write may have happened but its success was not durably recorded, recovery stops as `awaiting_approval`. A failed or cancelled write is also conservatively treated as uncertain. It will not rerun the write.
- `awaiting_approval` is a stop state, not an interactive approval service. Inspect the actual draft and saved intent yourself. There is no automatic “approve and retry” command. Start a new **read-only** job with a new state filename to inspect the situation, then separately authorize any further work. Do not edit counters or remove checkpoints to force replay.
- An inability to persist status is surfaced as a failure. The last durable checkpoint remains the recovery authority. Checkpoint corruption fails closed; this is not a transactional filesystem/database recovery system.

These safeguards assume the operator owns the private checkpoint directory and that another hostile process is not modifying workspace ancestors/checkpoints concurrently. The job file is not cryptographically authenticated. It is local execution state, not a portable or untrusted job-import format.

## Model response contract

Each completed Ollama envelope must contain one strict JSON object in its `response` string:

```json
{"action":"plan","plan":{"version":1,"steps":[{"tool":"read_file","path":"input.txt"}],"write_paths":[],"budgets":{}}}
```

or:

```json
{"action":"complete","summary":"A summary supported by the observations."}
```

or:

```json
{"action":"refuse","reason":"This task needs an unavailable browser or shell tool."}
```

Unknown actions/fields/tools, duplicate JSON keys, non-finite numbers, malformed responses, and empty plans are rejected. Failed safe reads become observations for the next iteration; permission/path violations stop instead of prompting the model to work around them.

## Verification and remaining scope

Run the repository's complete Python suite:

```sh
python -m unittest discover -s companion/tests -v
```

Tests use fake model response bytes but real SQLite memory, real core filesystem tools, real atomic draft creation, real temporary checkpoints, and real OS locking. They cover multi-iteration observations, refusals, no-write default, exact-scope escalation attempts, budget exhaustion, cancellation, transport deadlines, checkpoint corruption, completed-job idempotency, and simulated process loss/audit failure immediately after a real write. Live Ollama answer quality, local model installation, and Windows/macOS runtime behavior are not established by the authoring Linux tests. Cross-platform Python CI is configured separately.

Not implemented: background schedules/daemon, arbitrary app control, browser/shell/network tools beyond the fixed local model call, remote workers, mobile job submission, credentials, model installation, independent goal verification, semantic permission inference, overwrite/patch workflows, or automatic uncertain-write recovery.

## Optional paired foreground host

The separate [paired desktop preview](PAIRED_EXECUTION.md) exposes only reviewed, authenticated, bounded read-only jobs through HTTPS. It shares no existing notes implicitly and does not change the standalone local executor permissions. Windows activation and native iPhone verification remain gated.
