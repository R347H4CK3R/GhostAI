# Live GitHub access and offline fallback

The Assistant reasons with Apple's on-device model both online and offline. This uses no hosted-model API key and creates no hosted AI charge. The optional Hosted tab and its exact-request approval flow are unchanged.

## Connection and source indicators

- **GitHub not selected:** General or a saved workspace has no live repository selected. Open Projects, load public repositories or explicitly connect your account, then choose **Use this project in Assistant**. This is a setup/scope limitation, not “no service”. The app does not inherit dot/ChatGPT's GitHub connections or have automatic access to every repository.
- **Live GitHub ready / Checking GitHub:** The selected repository's existing, pinned, read-only tool will be used. A satisfied Wi-Fi/cellular path does not prove endpoint reachability.
- **GitHub online:** A live scoped read succeeded for this question. The app includes an initial root excerpt of at most 600 characters, charged to the existing 4,000-character shared tool-output budget. Later reads retain the existing request, byte, path and credential restrictions.
- **Offline fallback:** No network path is available, or the attempted GitHub connection failed, including connection loss, DNS/connect failure or timeout. The local model uses available saved context. No live request is automatically retried. A new question tries live access again when a path is available or unknown.
- **GitHub unavailable:** GitHub returned a server error. Saved-context fallback is available, but the app does not call this phone “no service”.
- **Reconnect / Access denied / Rate limited / Read failed:** These are distinct from offline fallback. Initial failure stops the question rather than pretending to have read the repository. Failure during a later model-directed read is reported to the model; it must describe that restriction.

An interruption after earlier live reads may leave partial live evidence in the model's current context. Its answer is labeled accordingly, rather than claiming only saved notes were used. Live reads are disabled for the rest of that question after connection/service failure, even if concurrent requests complete later.

The persistent header separates connection state from the on-device engine. Newly generated answers have source labels in the current app session. Older/imported/relaunched answers say their source was not recorded. Deleting chat also removes its ephemeral source labels. The chat, backup and encrypted-transfer formats remain unchanged.

## Lifecycle and limits

Typed and transcribed voice messages share the same request pipeline. Stop, workspace change and session revocation invalidate stale completions. Authorization is checked before returning cached repository data, even after an earlier connection failure; revocation is reported as authentication required and never grants private offline access. Leaving the foreground stops pending requests unless the user enabled an active background voice conversation. Draft recovery remains available after cancellation or error.

This change does not add account-wide repository scanning, writing, deployment, arbitrary tools, cloud uploads, paid model routing, credentials or broader permissions. A selected repository remains pinned to one commit; a successful read does not mean that commit is the latest remote revision. Apple model/device availability and its context limits still apply.

## Verification

Tests cover network hints versus endpoint success, missing setup, sanitized transport errors, 401/403/404/429/5xx distinctions, TLS errors, cancellation, large-root preflight budgets, concurrent fallback latching, next-question recovery, store publication and unchanged backup keys. A UI test checks the General header and response-origin label.

Native compilation, XCTest and simulator UI checks must pass in Xcode CI before this source is delivered as a verified build. A real iPhone check remains necessary for airplane mode, cellular recovery, background voice and Apple model behavior. No live paid model call was made during development.
