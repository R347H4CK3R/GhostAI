# Strata installation validation

The documented Strata at https://github.com/huzaifahshahid71-ops/Strata is based on LiveContainer 3.8.11. An installed app called Strata might be another build; verify its version/source before trusting it with data.

Our device build packages `Payload/AsterionVeyra.app` into `AsterionVeyra-unsigned.ipa`. The Strata importer expects a `Payload/*.app` directory with `Info.plist`, then patches and signs the guest. Download the Actions artifact ZIP and extract the IPA inside it; the outer ZIP is not the app.

Source references:
- Importer: https://github.com/huzaifahshahid71-ops/Strata/blob/main/LiveContainerSwiftUI/Views/AppList/LCAppListView.swift#L731-L753
- Host signing identity: https://github.com/huzaifahshahid71-ops/Strata/blob/main/LiveContainerSwiftUI/Utilities/LCUtils.m#L246-L262
- Guest bootstrap: https://github.com/huzaifahshahid71-ops/Strata/blob/main/LiveContainer/LCBootstrap.m#L482-L500

Strata changes the apparent main bundle and home directory and loads the guest in a host process. That does not give the guest a separate OS sandbox or establish all standalone app capabilities. The host may access guest data. FoundationModels compatibility in Strata has NOT been established by these source checks or by compilation.

## Minimal device validation
1. Use an Apple Intelligence-capable device on iOS 26+, with Apple Intelligence enabled and model assets available.
2. Import the extracted IPA in the existing trusted Strata installation, then launch normally in the foreground.
3. Check the app's Runtime diagnostics. An “On-device model ready” status is necessary but not sufficient.
4. Ask for a short greeting. Confirm actual model generation, not just availability.
5. Save a harmless dummy note, close/relaunch the guest and verify it is still there. Test a backup before trusting important memories.
6. If anything fails, retain the exact signing/launch/model error, iOS version and Strata version. Do not enter credentials while diagnosing the host.

A directly signed standalone installation with valid provisioning is a useful comparison if model generation fails in the guest. It is not a guarantee of success or proof that Strata must be replaced. No Apple signing credentials are embedded or collected by this project.
