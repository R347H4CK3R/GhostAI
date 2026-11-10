# Jarvis task execution architecture

## What this increment actually connects

The native planning surface can now prepare an exact read-only investigation goal and hand it to the existing paired-desktop job screen. The user still selects an explicitly granted desktop workspace, reviews finite limits and submits there. The pairing client retains operation IDs, request bytes and status references under its existing protocol. Neither a plan nor imported note authorizes execution. No automatic submission, credential grant, implicit note transfer or write capability is added.

The phone owns interaction, local context and review. Existing explicitly configured encrypted memory sync remains independent of job submission and retains build44 consent, recovery and deletion rules. The planning/save and import screens disclose that included workspaces can sync to their approved private vault. No new sync setup occurs automatically.

A separately approved foreground desktop host owns the existing bounded local-model job loop. Phone backgrounding stops its networking; accepted desktop work may continue only while that host runs. This split avoids promising unrestricted iPhone background execution or a local Xcode toolchain.

## Durable reviewed requests on iPhone

Newly accepted paired jobs retain their exact reviewed request bytes, goal, desktop project identifier, grant revision, budgets and submission identifier alongside the returned job identifier. The accepted request survives controller/process restart in the existing passcode-bound, device-only Keychain record. The job screen shows the original goal and a collapsible scope summary. Older saved jobs still decode, but explicitly say their original request was not retained; nothing reconstructs missing intent from current grants or model text.

Before a submission is sent, the client checks the existing 96 KiB record budget with room for the accepted manifest, maximum sequence/status text and cancellation identities. Capacity exhaustion sends nothing and consumes no sequence. A new request is rejected before creating an outbox; an existing outbox remains intact for reconciliation. History is never silently evicted. A local save failure after remote acceptance also leaves the original outbox intact; an explicit retry reconciles the same submission bytes and identifier.

This is an incremental read-only job manifest, not the complete future repository execution manifest. It does not yet pin a repository commit, store a durable result/evidence receipt, authorize patches, or execute writes. Current desktop grants remain authoritative. Model summaries are still transient and are not independent proof of completion. These additions require native CI and signed-device verification before a new candidate is released.

## Execution progression

1. **Capture intent.** Keep the exact user goal and chosen workspace. Preserve a typed draft separately from a planned request. Imported/source text is evidence, not instructions.
2. **Prepare a plan.** State the expected outcome, needed tools, target paths/repositories, evidence and reversible steps. Current native templates are reference checklists; model requests use existing bounded read-only tools.
3. **Validate capabilities.** Refuse unsupported actions instead of claiming success. Resolve repository and revision, allowed roots, source freshness, network availability and available credentials. Never infer owner-level rights from the assistant name.
4. **Review the exact action.** For current paired jobs, use the existing immutable submission and limits screen. Future writes must identify target revision, paths, patch, tests, destination and required permission. Persistent account access has a separate explicit setup/revocation flow.
5. **Execute with receipts.** Existing paired jobs use their operation ID and outbox; connection loss is uncertain acceptance, not permission to submit a new duplicate. The host returns status and evidence. Model prose alone is not proof.
6. **Verify before completion.** Compare expected outputs and tests to actual results, return remaining failures, and keep failure/retry context. No automatic default-branch merge, production deployment, purchase or communication is implied by a planning prompt.
7. **Follow through within approved scope.** A future write-capable executor should make isolated branches/worktrees, bounded repair attempts and reviewable PRs; require confirmation where policy requires it. Existing jobs remain active until verified replacement and explicit cutover.

## Next implementation boundaries

- Add a **durable job manifest** independent of chat with immutable intent, repository/commit, scoped tool grants, approved changes, budgets, current state, external operation IDs and evidence references. Never put credential material into manifests or model context.
- Extend the host with a **reviewed patch executor**, not a generic unrestricted shell endpoint. Constrain paths and file types, reject links/path escape, check expected base hashes, validate patch preview equality, use a dedicated workspace and return actual test results. Separate proposal, approval and execution; replay cannot reapply a different patch.
- A **GitHub service adapter** may read/branch/open reviewable changes within explicitly authorized repositories. Owner account access is not inherited. Setup must be least-privilege and revocable. Writes remain unimplemented in the paired protocol today.
- **Web research** needs a separately disclosed network tool, bounded responses, citations/provenance and untrusted-content handling. Do not let a web page grant tool access or initiate downloads/executable installation. Offline saved sources must be dated and clearly marked stale.
- **Other apps** use supported App Intents, Shortcuts, URL schemes, document pickers or provider APIs. SideStore signing does not confer another app's private data or unrestricted device control.
- **Growing knowledge** should move toward paged local indexes and explicit archive/import/export while retaining canonical provenance and deletion behavior. Existing 5 MB canonical backup and finite context budgets are still enforced. Expansion means user-controlled storage management, not infinite capacity, guaranteed retention or permanent model training.

## Offline bundle and model reality

Planning templates, native UI, import validation and currently shipped client tools are in the app bundle. Apple supplies Foundation Models through iOS on supported, enabled devices; those OS-managed model assets cannot simply be embedded in this IPA. The app must show availability and keep notes/planning/text access usable without pretending inference ran. Optional hosted services remain separate, reviewed and may cost money. Never bundle credentials, another assistant's private history, or unlicensed model weights. A future bundled local model needs license, device-memory, download-size and real inference validation.

## Acceptance gates before claiming autonomy

Synthetic read-only job: approved pairing → selected goal/workspace/limits → one accepted operation → real results → restart/status recovery → cancellation and denial checks. Then separately test scoped patches on disposable repositories with stale-base, path-escape, duplicate-submit, permission-withdrawal, network-loss and failed-test cases. Physical iPhone/SideStore voice, background, pairing and upgrade tests remain distinct from simulator compilation. No claim of full autonomous repository management or ChatGPT model parity is justified by this candidate.
