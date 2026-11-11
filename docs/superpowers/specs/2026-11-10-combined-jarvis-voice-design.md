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

## Lifecycle blocker found during integration
The first full-device-UI regressions found a navigation-bar ownership assertion when an open checklist editor becomes inactive, before any voice request. An identical no-voice control reproduces it. Removing the inner explicit identity and moving the sheet to the outer Memory navigation boundary did not repair it; both experiments are reverted rather than accumulated. A DEBUG-only independent editor host and minimal form control will isolate the failing boundary. None of these synthetic fixtures read or write user data. A missing editor after activation is not voice-routing evidence when activation relaunched a crashed process; require request and process diagnostics before assigning that cause. No candidate with this lifecycle failure may be promoted.

### Verified lifecycle differential
On iOS 26.2 with Xcode 26.3, the standalone exact editor and a minimal Form both crashed on inactivity when privacySensitive wrapped NavigationStack. Moving only the control's marker to Form preserved one process and the complete unsaved draft across two background cycles; the unchanged exact editor still crashed in that run. The narrow correction applies the same Form boundary to the exact editor. All private fields, completion, counts, workspace, errors and provenance remain marked; generic navigation chrome is excluded. This does not establish SwiftUI's internal mechanism or promise screenshot, recording, accessibility or app-switcher concealment. Synthetic original/redacted screenshots are required for visual coverage review before release. Full-app background and voice regressions still determine whether routing changes are necessary.
