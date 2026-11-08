# Opt-in voice conversations on iPhone

Voice starts from an explicit user action. Approve microphone and speech permissions in the foreground. Foreground-only behavior is the default. A separate background-voice opt-in applies only to the current user-started conversation; it must not be restored automatically from saved preferences.

## Direct SideStore installation and background audio

The directly installed app can declare `UIBackgroundModes: audio` for legitimate recording and speech playback during an explicitly enabled conversation. With `allowsBackgroundVoice` enabled, going to another app or locking the screen does not itself end an active voice turn. This is supported background-audio architecture, not a claim that continuous conversation has been validated on a particular iPhone or SideStore installation.

There is no silent-audio keepalive, custom wake-word listener, always-on assistant, automatic relaunch, or indefinite background computation. Each listening turn remains bounded. iOS may interrupt, suspend, or terminate the app; recognition availability, audio routing, battery usage, lock-screen behavior, and actual background continuation need device testing. A silent user reaches the listening timeout rather than keeping a microphone session alive indefinitely. Audio interruptions and disconnected audio devices stop the session without automatic resumption.

Between recording and spoken playback, a single `UIApplication` background task requests finite time to finish the response to the recognized utterance. iOS controls the time allowed. Expiration stops voice and publishes an interrupted state; the UI must cancel its model request and disable conversation. The task is not renewed while waiting for that response. It ends when speech actually starts, on Stop, on failure, or on explicit completion. No unrelated work should use it.

## Turn flow and limits

1. A user starts a conversation; the UI may set `allowsBackgroundVoice = true` only after the explicit background opt-in.
2. Call `startListening(onFinal:)`. Existing speech and microphone authorization are required for any background turn. The controller never starts a permission prompt in the background.
3. Recognition must be available **on device** for the current locale. `requiresOnDeviceRecognition = true` prevents server-recognition fallback. Unsupported devices/languages show an unavailable state.
4. A recognizer-final result or two seconds without a transcript update completes a turn. The latter is a transcript-based endpoint, not perfect acoustic silence detection. A dictation pause can submit the current text.
5. The controller begins its finite reply window, ends capture, then invokes the final callback. Pass the captured text to the assistant. The controller saves no raw microphone recording. Text sent to the configured model service follows normal chat persistence. On-device transcription does **not** mean offline assistant reasoning.
6. Call `speak(_:onFinished:)` for the answer. It preserves the existing reply window while transitioning to playback and ends it when playback starts. Call `endReplyWindow()` if the model turn ends without spoken output.
7. Restart listening only while conversation remains enabled, the model is idle, and the app is foreground or this conversation has background opt-in. `VoicePolicy.shouldListen` accepts `allowsBackgroundVoice` with a safe default of false.

Listening is capped at 45 seconds and 2,000 characters. Exceeding a limit stops without submitting the turn. Spoken output is capped at 4,000 characters; the full answer remains as text. Empty input, recognition failures, permission refusal, and microphone failure stop without automatic retries.

System speech synthesis supplies spoken output. Voice quality and language support depend on installed iOS voices. Turns are sequential, not full duplex: capture ends before playback. Use Stop for interruption; spoken barge-in is not implemented.

## Lifecycle and integration

`VoiceController` publishes `state`, `status`, `transcript`, and `allowsBackgroundVoice`. Keep it alive as a SwiftUI state object. The public API includes `startListening(onFinal:)`, `speak(_:onFinished:)`, `stop()`, `beginReplyWindow()`, and `endReplyWindow()`.

`beginReplyWindow()` is automatically called for a recognized turn. Repeating it during that reply does not renew the allowance. It is not a general-purpose background-work API. The default `stop()` ends the window, invalidates callbacks, cancels recognition, removes the tap, ends audio, and deactivates the audio session. Internal recording/playback transitions preserve only an existing finite reply window where needed.

On user Stop, disable conversation, call `stop()`, set `allowsBackgroundVoice = false`, and cancel the model request. Disable conversation on `.failed`, `.unavailable`, and `.interrupted`; do not immediately retry. Pause on inactive/background scene changes unless the current conversation has explicit background opt-in. Always honor genuine audio interruptions, route disconnection, and media-service resets, including while waiting for a model reply.

The background flag does not itself start audio or acquire permissions. Changing it to false while backgrounded stops an active session. The controller does not clear the flag during internal turn transitions; the UI owns user session consent and resets it on Stop/failure.

Include `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, and the `audio` background mode in the directly installed app's Info.plist. Do not use background audio to keep unrelated computation alive.

Strata/LiveContainer is not the primary installation path. Its host audio behavior remains unverified; guest entitlements do not become host entitlements, guest data shares the host sandbox, extensions are unsupported, and remote push is unavailable. Native build success does not establish host support.

## Verification still required

`Tests/VoicePolicyTests.swift` checks opt-in/foreground gating, required background authorization, non-resumption after interruptions, transcript validation, and limits. These are policy tests, not microphone or lifecycle integration tests. Swift and Xcode are unavailable in this Linux workspace, so no build or XCTest result is claimed here.

Run the full suite on macOS CI, then test the SideStore-installed build on a real iPhone:

- Approve and deny each permission; verify background turns never show permission prompts.
- Check supported on-device recognition offline and unavailable locales.
- Verify exactly one submission and reply for each voice turn, including repeated turns.
- Compare default foreground mode with explicit background opt-in while switching apps and locking the screen, during capture, model response, and playback.
- Stop during every phase; verify pending callbacks cannot restart voice.
- Test calls/audio interruptions, headset disconnection, route changes, and media-service reset. Verify no automatic restart.
- Test finite background-task expiration; verify the model request is cancelled by the UI and no new task renews the waiting response.
- Exceed the 45-second/2,000-character limits; verify no submission. Test silent listening timeout and long-answer speech clipping.
- Measure battery use and confirm visible system microphone indicators match actual capture. Do not promise all-day availability based only on a successful simulator build.

## Memory while locked

The local memory store uses iOS complete-until-first-user-authentication file protection. It is unavailable until the first unlock after restarting the phone, and remains available to the app after that so an explicitly started background voice session can save its conversation while locked. This differs from complete protection, which makes storage unavailable each time the screen locks. Strata's host-level data access remains a separate trust boundary.
