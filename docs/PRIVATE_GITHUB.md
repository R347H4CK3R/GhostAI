# Read-only private GitHub on iPhone

This is app code for a user-controlled GitHub connection, not an inherited ChatGPT/dot connection. No real credential was created, entered, configured or tested during implementation. Native simulator and direct-device validation are still required.

## Connect safely

1. Use a directly installed, correctly signed app on a trusted iPhone. **Do not enter a token in Strata, LiveContainer or another hosted app.** The host can inspect guest data and credentials. No reliable runtime detector exists here, so the app displays a prominent warning and requires a direct-install acknowledgment. That acknowledgment is not a technical security boundary.
2. In GitHub, create your own **fine-grained** personal access token with a short expiry. Select only the repositories you intend to browse. Grant **Contents: Read-only**; GitHub also includes repository metadata access. Organization approval/policies may limit availability. Do not grant write permissions. The app cannot introspect or reduce the token's full rights.
3. In Projects, enter the token in the secure field. Leave **Remember in this device’s Keychain** off for memory-only use. Confirm the destination, read-only purpose and storage choice in the app before any authenticated request.
4. The app verifies `/user`, displays the verified account login, then lets you load `/user/repos`. Only repositories accessible to that token appear. Selecting a repository pins its current default branch to an immutable commit SHA.
5. Use **Sign out and remove saved token** to revoke all app client references and delete the optional Keychain entry. GitHub server-side revocation is a separate action in GitHub settings.

Never paste a token into Assistant, a note, a source file, an issue, a diagnostic report or an exported backup. The app does not create or manage GitHub tokens and never requests a password.

## Credential lifecycle

- The default token is held only in session-only app memory. Secure-field content is cleared after submitting, cancelling, leaving the screen or backgrounding.
- A session expires after eight hours, app process exit or explicit sign-out. It survives ordinary backgrounding so switching apps does not require reconnecting; a pending connection is cancelled on backgrounding. Ending the session cancels its active network transports and removes in-memory token references. Managed Swift strings and OS networking buffers cannot guarantee cryptographic zeroization.
- Each client permanently belongs to its original public mode or authenticated session. Revoked/expired sessions fail closed; they never retry anonymously or adopt a newer account.
- Optional persistence happens only after the user explicitly opts in and account verification succeeds. The Keychain item uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and `kSecAttrSynchronizable = false`, no shared access group, and no UserDefaults/file copy. It is not exported in app JSON backups or migrated/synchronized to another device. Apple controls device/OS-level Keychain behavior; a compromised host/device is outside this protection.
- Saved tokens are **never loaded automatically**, including launch or foreground. **Use saved token on this device** requires a fresh confirmation and account verification.
- Expiry ends the session but deliberately retains a token the user explicitly saved. Sign-out attempts Keychain deletion even when no session is active. A deletion failure is reported, while all in-memory sessions remain revoked. Retry removal or revoke the token at GitHub. Do not rely on uninstall to remove Keychain entries.
- Credential/session objects are not Codable and are never passed into model prompts, memory, chat, diagnostics or backup export. Session descriptions/debug reflection are redacted. The network stack necessarily receives the Authorization header.

## Network boundary

Every request is an explicit GET to the fixed `https://api.github.com` host. Host, HTTPS scheme, port, embedded username/password and fragment checks run **before** an Authorization header is constructed. There is no configurable API base, user-supplied token query parameter or use of server-provided download URLs. All redirects are rejected, including same-host redirects. Non-server-trust authentication challenges are cancelled and normal TLS validation is preserved.

Networking uses an ephemeral URLSession with no URL cache, cookie jar, credential store or added protocol classes. HTTP/SOCKS/PAC proxy settings are explicitly disabled. This does not promise protection against a malicious app host, trusted TLS-interception certificate, system VPN, compromised OS or developer instrumentation. Do not enter credentials on an untrusted device or hosted runtime.

Responses have request/resource timeouts, an early Content-Length check and an enforced streamed byte cap (normally 2 MB; profile 64 KB, commit 512 KB, text 120 KB). Cancellation is checked during streaming and session validity is checked before results are returned. Response bodies, transport errors and decoding details are not surfaced in error text. The app gives sanitized status messages only. No write endpoint, OAuth grant or automatic token creation is implemented.

## Project and source scope

Public browsing remains anonymous and uses the existing `owner/repo` workspace. Authenticated workspaces use `GitHub account <stable numeric account ID>: owner/repo`, separating accounts and public-mode context even if a login is renamed. Connecting, changing account, sign-out or session expiry resets repository navigation and switches the assistant to General, cancelling generation and clearing attached source. Late results are ignored.

Explicitly saved notes, source excerpts and conversations **remain local after sign-out**. They are still visible in offline workspaces and can appear in user-exported backups. Remove them separately if required. Private source is never automatically saved merely by browsing. Selecting **Attach** or **Save excerpt** is an explicit choice; source suspected of containing a credential is blocked, but detection is only a heuristic.

The browser rejects entries explicitly marked as symlinks/submodules. GitHub's Contents API can dereference some symlinks before returning them, so the browser alone cannot prove the absence of symlink dereferencing. Model-callable tools use the separate nonrecursive Git trees and immutable blobs endpoints: tree modes distinguish regular files, directories, symlinks and submodules. Tools can thus reject symlinks/submodules before fetching blob content. Tree truncation, malformed SHAs and blob size/hash-field mismatches are rejected.

## Integration contract

`RepositoriesView(onRepositorySelected:)` calls `(Repository, pinnedSHA, GitHubClient, workspaceName)` only on explicit project/source selection. The callback runs **before** assigning source attachment fields. The parent stores this context ephemerally, not in saved memory. Old clients remain tied to their revocable original session. No token getter is supplied to the model. The app owns one `GitHubCredentialStore` and injects it into the view hierarchy. Its synchronous, payload-free `onSessionEnded` callback cancels assistant generation and clears context after credential revocation, even when Projects is offscreen; cancellation must not depend on a SwiftUI view observer.

Model tool transport adapters use:
- `toolTree(repo:sha:maximumResponseBytes:) -> (files, responseBytes)` for one immutable tree/commit.
- `toolText(repo:file:maximumResponseBytes:) -> (text, responseBytes)` for an already verified regular blob.

Both return measured HTTP body byte counts and enforce caller-provided byte caps. An error consumes the caller's reserved cap conservatively. The model-facing layer is responsible for fixing the repository/commit, resolving paths through these trees and enforcing shared question budgets. It must never expose these unrestricted transport methods directly to model-generated repository names or SHAs.

## Verification

`Tests/GitHubAuthTests.swift` uses an unmistakably synthetic token and a fake Keychain boundary, with no network requests. It covers destination checks, GET/header construction, anonymous separation, expired/revoked sessions, redacted descriptions, rejected token forms, route separation, URLSession privacy settings, redirect rejection, memory-only default, explicit saved-token lifecycle, cancelled connection races, deletion failure, account-scoped workspaces and direct lifecycle callbacks on sign-out, pending cancellation and expiry without a view observer.

Native tests were authored before implementation, but this Linux authoring environment has neither Swift nor Xcode. The attempted `xcodebuild ... test` exited 127 (`xcodebuild: command not found`), so no native red/green or UI-pass claim is made. Run the existing iOS CI scheme with Xcode 26, then test on a directly installed phone:

- Public browsing without any credential and with a saved-but-inactive token.
- Synthetic/invalid/expired/revoked token errors; no credential or response body in UI/logs/exports.
- A manually supplied, minimum-permission token: `/user`, paginated repositories, commit pinning, directory and text reads.
- Cancel connection, repeated connect, sign-out during a read, background during verification/read, expiry, changing accounts and returning from a source sheet. Old results must not reappear.
- Memory-only relaunch, optional Keychain relaunch with explicit reuse, locked-device access, sign-out deletion and failed deletion reporting.
- Same-host and cross-host redirects, oversized/chunked responses, hostile TLS/proxy setups and interrupted reads using controlled fixtures.
- Saved offline data intentionally persists after sign-out while active attachments and tool sessions are cleared.

Do not test real private access in Strata. Passing simulator tests does not establish safe container isolation, actual Keychain protection, physical-device TLS behavior or GitHub organization policy compatibility.
