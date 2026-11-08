# Optional local model planning

The desktop companion can ask an already installed local Ollama model to propose a bounded task plan. This is a separate planning step, not automatic execution, app control or a connection to the iPhone/Android app. No model server, model weights or software are installed by the companion. Live model inference and device performance have not been verified in the authoring environment.

## Prerequisites and privacy

Use a trusted Ollama installation on the same computer with a downloaded local model. Disable Ollama cloud features (`OLLAMA_NO_CLOUD=1` in the server environment) and run it without upstream proxies or remote-model aliases. The companion rejects model names containing `cloud`, URLs and slash-separated remote model names. It only contacts the fixed IPv4 loopback address `http://127.0.0.1:11434`, does not honor HTTP proxy environment settings, and rejects every non-200 response, including redirects. It never downloads a model or calls an external model API itself.

The local daemon is a trust boundary: the client cannot prove that a locally configured daemon or renamed model does not forward requests. Use a locally operated daemon with outbound network access disabled if that guarantee is important. Do not use a forwarding service on this port. Questions and selected project notes are sent to that daemon; do not include credentials or data you do not want it to see. Notes and model responses are untrusted data, not permission to execute tools.

## CLI

`python -m companion --db ./veyra-memory.sqlite plan --project demo --model YOUR_LOCAL_MODEL --goal "List workspace files" --trust-local-model`

The required `--trust-local-model` flag confirms that you have checked the daemon/model configuration described above. It receives the chosen project’s notes. This prints the full proposal, never executes it. Review it and save only its `plan` field before separately running the executor.

## Review then execute

The `generate_plan(goal, project, model, memory)` Python API returns a JSON-serializable object:

- `status: generated`, `executed: false` explicitly distinguish a proposal from a result.
- `plan` contains the entire strict version-1 executor plan, including every draft's full literal content. Save **only this field** as a plan JSON file if you choose to run it.
- `summary` lists the proposed read paths, proposed draft-write paths, all declared write paths, effective execution budgets and whether write approval is needed.
- `memory_context` reports the selected project, number of included notes and their context bytes.

Review every step, every draft and the exact scope before separately invoking `python -m companion ... run --workspace ... --plan ...`. Add `--allow-writes` only when approving the proposed draft files. A generated plan is never permission by itself. The planner does not inspect workspace files, write drafts, save plans, update memory, create task audit records or start a runner. An outer CLI may initialize its explicitly chosen memory database; that is not task execution.

Unsupported tools and malformed model JSON fail closed. If the model cannot express a request using the five available tools, it is instructed to return no steps. An empty plan does not mean the user's goal was completed. Generated content may be mistaken, incomplete or malicious despite structural validation. Full path existence, containment, symlink checks and write authorization happen in the executor, so a structurally valid proposal can still fail before execution. No automatic repair-and-retry or tool-result feedback loop is implemented.

## Bounds

- Goal: up to 8 KiB UTF-8; project name: 256 bytes; model name: 128 bytes.
- Memory retrieval: only the exact selected project, up to the newest 100 records returned by the existing store. At most 16 notes enter the prompt, with at most 2 KiB of each body, 512 bytes of each source, and 8 KiB total serialized note context. Truncation preserves valid UTF-8. This is recency-based retrieval, not semantic search.
- User/context prompt: at most 24 KiB UTF-8, plus a fixed system instruction. JSON escaping may cause a near-limit request to be rejected rather than silently dropping the goal. Context bytes are not token guarantees.
- Request: capped at 128 KiB by the transport. Model options request 8,192 context tokens and at most 4,096 generated tokens; daemon/model support determines whether these options are usable.
- Response: at most 1 MiB, strict UTF-8 JSON envelope, completed response required. The proposed plan is parsed with the executor's duplicate-key/non-finite rejection and validated against its supported tool/schema and hard budget ceilings.
- Connection timeout: 30 seconds; after connection, a separate 30-second deadline closes the socket even for a stalled header/body. No retries or redirect following. Total worst-case connection plus request time can approach 60 seconds. Closing the connection does not prove server-side inference has stopped.

## Testing

`python -m unittest discover -s companion/tests -v`

Planner tests use an injected fake transport, real SQLite memory and the real plan validator. They cover complete proposals, read/write summary, no execution, project isolation, prompt limits, unsupported tools, invalid/incomplete output, external-endpoint rejection, cloud/remote model-name rejection and transport failures. No Ollama dependency is needed for tests. These tests do not establish live model quality or cross-platform socket behavior; verify those on each target computer.
