# Pinned file evidence search

## Intent and approach

Help the on-device assistant investigate relevant implementation beyond the beginning of a file. The existing prefix read can omit useful code under the shared 4,000-character output budget even when the complete file fits the 60,000-byte read limit.

The selected approach is literal search within one explicitly selected repository's pinned file. This reuses the existing question actor, verified Git-tree traversal and read credential. Repository-wide recursive search would consume unbounded discovery and retrieval; GitHub code search would introduce moving-branch semantics. A proposal diff is useful separately but does not solve evidence retrieval. The implementation choice is additive Swift/FoundationModels functionality, without a new service or dependency.

## Contract

- The model supplies only `path` and `query`. It cannot choose repository, commit, host, credential, budgets or another account.
- Query is a nonblank, case-sensitive literal, at most 128 UTF-8 bytes. Reject all Unicode newlines/control/illegal/bidirectional controls and possible credentials before I/O. No regex, case folding or Unicode normalization. Query is processed locally and is not sent to GitHub or echoed in errors.
- Read the entire regular file through the same verified reader as prefix reads. Preserve the 60,000-byte file limit and full-file binary/possible-credential screening before selecting any excerpt. No weaker parallel reader or persistent source cache.
- Inspect LF-separated lines; remove the CR in CRLF for presentation. Render standalone CR, U+2028 and U+2029 as visible escape sequences so source cannot create unnumbered visual lines. A trailing LF has an empty final line. Match within a line, not across lines.
- Count all matching lines. Select the first three matching lines in file order, include one preceding/following line, and merge overlapping windows without duplicate lines. Describe extra matches as not selected as anchors, not necessarily omitted: a context line can contain another match. Center matching context lines around their own first match too. No-match means this one complete eligible file was inspected, never the repository.
- Each rendered line has its original one-based line number. Long lines show at most 240 Unicode scalars; a matching line centers the excerpt around its first match, with up to 56 preceding scalars. Mark omitted prefixes/suffixes. Preserve the complete match within the line excerpt. Context lines show their first 240 scalars.
- Output includes repository/path/commit/blob provenance and the untrusted-reference warning. The existing shared output limiter remains final authority and may truncate the complete result with its explicit marker.
- Search, list and read share eight admitted calls, twelve network requests, 120,000 response-body bytes and 4,000 output characters per question. Existing 6,000-character hard maximum for configured scopes stays unchanged. Invalid queries consume a call, not a request. The root preflight remains in the same budget. A truncated prefix read can exhaust output, so guide the model to choose search first when it knows a symbol or phrase; search does not restore spent budget.
- Cancellation, revoked sessions, obsolete questions, parallel reservation accounting, connection fallback and error sanitization remain unchanged. Search performs no retry, write, background crawl or automatic permission change.

## Integration and preservation

Register the search tool beside list/read after the existing live preflight. Extend the compiled read-capability catalog with the same selected-repository read scope; it remains a declaration, not an executable grant. State, backup, sync, proposal publication, paired desktop grants, release identity and stable feed do not change. Android development stays paused; existing required checks remain.

## Verification and limits

First demonstrate the missing search operation through the existing registry consumer API in native CI. Then exercise real actor output with deterministic injected transport: late-file/long-line matches, CRLF/Unicode, overlapping windows, exact literal behavior, no match, omitted results, malformed queries, complete-file screening, shared budgets, pinning, invalid metadata, cancellation, revoked credentials and transport failure. Run full native/UI, TLS, desktop, Android, encrypted-transfer, retained-upgrade and device-packaging gates on the final head before publication.

No real private repository or credentials are used for development. Synthetic native tests establish tool/policy behavior, not that Apple's model always chooses the best query or that a physical iPhone was tested. No unrestricted repository autonomy or feature parity is claimed.
