# Working assistant identity and launch controls

## Intent
The screenshot requests a usable assistant menu, not a cosmetic copy. The user delegated UI and implementation choices. This independently reviewable iPhone increment makes local identity and launch choices work, while connecting the menu to existing real capabilities.

## Approach and scope
Use the existing native SwiftUI app. Persist a small versioned local preferences value separately from notes, chats, pairing and private sync. A shared observable owner supplies the current display name and one of six bundled SF Symbol avatars. A settings sheet edits a draft; Save validates and commits it, while Cancel changes nothing. Pick the launch tab from Assistant, Projects, Memory, Hosted or About. The selection applies on the next app launch, not immediately or on every foreground activation. Siri voice entry still opens Assistant controls and never starts recording.

The chat menu links directly to the existing paired-computer setup and to voice controls, exposes profile editing and a real Assistant-as-start-screen action, and keeps the existing explicitly confirmed Delete chat action. Existing notes, conversations and credentials remain unchanged. Names are presentation only and must never change model/tool authority or repository/workspace identity.

Alternatives considered: a visual menu with nonfunctional controls is rejected; combining a new texting/backend service and global pause with identity changes would expand access and create ambiguous cancellation semantics. Those need separate increments. Local preset avatars avoid new photo permissions and image-storage migration; photo avatars can follow separately.

## Constraints
- iOS 26+ native SwiftUI; no new dependencies, entitlements or remote accounts.
- Default name Jarvis, avatar sparkles and launch tab Assistant preserve current behavior.
- Trim leading/trailing whitespace; reject empty names, names over 40 Characters or 160 UTF-8 bytes, controls, line separators and bidirectional control scalars. Preserve other Unicode exactly.
- Versioned preferences never modify canonical memory, deletion markers, pairing credentials or sync setup. Malformed/unsupported stored preferences stay intact until an explicit valid save.
- No service, phone number, SMS/iMessage, all-day background execution, unrestricted computer control, global pause or whole-assistant deletion is claimed.
- Keep existing release/native/UI/retained-upgrade gates unchanged. No signed or physical-device verification is implied by CI.

## Acceptance
Profile edits change the header, assistant labels and composer and survive relaunch. Cancel and invalid input preserve the saved value. Unknown stored preferences use safe defaults and show a local explanation without silently writing. Launch-screen choice survives relaunch; foregrounding does not reset navigation; voice entry overrides it. Computer entry opens existing review, not automatic pairing or jobs. Existing chat/draft/voice/import/upgrade tests remain green.
