# Pinned read-only repository tools

The iPhone can give Apple's on-device model two tools while answering a question in a selected GitHub project:

- `list_selected_repository_directory`: direct children of a relative directory; an empty path lists the root.
- `read_selected_repository_text`: an excerpt from one regular text file.

The tools do not start until the user asks a question. Selecting a project may separately fetch its commit and browse its files through the UI. There is no autonomous background crawl, shell, file write, repository modification, arbitrary URL fetch, or remote model call.

## Scope and credentials

The application captures one repository, a full immutable 40-character commit, and the selected GitHub client before generation. The only model argument is `path`. The model cannot choose a repository, account, host, branch, commit or credential.

Paths are resolved from the pinned Git tree through previously observed child tree IDs. File content is fetched by its observed blob ID. Git modes distinguish regular files from symlinks and submodules; these tools do not use GitHub's symlink-dereferencing Contents API. Every file's declared byte size must match its returned blob. Output includes repository, path and pinned commit; file excerpts also include the blob ID. A cached tree applies only to this one response and cannot silently drift with a moving branch.

Authentication stays inside the captured client. It is never added to tool arguments or output. The client rejects redirects and destinations outside GitHub's API. A revoked connection cannot serve even cached tool metadata. Changing project, signing out, or cancelling should cancel the current question and its tools. No automatic anonymous fallback or credential refresh is attempted.

Repository content is untrusted reference data. Instructions inside it must not override the user's question or application rules. Input validation rejects traversal, URL syntax, percent encoding, backslashes, controls and bidirectional override characters. Links, submodules and common credential-file names are excluded. Binary control characters and text matching the existing possible-credential heuristic are withheld before any excerpt is returned. This heuristic cannot identify every secret; do not select sensitive repositories indiscriminately or rely on it as a secret scanner.

## Per-question bounds

Both tools share one actor, created fresh for each user-started question:

| Resource | Bound |
| --- | --- |
| Admitted tool calls, including invalid paths | 8 |
| Network requests, including ancestor-tree resolution | 12 |
| Application-consumed HTTP response-body bytes | 120,000 total |
| One directory response body | 30,000 bytes |
| One blob response body | 90,000 bytes |
| Decoded file | 60,000 bytes, known nonnegative size |
| Successful source/metadata output | 4,000 characters total (6,000 hard maximum for an explicitly configured scope) |
| Directory summary | 60 direct children |
| Relative path | 512 UTF-8 bytes and 16 components |

The total response-body budget reserves each request's full cap before suspension, then refunds unused bytes on successful reads. Parallel calls cannot reserve the same bytes. Failed requests conservatively retain their full reservation because the exact consumed size may be unknown. There are no automatic retries. Caches avoid repeated directory requests, but each requested file read still counts against the budgets.

These byte counts do not include HTTP/TLS headers or buffers prefetched by URLSession. Directory response limits may prevent reading unusually large directories; the app reports failure rather than claiming a complete listing. A truncated GitHub tree is rejected. Summaries and text that reach output bounds are explicitly marked as omitted/truncated. Fixed diagnostic errors are additional to the successful-output character budget. Further tool calls are refused before network I/O once a hard limit is reached.

Character bounds are not token guarantees. Tool schemas, instructions, saved notes, attached source, question and conversation history also consume model context. Keep those other inputs small when tools are active; a model context error is still possible and must be surfaced honestly. These are per-question limits, not daily usage limits.

## Application integration

Create one scope inside the question operation, never a new scope on every tool call:

```swift
let repositoryTools = try RepositoryQuestionTools(
    repository: selectedRepository.full_name,
    commit: pinnedCommit,
    client: selectedClient
)
var tools: [any Tool] = [ProjectMemoryTool(notes: notes, project: project)]
tools.append(ListRepositoryDirectoryTool(repository: repositoryTools))
tools.append(ReadRepositoryTextTool(repository: repositoryTools))
let session = LanguageModelSession(tools: tools, instructions: instructions)
```

Retain that actor for the question. Call `await repositoryTools.cancel()` when cancelling the question, changing its project/account, and after completion. It cancels in-flight child tasks and clears cached trees. Individual tool-call task cancellation is forwarded to the network task, and all request results are checked again before output. The outer store must also discard results belonging to an obsolete question generation.

The injected `RepositoryToolReader` enables network-free tests. Its production adapter binds repository and client. A custom adapter is a trusted transport boundary: it must enforce the supplied response-byte cap while streaming, report exact consumed bytes, classify modes correctly and honor cancellation. No adapter supplied by the model is accepted.

## Verification

`Tests/RepositoryToolTests.swift` exercises scope validation, path rejection, pinned ancestor traversal, cache behavior, symlink/submodule refusal, malformed metadata, size mismatches, binary/credential withholding, shared call/request/byte/output budgets, concurrent reservations, error sanitization, revoked access and cancellation using deterministic reader stubs.

Run the project's `AsterionVeyra` XCTest scheme on an iOS 26 simulator using Xcode 26. The authoring Linux environment lacks Swift/Xcode, so test source was written before implementation but cannot establish an executed red/green cycle. Native type checking, FoundationModels integration and physical-device model behavior require the existing native CI/device workflows. No live private-repository credential is needed for these tests.
