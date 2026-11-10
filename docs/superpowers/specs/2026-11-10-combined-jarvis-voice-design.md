# Combined Jarvis checklist and voice integration

## Intent
Integrate the separately reviewed editable Luma copies, assistant controls and preview publisher without allowing an incoming voice navigation request to hide an unsaved checklist editor. The user has delegated implementation and publishing; this bounded interaction design is an engineering choice, not a new user instruction.

## Scope and constraints
- iPhone and iOS 26.0+, existing SwiftUI and data formats, no new dependencies.
- Preserve unsaved fields while the editor is open. Do not save, cancel, start a microphone, send a request or expand permissions because voice navigation arrives.
- After Save, Cancel or interactive dismissal actually completes, route to Assistant and show voice controls once. A failed Save keeps the editor and pending request.
- Use the existing single pending VoiceEntryRequest and PR6 consume(canPresent:) API. Existing profile/computer sheet gating remains intact.
- Integrate histories and the exact reviewed publisher patch. No default/stable source change. Full exact-head PR and release gates remain required.
- This does not claim universal modal routing, background recording, multiple-window intent targeting or real-device installation proof.

## Approaches
1. Automatically dismiss the editor: rejected because it could discard an unsaved draft.
2. Global token/lease registry for every app sheet: can support all windows, but adds lifecycle/concurrency and cleanup machinery beyond this iPhone interaction.
3. A scene-owned editor presentation binding shared by MainView, MemoryView and ChatView: chosen as the smallest explicit lifecycle gate. MainView postpones tab changes, ChatView postpones consumption, and MemoryView releases only in sheet onDismiss. Scene destruction cannot leak a global block. Cost: other unrelated sheets and multiwindow routing keep their existing behavior.

## Verification
A DEBUG-only, synthetic checklist fixture requests voice navigation on a real background-to-active transition. Production routing and real editor/save/dismissal are exercised. Native UI tests prove draft survival and eventual once-only voice controls after Save, Cancel and interactive dismissal. They never start the microphone. Existing model/store/import/sync tests, encrypted transfer, baseline retained-install upgrade and unsigned device build remain mandatory. One composition review precedes release.
