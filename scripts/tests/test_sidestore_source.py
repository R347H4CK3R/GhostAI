import hashlib
import importlib.util
import json
import plistlib
from pathlib import Path
import struct
import stat
import sys
import tempfile
import unittest
import zipfile

SCRIPTS = Path(__file__).parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('sidestore_source', SCRIPTS / 'sidestore_source.py')


def info_fixture():
    return {'CFBundleIdentifier': 'dev.asterionveyra.assistant',
            'CFBundleVersion': '40', 'CFBundleShortVersionString': '0.3.4',
            'CFBundleSupportedPlatforms': ['iPhoneOS'], 'MinimumOSVersion': '26.0',
            'CFBundleExecutable': 'AsterionVeyra',
            'NSMicrophoneUsageDescription': 'Record when requested.',
            'NSLocalNetworkUsageDescription': 'Connect to your paired desktop.'}


def ipa_fixture(path, info=None, commands=b'', extra=None):
    # A little-endian ARM64 MH_EXECUTE header with optional load commands.
    binary = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2,
                         1 if commands else 0, len(commands), 0, 0) + commands
    with zipfile.ZipFile(path, 'w') as archive:
        archive.writestr('Payload/AsterionVeyra.app/Info.plist', plistlib.dumps(info or info_fixture()))
        archive.writestr('Payload/AsterionVeyra.app/AsterionVeyra', binary)
        for name, content in (extra or {}).items():
            archive.writestr(name, content)


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(spec.origin and Path(spec.origin).exists(),
                        'Source renderer is not implemented')
        self.source = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.source)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'app.ipa'
        ipa_fixture(self.path)

    def render(self):
        return self.source.render_source(self.path, 40, 'a' * 40, '2026-11-08T13:00:00Z')

    def test_exact_verified_ipa_metadata_and_classic_source_schema(self):
        feed = self.render()
        self.assertEqual(feed['name'], 'Asterion Veyra')
        self.assertEqual(feed['identifier'], 'dev.asterionveyra.source')
        self.assertEqual(feed['sourceURL'], 'https://raw.githubusercontent.com/R347H4CK3R/GhostAI/sidestore-source/source.json')
        self.assertEqual(len(feed['apps']), 1)
        app = feed['apps'][0]
        self.assertEqual(app['bundleIdentifier'], 'dev.asterionveyra.assistant')
        self.assertEqual(app['developerName'], 'R347H4CK3R')
        self.assertNotIn('marketplaceID', app)
        self.assertEqual(app['appPermissions'], {'entitlements': [], 'privacy': {
            'NSMicrophoneUsageDescription': 'Record when requested.',
            'NSLocalNetworkUsageDescription': 'Connect to your paired desktop.'}})
        version = app['versions'][0]
        self.assertEqual(version, {
            'version': '0.3.4', 'buildVersion': '40',
            'date': '2026-11-08T13:00:00Z', 'minOSVersion': '26.0',
            'downloadURL': 'https://github.com/R347H4CK3R/GhostAI/releases/download/ios-build-40/AsterionVeyra-unsigned.ipa',
            'size': self.path.stat().st_size,
            'sha256': hashlib.sha256(self.path.read_bytes()).hexdigest()})
        self.assertEqual(app['iconURL'], 'https://raw.githubusercontent.com/R347H4CK3R/GhostAI/' + 'a' * 40 + '/App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png')
        self.assertEqual(feed['news'], [])

    def test_invalid_identity_version_platform_minimum_and_privacy_fail_closed(self):
        for key, value in [('CFBundleVersion', '39'), ('CFBundleIdentifier', 'other.app'),
                           ('CFBundleShortVersionString', ''), ('CFBundleShortVersionString', 'bad\nversion'),
                           ('CFBundleSupportedPlatforms', ['iPhoneSimulator']),
                           ('MinimumOSVersion', '25.0'), ('MinimumOSVersion', 'bad'),
                           ('NSMicrophoneUsageDescription', ''), ('NSMicrophoneUsageDescription', 1),
                           ('CFBundleExecutable', '../other')]:
            with self.subTest(key=key, value=value):
                ipa_fixture(self.path, dict(info_fixture(), **{key: value}))
                with self.assertRaises(ValueError):
                    self.render()

    def test_signed_or_extension_payloads_require_explicit_permission_support(self):
        for extra in [{'Payload/Other.app/Info.plist': b'bad'},
                      {'Payload/AsterionVeyra.app/PlugIns/Widget.appex/Info.plist': b'bad'},
                      {'Payload/AsterionVeyra.app/embedded.mobileprovision': b'bad'},
                      {'Payload/AsterionVeyra.app/_CodeSignature/CodeResources': b'bad'}]:
            with self.subTest(extra=extra):
                ipa_fixture(self.path, extra=extra)
                with self.assertRaises(ValueError):
                    self.render()
        ipa_fixture(self.path, commands=struct.pack('<4I', 0x1d, 16, 48, 1))
        with self.assertRaises(ValueError):
            self.render()

    def test_noncanonical_symlink_or_nested_app_zip_entries_are_rejected(self):
        for name in ('Payload/AsterionVeyra.app/../../Other.app/Info.plist',
                     'Payload/AsterionVeyra.app/Watch/Other.app/Info.plist',
                     '/Payload/AsterionVeyra.app/extra',
                     'Payload/AsterionVeyra.app//extra',
                     'Payload/AsterionVeyra.app/./extra',
                     'Payload/AsterionVeyra.app/Watch/Other.APP/Info.plist'):
            with self.subTest(name=name):
                ipa_fixture(self.path, extra={name: b'unadvertised permissions'})
                with self.assertRaises(ValueError):
                    self.render()
        ipa_fixture(self.path)
        with zipfile.ZipFile(self.path, 'a') as archive:
            link = zipfile.ZipInfo('Payload/AsterionVeyra.app/link')
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(link, '../Other.app')
        with self.assertRaises(ValueError):
            self.render()

    def test_bad_binary_or_load_command_fails_closed(self):
        for binary in [b'', b'not macho', struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 1, 8, 0, 0),
                       struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 1, 8, 0, 0) + struct.pack('<2I', 1, 0)]:
            with self.subTest(binary=binary):
                with zipfile.ZipFile(self.path, 'w') as archive:
                    archive.writestr('Payload/AsterionVeyra.app/Info.plist', plistlib.dumps(info_fixture()))
                    archive.writestr('Payload/AsterionVeyra.app/AsterionVeyra', binary)
                with self.assertRaises(ValueError):
                    self.render()

    def test_source_history_rejects_rollback_identity_or_provenance_mismatch(self):
        feed = self.render()
        provenance = self.source.make_provenance(feed, 123, 2, 'a' * 40)
        self.source.validate_previous(feed, provenance, 41)
        for build in (40, 39):
            with self.assertRaises(ValueError):
                self.source.validate_previous(feed, provenance, build)
        for mutate in (lambda f: f.update(identifier='other'),
                       lambda f: f['apps'][0]['versions'][0].update(sha256='b' * 64),
                       lambda f: f['apps'][0]['versions'][0].update(downloadURL='https://evil.test/app.ipa')):
            changed = json.loads(json.dumps(feed))
            mutate(changed)
            with self.assertRaises(ValueError):
                self.source.validate_previous(changed, provenance, 41)


if __name__ == '__main__':
    unittest.main()
