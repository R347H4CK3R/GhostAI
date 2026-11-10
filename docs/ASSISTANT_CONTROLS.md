# Local assistant controls

Assistant → Chat options → Edit name & avatar changes the displayed name and one of six bundled local avatars. Save applies all choices together; Cancel keeps saved settings. The header, assistant message labels, composer, voice description and app alert title use the display name. Existing messages, models, workspace identities, permissions and credentials do not change. App/Shortcuts installation names remain Jarvis.

The same sheet chooses a launch tab. It applies on the next launch, not immediately, not on returning from the background and not by changing the iOS Home Screen. Chat options → Set as start screen restores Assistant as the launch tab. Siri voice requests still route to Assistant and open controls without activating the microphone. A request arriving while profile/computer/voice controls are open stays pending until those controls are dismissed.

Computers opens the existing explicitly configured read-only paired-desktop screen, using the shared client and existing approval rules. With an existing pairing, opening that screen can refresh its approved status. It never creates a pairing, grants scope or submits a job automatically. It is not a managed cloud computer or general shell.

## Persistence and validation

A dedicated versioned UserDefaults value stores only display name, preset avatar and start tab, separately from notes, chats, knowledge and pairing. It is device-local, excluded from the app's memory backup/private-sync formats, and may be included in OS device backups. Missing settings use Jarvis/sparkles/Assistant without writing. Unsupported/corrupt settings are preserved on load with a visible explanation in the editor; an explicit valid Save replaces only that settings value.

Names trim surrounding spaces but reject line breaks, ASCII/C1 controls, line separators and bidirectional control scalars before trimming. Limits are 40 Swift Characters and 160 UTF-8 bytes. Ordinary Unicode including combining accents and emoji joiners stays byte-exact. Preset avatars need no photo permission, remote image request or new image storage. Arbitrary uploaded photos are not included.

## Separate work still required

No SMS/iMessage provider, phone number, general attachment/vision model, persistent global assistant pause, whole-assistant deletion, always-on service or unrestricted repo automation is introduced. Existing Clear chat / Delete chat remains explicitly limited to the selected project's history; it does not delete notes, connections or host jobs. Existing Stop generating / End call remain session controls. A broader lifecycle or texting feature needs a real service/permission/cancellation design.

Native/UI tests include synthetic profile save/relaunch/cancel, unchanged drafts, invalid names, launch-tab behavior, direct computer review and Siri navigation. Release gates and real signed-device checks are still required before treating a candidate as installable and reliable.
