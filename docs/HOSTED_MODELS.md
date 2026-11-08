# Optional hosted text

## Scope and integration

`HostedAssistantView()` is a standalone SwiftUI screen with its own `NavigationStack`. Add it as a tab or sheet; it takes no `AssistantStore`, repository, memory, credential or voice dependencies. The local Assistant and voice paths remain unchanged. Android and desktop do not gain a hosted model through this screen.

This is a personal, bring-your-own-existing-key text client for the fixed official `https://api.openai.com/v1/responses` endpoint. No service account, API key, paid account, subscription or backend is provisioned. No live provider request was made during development. It is not ChatGPT login or access to the user's dot account.

## User flow

1. Use a directly installed app. A required acknowledgment unlocks the `SecureField`. Do not use real keys in Strata or another app host: a host can read its guest's credentials and content, and the app cannot reliably detect such hosting.
2. Enter an existing OpenAI API key and choose **Use key for this session**. This only stores a revocable in-memory session, not a network-verified connection. There is no Keychain or other persistent storage.
3. Enter a Responses-compatible model ID available to the user's API account. The model field intentionally starts blank. The client does not query model lists, invent access, silently substitute models, or guarantee that a model supports every request parameter.
4. Type a question and optionally paste context. No memory, saved chat, attached file, repository tool output, voice recording or previous answer is automatically included. Review for secrets and information that should not go to OpenAI. Heuristic rejection is deliberately conservative and incomplete.
5. Choose **Review exact request**. The review sheet displays the exact immutable question, context, model, destination and JSON body, excluding the key. It also discloses transmission of the key in the Authorization header, credential exposure risks, provider retention and metered API charges. The user must enable a fresh approval toggle and press **Send this request to OpenAI** for each call.
6. View the completed answer as inert text. There is no command execution, tool access, link opening, code application, memory write or continuation request. Explicit answer-only text export uses the user's chosen file provider, which can upload files. A local destination avoids that extra transmission.

API usage is metered under the API account. Do not assume a ChatGPT subscription covers it. The client cannot quote an exact charge or enforce a currency spending limit. Cancelling or timing out locally may not prevent provider-side processing or charges. The user should review their provider account pricing and limits before sending.

## Privacy and request integrity

- Keys remain in memory for at most a 30-minute session. Leaving this screen, backgrounding the app, session expiry, or **End session and clear screen** cancels pending work and revokes local access. Pending previews and late answers are invalidated. Provider-side key revocation remains a separate action in the user's account.
- Starting another session never adopts an old preview. A preview is bound to the session and is single use. Edits to key, question, context or model invalidate it. A rejected or cancelled request requires a new review. There is no automatic retry, provider fallback or model fallback.
- Only the fixed HTTPS endpoint is accepted, including for the final HTTP response. Redirects are refused, even to the same host. The ephemeral transport disables cookie/credential stores, disk cache, custom protocol handlers and inherited HTTP/SOCKS/PAC proxies. System TLS trust remains in force. These controls do not protect a compromised OS, hostile app host or compromised trusted certificate authority.
- Raw provider errors, response bodies, URL requests and transport descriptions are never logged or surfaced. Errors are generic. Keys are omitted from session description/reflection; exact key echoes and common credential patterns are redacted from completed answers before display/export. Swift and URLSession cannot guarantee zeroization of prior string/header copies.
- The request sets `store: false`, `stream: true`, `tools: []` and `tool_choice: "none"`. There is no `previous_response_id`, conversation identifier, hidden memory or hidden system prompt. `store: false` is not a zero-retention promise: provider data controls, safety processing and applicable account terms remain relevant.
- The app stores no hosted question/answer history or credentials in its memory, JSON backups, diagnostics or Keychain. Explicitly exported files are outside that guarantee. The OS keyboard, screenshots, device software and selected file providers have their own behavior.

## Bounds and compatibility

Question: 8,000 UTF-8 bytes. Optional context: 24,000 UTF-8 bytes. Model ID: 1–128 ASCII letters, digits, periods, underscores or hyphens. Inputs are rejected, not silently truncated. Credential-like strings in all three fields are rejected.

Output request limit: 2,048 tokens, including reasoning tokens under the Responses API contract. This is not a dollar cap or a guarantee that a reasoning-heavy model can finish within it. Incomplete responses are rejected rather than presented as successful answers.

The network response is incrementally read, with a 524,288-byte cumulative budget before decoding. SSE lines are limited to 65,536 bytes, event data to 131,072 bytes and accepted/redacted output to 32,768 bytes. Request inactivity timeout is 25 seconds; resource timeout is 60 seconds. Cancellation invalidates the active URLSession, and session/cancellation checks also gate the completed answer.

The decoder accepts documented text/refusal deltas and final message text from a `response.completed` event. It requires completed status and rejects malformed, oversized, failed, incomplete or truncated results. Other events, including model tool calls, are ignored without executing anything. Text is buffered until completion and redaction, rather than showing unsafe partial fragments. Unknown models, incompatible APIs, excess reasoning, future protocol changes or insufficient account permissions can result in a generic failure.

## Verification

The initial XCTest suite in `Tests/HostedAssistantTests.swift` was authored before implementation; additional edge-case tests were added during review. They cover endpoint isolation, injection/credential rejection, exact payload construction, immutable single-use consent, revocation and expiry, redaction, redirects, response status/type/length, split UTF-8 SSE parsing, ignored executable events, incomplete responses, byte budgets, cancellation, late replies, timeout errors and controller cleanup. Network behavior is injected with synthetic fixtures only; no real key is used.

The authoring Linux environment has no Swift or Xcode. The attempted native test command returned `xcodebuild: command not found`; no native red/green result, Swift type-check, simulator visual review or device/provider behavior is claimed. The existing 66 Python companion tests pass locally. Native compilation and XCTest must run in the repository's Xcode CI before packaging is considered verified. Physical-device UI interruption checks and an explicitly authorized paid provider smoke test remain separate follow-up verification.

## Official API references checked during development

- [Responses create schema](https://developers.openai.com/api/reference/resources/responses/methods/create). The full page exceeded the documentation fetcher's size limit; endpoint/request-field references were also cross-checked against the published streaming schema. No model access conclusion is drawn from examples.
- [Responses streaming events](https://developers.openai.com/api/reference/resources/responses/streaming-events), opened November 8, 2026: text/refusal deltas, completed status and message output fields.
- [API data controls](https://developers.openai.com/api/docs/guides/your-data), opened November 8, 2026: storage flags do not replace provider retention policies.
