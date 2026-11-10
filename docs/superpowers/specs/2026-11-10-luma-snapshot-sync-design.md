# Luma snapshot import-time reconciliation

The user delegated continued one-app migration and preservation work. Independently importing the same Luma backup on two syncing devices currently gives the same checklist identity, text and provenance but different import-time `savedAt` values. The generic merge creates a conflict copy solely for that date difference.

## Approach

Reconcile only identical same-ID Luma checklist snapshots, choosing the earlier import time. Require byte-for-byte equal UTF-8 project, text and source, the exact checklist body header and import-time provenance markers, and UUIDv8. This covers both imported and explicitly restored identities while leaving UUIDv5 legacy conflict copies alone. Source text is classification metadata, never authentication or permission.

Alternatives considered: generic timestamp reconciliation for every note changes unrelated note semantics; changing import identities or dates cannot repair existing independent imports and would obscure provenance; parsing source IDs is ambiguous because valid IDs and filenames can contain delimiters, and restored IDs intentionally differ. The narrow merge rule is the implementation choice under the delegated request.

## Preservation boundaries

- Keep text, source, workspace and identity unchanged; only reconcile the otherwise identical import time.
- Real content/provenance/workspace differences retain existing three-way merge behavior. Different filenames remain distinct provenance.
- Different identities, including existing duplicate conflict copies, are never deduplicated or deleted.
- Deletion markers remain dominant. Explicit restoration keeps its existing deterministic ID and old tombstones.
- No schema, encryption, sync scope, credential, import acknowledgment, UI, job or permission changes.
- A changed saved date can invalidate a pending planning review, requiring a fresh review under existing safeguards.

## Verification

Use synthetic backups through the real importer, selection, sync capture, encoding/decoding and merge. Cover reverse merge order, repeated stale-device merge, restored imports, deletions, source/content/workspace changes, ordinary and dated Luma notes, legacy conflict IDs, distinct identities, delimiter-containing inputs, and changed completion status. Observe the duplicate regression fail natively before production changes, then require the complete CI and release gates.
