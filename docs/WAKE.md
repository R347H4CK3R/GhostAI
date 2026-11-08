# Voice entry and Siri

Asterion supplies an App Intent and App Shortcut for a **directly installed** app: ask Siri to open Asterion Veyra, then choose voice or text inside the app. Opening never silently starts microphone capture. OS registration, Siri availability/language and actual invocation must be verified on the device.

This is Apple's Siri wake mechanism, not an always-listening custom “Hey Asterion” detector. A normal third-party iOS app cannot assume Siri's privileged wake-word/background behavior.

Strata guests are dynamically hosted rather than independently installed with their full OS identity. Their App Intent metadata must not be assumed registered by iOS. A separate user-created Shortcut that opens a documented Strata launch URL may be possible; use only the scheme and guest identifier supported by the installed Strata version. No automatic shortcut installation or host entitlement change is performed by this app.

The app's capabilities screen offers documented Open Shortcuts and Create Shortcut editor links. They open the system UI for user configuration; they do not silently install arbitrary workflows. Built-in app actions are extracted through AppShortcutsProvider.

For Strata, a user-created Shortcut can open the documented host link `livecontainer://livecontainer-launch?bundle-name=<installed-guest-folder>`. Use Strata's generated guest link rather than guessing the folder or host scheme when multiple container apps are installed. The host's source is linked in STRATA.md.
