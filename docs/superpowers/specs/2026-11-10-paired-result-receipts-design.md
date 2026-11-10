# Durable paired desktop observations

## Intent and scope

Keep a bounded desktop response available after the iPhone app restarts, beside the exact reviewed request. This is a local observation record, not a signed desktop attestation, independent verification of model claims, or permission to execute more work. Existing read-only grants, protocol, app identity, storage policy and release gates stay unchanged.

## Chosen approach

Add an optional `resultReceipt` to each saved job and commit it atomically with status in the existing passcode-bound Keychain record. Compared with metadata-only receipts, a short preview makes the record useful offline. Full summaries or separate receipt files would require more storage and multi-record recovery, so they are outside this increment.

The receipt includes version, job/project/submission identities, phone observation time, reported status and cancellation flag, four counters, bounded error code, a 256-UTF-8-byte summary preview, full summary byte count/hash, and exact response byte count/hash. Null and empty summaries remain distinct. Truncate only at Unicode-scalar boundaries and disclose truncation. Hashes are integrity references for observed bytes, not proof of execution.

## Preservation and transitions

Legacy jobs decode without a receipt. Never reconstruct old results, delete history or overwrite malformed records. Validate the entire response and receipt before saving. Keep an observed terminal result's status, counters, summary identity and error immutable; reject conflicting results and terminal-to-running regressions. Accept equivalent JSON formatting and cancellation requested changing from false to true. Running-to-starting is valid host recovery. A failed refresh must not create a new timestamp, replace the prior receipt or publish new details.

## Capacity

Retain the existing 96 KiB record limit and 20-job ceiling. New submissions reserve a provable worst-case encoded receipt for every retained job plus the new job, along with existing sequence/status/cancellation reservations. Before reading or cancelling an existing job, reserve the target receipt before any sequence or network change. Old near-full records report a local capacity limit without eviction or falsely marking Keychain storage unreadable. Use escaped control-character fixtures to test encoded-size bounds.

## UI and limits

Show saved observations without a network request. Label observation time as phone receipt time, summaries as model text, and nonterminal states as nonfinal. Expose counters and response fingerprint in a disclosure. Missing receipts are explicit. No repository commit pin, write execution, task scheduling, migration of credentials or physical-device verification is introduced.

## Verification

Test Codable relaunch, legacy compatibility, malformed/binding/counter failures, Unicode/null/empty previews, semantic transitions, late cancellation, atomic save failure, lifecycle cancellation, near-full legacy preflight and admission reservation. Run complete native/UI, desktop, Android, transfer, retained-upgrade and packaging gates on the final candidate before publication.
