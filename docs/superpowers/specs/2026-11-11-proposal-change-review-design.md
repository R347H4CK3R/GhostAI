# Proposal change review

## Intent and delegated choice

The user wants practical repository management in the unified iPhone assistant and delegated the next safe increment. Build 13 can inspect pinned source and publish one explicitly reviewed replacement as a draft PR, but review currently requires manually comparing two full files. Add a local change preview to that existing immutable review. This is a review aid, not new model or publishing authority.

## Approaches

- Selected-file path prefill reduces navigation but does not help verify an edit.
- On-device generated replacements provide more authoring help but require a larger inference, cancellation and source-binding design.
- Choose a deterministic local change preview first. Common-prefix/common-suffix line comparison is linear and bounded; quadratic minimal-diff algorithms are unnecessary for the current 30 KB files. Disjoint changes remain one changed region, including unchanged middle lines, and the UI must say so.

## Contract

Create an immutable comparison from the exact original/replacement when `RepositoryProposalReview` is prepared. The complete original, replacement, title, destination and PR body remain visible and authoritative. No consent is inferred from viewing a preview. Editing continues to invalidate the review; publisher, credentials, source verification, scopes and recovery receipts remain unchanged.

Compare exact UTF-8 line bytes, including terminators, without normalization or case folding. Empty files have zero lines; a trailing LF terminates its preceding line and does not create an extra line. Distinguish LF, CRLF and missing final newline. Trim only identical prefix and suffix lines. Preserve line numbers and full changed-region counts. Do not claim a minimal diff or exact minimal addition/deletion counts.

Display the first 12 removed and first 12 added lines, at most 24 rows. Each line's rendered content is limited to 240 UTF-8 bytes, only at Unicode-scalar boundaries, with explicit shortening metadata. Render backslashes, tabs, standalone CR, Unicode line/paragraph separators and trailing ASCII spaces visibly. Append an explicit LF/CRLF/no-newline marker to every row. Output must unambiguously distinguish literal escape text from escaped controls. Report omitted rows separately from shortened displayed rows. Rendering never modifies the actual source/replacement.

Use a disclosure section labeled Change preview before both complete files. Explain the changed-region algorithm and bounds, including when no identical prefix/suffix exists. Use text/symbol labels in addition to color. Avoid expensive per-line SwiftUI trees for pathological newline-heavy inputs. Privacy shielding remains supplied by the existing proposal screen.

## Scope and verification

No new networking, credentials, source persistence, model tools, path prefill or publishing methods. No Android changes. Existing review/publisher/receipt and release gates remain mandatory.

Pure tests cover empty/identical/insertion/deletion/replacement/disjoint/repeated-line input, exact Unicode, CRLF/LF/final-newline distinctions, escaping, large inputs, rendering caps and immutable review binding. A DEBUG-only isolated UI host displays the real review-content component with synthetic data, no ordinary stores, credentials or network. UI tests inspect the comparison alongside full files and capture screenshots. Native tests run in the existing CI because this Linux workspace has no Swift/Xcode.
