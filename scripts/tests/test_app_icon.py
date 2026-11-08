"""Regression coverage for icon checks using deliberately broken local artifacts."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('verify_app_icon', ROOT / 'scripts/verify_app_icon.py')
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def png(size, alpha=False, transparency=False):
    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data))
    channels = 4 if alpha else 3
    data = b'\x89PNG\r\n\x1a\n'
    data += chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 6 if alpha else 2, 0, 0, 0))
    if transparency:
        data += chunk(b'tRNS', b'\0' * 6)
    data += chunk(b'IDAT', zlib.compress((b'\0' + b'\xff' * size * channels) * size))
    return data + chunk(b'IEND', b'')


class IconValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)

    def source_copy(self):
        shutil.copytree(ROOT / 'App/Assets.xcassets', self.path / 'App/Assets.xcassets')
        shutil.copy(ROOT / 'project.yml', self.path / 'project.yml')
        return self.path / 'App/Assets.xcassets/AppIcon.appiconset'

    def make_ipa(self, *, assets=True, metadata=True, high_resolution=True):
        path = self.path / 'fixture.ipa'
        primary = {'CFBundleIconName': 'AppIcon', 'CFBundleIconFiles': ['AppIcon60x60']}
        info = {'UIDeviceFamily': [1], 'CFBundleVersion': '1', 'CFBundleShortVersionString': '0.0.0'}
        if metadata:
            info['CFBundleIcons'] = {'CFBundlePrimaryIcon': primary}
        prefix = 'Payload/Fixture.app/'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr(prefix + 'Info.plist', plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
            if assets:
                # Presence is the check's contract; it does not parse Apple's private CAR format.
                archive.writestr(prefix + 'Assets.car', b'fixture-placeholder')
            archive.writestr(prefix + 'AppIcon60x60@2x.png', png(120))
            if high_resolution:
                archive.writestr(prefix + 'AppIcon60x60@3x.png', png(180))
        return path

    def test_current_source_has_every_required_opaque_icon(self):
        with contextlib.redirect_stdout(io.StringIO()):
            check.verify_source(ROOT)

    def test_source_rejects_incorrect_pixel_dimensions(self):
        iconset = self.source_copy()
        (iconset / 'AppIcon-180.png').write_bytes(png(179))
        with self.assertRaisesRegex(ValueError, 'expected.*180'):
            check.verify_source(self.path)

    def test_source_rejects_missing_ipad_slot(self):
        iconset = self.source_copy()
        path = iconset / 'Contents.json'
        content = json.loads(path.read_text())
        content['images'] = [e for e in content['images'] if e['size'] != '83.5x83.5']
        path.write_text(json.dumps(content))
        with self.assertRaisesRegex(ValueError, 'Incorrect AppIcon slots'):
            check.verify_source(self.path)

    def test_source_rejects_missing_icon_selection(self):
        self.source_copy()
        path = self.path / 'project.yml'
        path.write_text('\n'.join(line for line in path.read_text().splitlines()
                                  if 'ASSETCATALOG_COMPILER_APPICON_NAME' not in line))
        with self.assertRaisesRegex(ValueError, 'must select'):
            check.verify_source(self.path)

    def test_png_rejects_even_fully_opaque_alpha_channel(self):
        with self.assertRaisesRegex(ValueError, 'no alpha channel'):
            check.png_metadata(png(20, alpha=True), 'alpha.png', require_rgb=True)

    def test_png_rejects_rgb_transparency_chunk(self):
        with self.assertRaisesRegex(ValueError, 'transparency'):
            check.png_metadata(png(20, transparency=True), 'transparent.png', require_rgb=True)

    def test_png_rejects_corrupted_bytes(self):
        data = bytearray(png(20))
        data[-1] ^= 1
        with self.assertRaisesRegex(ValueError, 'CRC'):
            check.png_metadata(bytes(data), 'corrupt.png', require_rgb=True)

    def test_ipa_accepts_required_metadata_and_files(self):
        with contextlib.redirect_stdout(io.StringIO()):
            check.verify_ipa(self.make_ipa())

    def test_ipa_rejects_missing_compiled_asset_catalog(self):
        with self.assertRaisesRegex(ValueError, 'Assets.car'):
            check.verify_ipa(self.make_ipa(assets=False))

    def test_ipa_rejects_missing_primary_icon_metadata(self):
        with self.assertRaisesRegex(ValueError, 'primary AppIcon metadata'):
            check.verify_ipa(self.make_ipa(metadata=False))

    def test_ipa_rejects_missing_3x_home_screen_icon(self):
        with self.fake_assetutil([]):
            with self.assertRaisesRegex(ValueError, '180px'):
                check.verify_ipa(self.make_ipa(high_resolution=False))

    # Synthetic assetutil records, not a claim to have inspected a native build.
    def catalog_entry(self, **changes):
        entry = {'AssetType': 'Icon Image', 'Name': 'AppIcon', 'Idiom': 'phone',
                 'PixelWidth': 180, 'PixelHeight': 180, 'Scale': 3,
                 'RenditionName': 'AppIcon-180.png', 'Opaque': True,
                 'SizeOnDisk': 500}
        entry.update(changes)
        return entry

    def fake_assetutil(self, entries, returncode=0):
        def run(command, **kwargs):
            # The JSON evidence must come from the CAR inside this IPA, never
            # another build's catalog or a caller-supplied inventory.
            self.assertEqual(command[:-1], ['xcrun', '--sdk', 'iphoneos', 'assetutil', '--info'])
            self.assertEqual(Path(command[-1]).read_bytes(), b'fixture-placeholder')
            return subprocess.CompletedProcess(command, returncode,
                                               stdout=json.dumps(entries), stderr='tool diagnostic')
        return mock.patch('subprocess.run', side_effect=run)

    def test_ipa_accepts_3x_home_screen_icon_in_exact_bundled_catalog(self):
        report = self.path / 'asset-info.json'
        entries = [{'SchemaVersion': 2}, self.catalog_entry()]
        with self.fake_assetutil(entries), contextlib.redirect_stdout(io.StringIO()):
            check.verify_ipa(self.make_ipa(high_resolution=False))
            check.verify_ipa(self.make_ipa(high_resolution=False), asset_info_output=report)
        self.assertEqual(json.loads(report.read_text()), entries)

    def test_catalog_rejects_wrong_icon_identity_dimensions_type_idiom_or_scale(self):
        for change in [{'Name': 'AnotherIcon'}, {'Name': 'AppIcon-Other'},
                       {'AssetType': 'Image'}, {'AssetType': 'MultiSized Image'},
                       {'Idiom': 'pad'}, {'Idiom': 'marketing'},
                       {'Scale': 2}, {'PixelWidth': 179}, {'PixelHeight': 179}]:
            with self.subTest(change=change), self.fake_assetutil([self.catalog_entry(**change)]):
                with self.assertRaisesRegex(ValueError, '180px'):
                    check.verify_ipa(self.make_ipa(high_resolution=False))

    def test_catalog_checks_do_not_replace_required_loose_120px_icon(self):
        path = self.make_ipa(high_resolution=False)
        # Retain metadata and an incorrectly sized PNG so the size gate must run.
        with zipfile.ZipFile(path) as source:
            contents = {n: source.read(n) for n in source.namelist()}
        contents['Payload/Fixture.app/AppIcon60x60@2x.png'] = png(119)
        with zipfile.ZipFile(path, 'w') as target:
            for name, data in contents.items():
                target.writestr(name, data)
        with self.fake_assetutil([self.catalog_entry()]):
            with self.assertRaisesRegex(ValueError, '120px'):
                check.verify_ipa(path)

    def test_catalog_tool_failure_is_not_accepted_even_with_valid_stdout(self):
        report = self.path / 'asset-info.json'
        entries = [self.catalog_entry()]
        with self.fake_assetutil(entries, returncode=1):
            with self.assertRaisesRegex(ValueError, 'assetutil.*failed'):
                check.verify_ipa(self.make_ipa(high_resolution=False), asset_info_output=report)
        self.assertEqual(json.loads(report.read_text()), entries)

    def test_catalog_invalid_json_is_preserved_and_rejected(self):
        report = self.path / 'asset-info.json'
        with mock.patch('subprocess.run', return_value=subprocess.CompletedProcess([], 0, 'invalid', '')):
            with self.assertRaisesRegex(ValueError, 'assetutil.*JSON'):
                check.verify_ipa(self.make_ipa(high_resolution=False), asset_info_output=report)
        self.assertEqual(report.read_text(), 'invalid')

    def test_catalog_wrong_json_shape_is_rejected(self):
        for value in [{'Name': 'AppIcon'}, [None], 'AppIcon', []]:
            with self.subTest(value=value), self.fake_assetutil(value):
                with self.assertRaises(ValueError):
                    check.verify_ipa(self.make_ipa(high_resolution=False))

    def test_catalog_unavailable_tool_fails_closed_with_useful_error(self):
        with mock.patch('subprocess.run', side_effect=FileNotFoundError('xcrun')):
            with self.assertRaisesRegex(ValueError, '180px.*assetutil'):
                check.verify_ipa(self.make_ipa(high_resolution=False))


if __name__ == '__main__':
    unittest.main()
