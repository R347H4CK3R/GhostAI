# Native unification implementation plan

Goal: expose original planning and selected Luma data in the existing native assistant without replacing its storage or runner.
Architecture: add isolated compatibility adapter and planning views; reuse canonical memory preview/merge and existing model interface. Voice shortcut only navigates to explicit controls.
Spec: ../specs/2026-11-09-unified-assistant-design.md

- [x] Inspect current main and isolate branch; preserve default branch and existing jobs.
- [x] Author Luma import, planning policy and voice routing XCTest cases before implementation.
- [x] Implement adapter with bounded types, dates, unique IDs, reference-only snapshots and no network.
- [x] Add original planning flow and reviewed local model question using existing state.
- [x] Add one-shot voice-controls navigation intent; retain explicit microphone start.
- [x] Independent static review and fixes; native routing remains a device-test gate.
- [ ] Run native tests/build on reviewed exact commit; authoring workspace has no Swift/Xcode.
- [ ] Signed-device upgrade, import and voice tests; no job cutover until verified and authorized.
