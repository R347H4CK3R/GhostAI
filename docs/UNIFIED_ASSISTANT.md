# Unified assistant integration candidate

The visible assistant name is Jarvis. The app identifier, storage paths, signing identity requirements and model boundaries remain unchanged. This is an independently implemented personality and interface, not a copy of ChatGPT’s model or private conversations.

This branch adds original native planning and Luma-backup compatibility to Veyra. It is a source candidate, not a verified merged/released app. No private Luma source, conversations, credentials or model weights are embedded.

## Available in this candidate's source

- Assistant → Plan and act: four original offline planning templates, reviewed save into existing workspace memory, and exact question preview before using the existing local assistant. Templates are not AI output and saving one does not execute or schedule it.
- A navigation entry to the existing explicitly paired, read-only desktop job preview. This does not expand its permissions.
- Memory → Import conversations or memories → Luma plain backup JSON: selected notes and checklist status are previewed and imported additively as reference notes. Luma itself is untouched. Encrypted backups are unsupported. Existing file-reader, structural JSON validation, destination-epoch and canonical capacity checks remain in force.
- Siri/Shortcuts: Open voice controls routes to the Assistant voice sheet. It does not silently start recording. Start voice call and device permissions are still required. Existing voice turn-taking and optional supported active-background-audio behavior are preserved.

## Data preservation and boundaries

The bundle identifier, existing state schema and storage paths are unchanged. Keep both apps and backups until a signed-device upgrade and migration are verified. Luma notes retain timestamps; checklist records have no original date, so provenance explicitly identifies import time. Checklist records become snapshots, not editable live task objects. Reimported identical native records deduplicate within a workspace. Edited content creates a new snapshot instead of overwriting existing records. Old snapshots may remain retrievable; review them manually. Converter-generated imports and direct native imports use distinct namespaces; choose one route to avoid duplicate notes.

The adapter accepts a plain v1 backup with at most 1,000 memories, 3,000 checklist records and 2,000,000 input bytes. IDs must be unique across both collections. Notes/checklist fields are bounded in UTF-16 units for compatibility, booleans and dates are checked, and duplicate JSON keys are rejected upstream. Unknown fields are excluded. Possible secrets reject the import, but pattern screening is incomplete; review content locally. No account, provider token, permissions, models, settings or jobs migrate.

Opening planning or import makes no network call. Explicit Ask assistant uses the existing model/context and any already-selected bounded read-only GitHub tools. No hosted fallback, shell or autonomous write is added. Memory remains within existing finite device/canonical budgets, not infinite storage or permanent learning.

## Verification gates

Native XCTest files were authored before implementation but could not execute in the authoring Linux workspace: Swift/Xcode is unavailable. Static review cannot establish type correctness. Before merging/releasing, run the repository's existing iOS tests and compile gate once on the reviewed commit, followed by signed-device checks:

1. Install over the retained app without deleting it; verify existing notes/chats and settings.
2. Import synthetic Luma notes/checklists, reject duplicate-key/unsafe/malformed samples, cancel and change workspace mid-preview; confirm no unintended write.
3. Reimport the same file and then an edited snapshot; confirm deduplication and transparent old/new versions.
4. Create/save a checklist, review/submit a question and see its response in Assistant. Verify unavailable-model and busy states without lost drafts.
5. Invoke voice controls from Siri/Shortcuts while on each tab and during a pushed planning screen, on cold launch and with multiple active windows. Verify tab navigation, no recording before Start, permissions, interruption/stop and locked-screen behavior.
6. Verify SideStore signing/renewal and real-device foreground/background behavior. SideStore does not remove iOS sandbox, entitlements, background or microphone restrictions.

Future increments: native editable goal state, approved web-research tools with provenance, supported app integrations, archive/index capacity, and a reviewed scoped write-capable runner. Do not cut over existing jobs until end-to-end reliability and authorization are established. No model parity, unrestricted app control or always-on execution is promised.
