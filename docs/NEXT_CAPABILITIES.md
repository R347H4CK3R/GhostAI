# Capability expansion after build 10

This increment preserves the existing test candidate and does not provision credentials, paid services or remote infrastructure.

## Scope
- Private GitHub browsing: explicit app-local token consent, in-memory session by default, optional device-only Keychain storage, sign-out revocation, requests limited to api.github.com. No repository writes.
- Repository tools: model-directed reads confined to the user-selected repository and immutable commit, with finite call/context budgets. The model never receives credentials or chooses the host/account.
- Encrypted transfer: passphrase-authenticated mobile backup and an explicitly notes-only desktop-compatible format. Manual file transfer, not background synchronization.
- Desktop autonomy: opt-in finite plan/execute/observe/replan loop, durable job history, immutable operator tool/write permissions, interruption and uncertain-write handling. No shell or unrestricted remote agent.

## Alternatives and choices
OAuth/app registration would reduce manual credential handling but requires provisioning persistent access; the initial code offers user-configured scoped tokens without creating any. Cloud synchronization needs a chosen recipient/transport and account, so this increment implements encrypted files without transmitting private data. A remote phone-controlled runner requires secure pairing; this increment first makes local desktop jobs durable and bounded.

## Verification boundaries
Unit and UI tests must prove data boundaries, cancellation, wrong passphrases and tampering, immutable authorization and bounded execution. CI verifies the exact published commit. Physical phone inference, signing, speech and background behavior remain separately unverified. Live private GitHub credentials and Ollama must not be fabricated or inferred from source tests.
