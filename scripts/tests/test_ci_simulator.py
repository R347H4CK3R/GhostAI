"""Host regressions for the main-suite simulator's explicit ownership handoff."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))


class CISimulatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.identifier = '11111111-2222-3333-4444-555555555555'
        self.other = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        self.owned = {'simulator_id': self.identifier, 'name': 'Asterion CI 0123456789abcdef0123456789abcdef',
                      'runtime': 'com.apple.CoreSimulator.SimRuntime.iOS-26-2',
                      'device_type': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'}
        self.state = 'Booted'
        self.calls = []
        self.devices = [dict(udid=self.identifier, name=self.owned['name'], isAvailable=True,
                             deviceTypeIdentifier=self.owned['device_type']),
                        dict(udid=self.other, name='Unrelated iPhone', isAvailable=True,
                             deviceTypeIdentifier=self.owned['device_type'], state='Booted')]
        # Only the external simctl boundary is replaced. Ownership validation and
        # persisted reports execute unchanged; unexpected/mutating commands fail.
        self.check = self.load_check()

    def load_check(self):
        path = ROOT / 'scripts/ci_simulator.py'
        self.assertTrue(path.is_file(), 'CI needs an explicit owned-simulator lifecycle, not a preexisting UDID')
        spec = importlib.util.spec_from_file_location('ci_simulator', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def listing(self):
        devices = [dict(d, state=self.state) if d['udid'] == self.identifier else dict(d)
                   for d in self.devices]
        return {'devices': {self.owned['runtime']: devices}}

    def simctl_run(self, args, **options):
        self.calls.append((args, options))
        if args[:4] == ['xcrun', 'simctl', 'list', 'devices']:
            return json.dumps(self.listing()), 0
        if args == ['xcrun', 'simctl', 'shutdown', self.identifier]:
            self.state = 'Shutdown'
            return '', 0
        self.fail('Unexpected simulator operation: ' + repr(args))

    def runner(self):
        runner = self.check.Runner(self.root, 90)
        self.addCleanup(patch.stopall)
        patch.object(runner, 'run', side_effect=self.simctl_run).start()
        return runner

    def test_handoff_stops_only_matching_owned_device_and_verifies_shutdown(self):
        result = self.check.shutdown_owned(self.runner(), self.owned, self.identifier)
        self.assertEqual(result['state_before'], 'Booted')
        self.assertEqual(result['state_after'], 'Shutdown')
        self.assertEqual(result['simulator_id'], self.identifier)
        self.assertEqual([a[2] for a, _ in self.calls], ['list', 'shutdown', 'list'])
        self.assertEqual(self.devices[1]['state'], 'Booted')

    def test_already_shutdown_device_is_verified_without_mutation(self):
        self.state = 'Shutdown'
        self.check.shutdown_owned(self.runner(), self.owned, self.identifier)
        self.assertEqual([a[2] for a, _ in self.calls], ['list', 'list'])

    def test_invalid_or_mismatched_selector_is_rejected_before_simctl(self):
        for selector in ['all', 'booted', '', self.other]:
            with self.subTest(selector=selector), self.assertRaises(ValueError):
                self.check.shutdown_owned(self.runner(), self.owned, selector)
        self.assertEqual(self.calls, [])

    def test_missing_duplicate_or_renamed_owned_device_never_gets_shutdown(self):
        original = list(self.devices)
        for devices in [[], [original[0], original[0]],
                        [dict(original[0], name='Another job')],
                        [dict(original[0], deviceTypeIdentifier='different-type')],
                        [dict(original[0], isAvailable=False)]]:
            self.devices = devices
            self.calls = []
            with self.subTest(devices=devices), self.assertRaises(ValueError):
                self.check.shutdown_owned(self.runner(), self.owned, self.identifier)
            self.assertEqual([a[2] for a, _ in self.calls], ['list'])

    def test_unknown_state_fails_closed_without_shutdown(self):
        self.state = 'Creating'
        with self.assertRaises(ValueError):
            self.check.shutdown_owned(self.runner(), self.owned, self.identifier)
        self.assertEqual([a[2] for a, _ in self.calls], ['list'])

    def test_successful_shutdown_command_must_reach_shutdown_state(self):
        def stuck(args, **options):
            value = self.simctl_run(args, **options)
            self.state = 'Booted'
            return value
        runner = self.runner()
        with patch.object(runner, 'run', side_effect=stuck), self.assertRaisesRegex(RuntimeError, 'Shutdown'):
            self.check.shutdown_owned(runner, self.owned, self.identifier)
        self.assertEqual([a[2] for a, _ in self.calls], ['list', 'shutdown', 'list'])

    def test_uncertain_shutdown_is_not_retried_or_reported_as_success(self):
        def uncertain(args, **options):
            value = self.simctl_run(args, **options)
            if args[2] == 'shutdown':
                raise subprocess.TimeoutExpired(args, 60)
            return value
        runner = self.runner()
        with patch.object(runner, 'run', side_effect=uncertain), self.assertRaises(subprocess.TimeoutExpired):
            self.check.shutdown_owned(runner, self.owned, self.identifier)
        self.assertEqual([a[2] for a, _ in self.calls], ['list', 'shutdown'])

    def test_boot_records_created_identity_before_one_bounded_boot(self):
        output = self.root / 'created'; output.mkdir()
        runner = self.check.Runner(output, 330)
        env = self.root / 'github-env'
        calls = []
        def simctl(args, **options):
            calls.append((args, options))
            if args[2:4] == ['list', 'runtimes']:
                return json.dumps({'runtimes': [{'identifier': self.owned['runtime'], 'version': '26.2',
                    'isAvailable': True, 'supportedDeviceTypes': [{'name': 'iPhone 17 Pro',
                    'identifier': self.owned['device_type']}]}]}), 0
            if args[2:4] == ['list', 'devicetypes']:
                return '{"devicetypes": []}', 0
            if args[2] == 'create':
                self.devices[0]['name'] = args[3]
                return self.identifier + '\n', 0
            if args[2:4] == ['list', 'devices']:
                return json.dumps(self.listing()), 0
            if args == ['xcrun', 'simctl', 'bootstatus', self.identifier, '-b']:
                self.assertTrue((output / 'ownership.json').exists())
                self.assertEqual(env.read_text(), 'SIMULATOR_ID=' + self.identifier + '\n')
                raise subprocess.TimeoutExpired(args, options['timeout'])
            self.fail(repr(args))
        self.state = 'Shutdown'
        with patch.object(runner, 'run', side_effect=simctl), self.assertRaises(subprocess.TimeoutExpired):
            self.check.create_and_boot(runner, env)
        ownership = json.loads((output / 'ownership.json').read_text())
        self.assertEqual(ownership['simulator_id'], self.identifier)
        self.assertTrue(ownership['name'].startswith('Asterion CI '))
        self.assertEqual(sum(args[2] == 'bootstatus' for args, _ in calls), 1)
        self.assertLessEqual(calls[-1][1]['timeout'], 330)
        self.assertGreater(calls[-1][1]['timeout'], 180)
        self.assertFalse(any(args[2] in ['delete', 'shutdown'] for args, _ in calls))


if __name__ == '__main__':
    unittest.main()
