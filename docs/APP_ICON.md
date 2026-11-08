# App icon

The app icon is an opaque cyan/violet guiding star on midnight blue. iOS applies
its own rounded mask; the supplied artwork has square corners and no alpha.
The editable vector source is `Artwork/AppIcon.svg`.

`App/Assets.xcassets/AppIcon.appiconset` supplies all 18 iPhone, iPad and App Store
slots, backed by 13 RGB PNGs from 20 to 1024 pixels. The project selects this set
with `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`. XcodeGen discovers the asset
catalog through the existing `sources: [App]` declaration. Do not manually add
`CFBundleIcons` to the source plist: Xcode's asset compiler creates the compiled
icon metadata and packaged icon PNGs.

## Verification

These commands require only Python 3, with no extra packages:

```sh
python3 scripts/verify_app_icon.py
python3 -m unittest discover -s scripts/tests -v
python3 scripts/verify_app_icon.py --ipa AsterionVeyra-unsigned.ipa
```

The source check validates the complete size/scale matrix, PNG dimensions, CRCs,
and absence of alpha/transparency. The IPA check reads the real compiled plist,
requires a nonempty `Assets.car`, resolves every declared primary icon filename,
and requires both 120px and 180px iPhone home-screen PNGs. It targets a universal,
unthinned archive, such as the CI unsigned IPA. It does not decode the private
CAR format. CI runs source checks before project generation and checks the IPA
before uploading the build artifact.

To diagnose an old IPA independently of the current source:

```sh
python3 scripts/verify_app_icon.py --ipa-only --ipa /path/to/old.ipa
```

Build 17 (version 0.3.0) had no icon metadata, icon PNGs or `Assets.car`. The
regression check rejects that artifact. Rebuilding is necessary; adding artwork
to a checkout does not change an already downloaded IPA.

A packaging pass is not proof of signing, successful installation or appearance
on a physical home screen. Install a newly signed build and check the actual
icon on the intended device/importer. An old importer cache may still show an
older icon. Do not uninstall the app without exporting important local data.

## Regenerate artwork

With Inkscape and ImageMagick already installed:

```sh
python3 scripts/render_app_icon.py
```

The script renders the SVG, strips alpha and metadata, emits each required PNG,
rewrites the asset metadata and runs the source check. Committed PNGs keep
rendering tools out of the Xcode/CI build dependencies. Inspect the regenerated
1024px master and a small icon before committing any artwork changes.
