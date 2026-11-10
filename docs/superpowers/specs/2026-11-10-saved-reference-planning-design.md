# Reviewed planning from saved Luma context

## Intent and scope

Let one Jarvis use an imported Luma note/checklist as an explicitly selected planning reference. Preserve the original snapshot, dates, IDs, backup and private-sync behavior. The user supplies a goal, sees the exact bounded question, and separately chooses Ask. Opening or selecting does not send, schedule, mutate notes, or create a desktop job.

The user delegated continued implementation and asked to finish the combined assistant. This is an implementer-chosen narrow increment, not a claim of complete Luma migration, live checklist editing, or autonomous execution.

## Approaches

- Chosen: a saved-reference picker within the existing Plan and act screen. It reuses the current ChatView question submission, error/retry and draft isolation unchanged.
- Deferred: a direct cross-tab Memory-to-planning route. It adds navigation/ownership complexity without adding a new capability.
- Deferred: live editable imported checklists. This needs a versioned canonical schema and cross-platform backup/sync design.

## Design

- Default is no selected reference. Picker searches only current-workspace notes, including imported Luma snapshots, without source-string-based privilege.
- Capture the entire selected MemoryNote and current workspace epoch. Before producing or sending a question, confirm the exact note still exists in the same workspace and epoch. Deletion, replacement, switch-away-and-back, or selection changes invalidate the prepared question.
- Show the source/date and full original through disclosure, plus the exact bounded excerpt and an explicit shortening notice. Original text never changes. The goal starts empty and is not inferred from imported prose.
- Question construction keeps the existing 2,000-character limit and independently caps reference text at 800 UTF-8 bytes and source at 120 UTF-8 bytes, truncating at a Unicode-scalar boundary. Further reduce the excerpt if JSON escaping makes the final question exceed 2,000 characters. Fail if the bounded metadata and user goal alone do not fit; never silently truncate the user's goal.
- Return one deterministic composed review containing question, final excerpt/source and shortening flags. Use sorted JSON keys and a fixed saved_at_ms timestamp; explain that saved date may be import time. Cap the complete question at 8,192 UTF-8 bytes as well as 2,000 characters, rejecting an oversized user goal rather than truncating it. Encode reference identity/source/date/text as JSON data after clear untrusted-reference instructions. Imported instructions cannot grant tools or permissions. Show the complete exact question before Ask. Use the existing on-device assistant and normal workspace context; no hosted fallback or broader grant is introduced.
- The selected reference affects only the assistant planning question. Offline checklists remain fixed templates based on the user's goal. Paired-desktop handoff uses only that goal and never copies the selected note. UI states these distinctions.
- Selecting, removing or changing context resets pending question review. Ask revalidates the snapshot and regenerates the question to require exact equality with what was reviewed.
- Only selection/review state is ephemeral. Successful Ask persists the question and reference excerpt in normal chat, under existing approved sync. No new persistence, encryption, sync schema or Luma source code is introduced.

## Acceptance

Native tests cover bounded escaped/Unicode content, exact reference identity and provenance, stale/deleted/replaced notes, foreign workspace/epoch, unsafe text, unchanged originals, unchanged no-reference question, and desktop exclusion. UI covers explicit choice, workspace isolation, empty-goal review, full question before send, cancellation/removal invalidation, and typed-chat draft preservation. Existing complete CI and release gates remain mandatory. Physical iPhone verification remains separate.
