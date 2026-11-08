"""Host-only tests for the upgrade gate, including deliberate preservation failures."""
import copy
import contextlib
import io
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('verify_simulator_upgrade', ROOT / 'scripts/verify_simulator_upgrade.py')
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class SimulatorUpgradeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_fixture_is_prior_format_and_has_two_scopes(self):
        value = check.validate_fixture(check.FIXTURE.read_bytes())
        self.assertEqual(value['version'], 1)
        self.assertEqual({n['project'] for n in value['notes']}, {'General', 'upgrade/second-project'})
        self.assertEqual([c['role'] for c in value['chats']], ['user', 'assistant'])

    def test_fixture_rejects_missing_chats_unknown_format_and_duplicate_ids(self):
        valid = json.loads(check.FIXTURE.read_bytes())
        invalid = [dict(valid, chats=[]), dict(valid, version=2), dict(valid, notes=[valid['notes'][0]] * 2)]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                check.validate_fixture(json.dumps(value).encode())

    def test_fixture_rejects_wrong_dates_and_extra_top_level_fields(self):
        valid = json.loads(check.FIXTURE.read_bytes())
        wrong = copy.deepcopy(valid); wrong['notes'][0]['savedAt'] = '2026-11-07'
        for value in [wrong, dict(valid, unexpected=True)]:
            with self.assertRaises(ValueError):
                check.validate_fixture(json.dumps(value).encode())

    def test_seed_preserves_exact_fixture_bytes_and_real_preference(self):
        check.seed_container(self.root)
        self.assertEqual((self.root / check.STATE_PATH).read_bytes(), check.FIXTURE.read_bytes())
        prefs = plistlib.loads((self.root / check.PREFERENCES_PATH).read_bytes())
        self.assertEqual(prefs[check.PREFERENCE_KEY], check.PREFERENCE_DATE)
        self.assertEqual(check.verify_container(self.root)['notes'], 2)

    def test_seed_refuses_existing_state_or_preferences(self):
        for relative in [check.STATE_PATH, check.PREFERENCES_PATH]:
            root = self.root / str(len(list(self.root.iterdir())))
            path = root / relative; path.parent.mkdir(parents=True); path.write_bytes(b'preserve')
            with self.assertRaises(ValueError):
                check.seed_container(root)
            self.assertEqual(path.read_bytes(), b'preserve')
            other = check.PREFERENCES_PATH if relative == check.STATE_PATH else check.STATE_PATH
            self.assertFalse((root / other).exists())

    def test_preservation_fails_for_missing_or_rewritten_state(self):
        check.seed_container(self.root)
        path = self.root / check.STATE_PATH
        path.write_bytes(json.dumps(json.loads(path.read_bytes())).encode())
        with self.assertRaisesRegex(ValueError, 'bytes'):
            check.verify_container(self.root)
        path.unlink()
        with self.assertRaises((ValueError, FileNotFoundError)):
            check.verify_container(self.root)

    def test_preferences_are_compared_semantically_not_as_plist_bytes(self):
        check.seed_container(self.root)
        path = self.root / check.PREFERENCES_PATH
        value = plistlib.loads(path.read_bytes()); value['unrelated-system-key'] = True
        path.write_bytes(plistlib.dumps(value, fmt=plistlib.FMT_XML))
        check.verify_container(self.root)
        value[check.PREFERENCE_KEY] = 'wrong type'
        path.write_bytes(plistlib.dumps(value))
        with self.assertRaisesRegex(ValueError, 'preference'):
            check.verify_container(self.root)

    def test_selects_latest_available_ios26_runtime_and_compatible_iphone(self):
        data = {'runtimes': [
            {'identifier': 'ios26', 'version': '26.0', 'isAvailable': True, 'supportedDeviceTypes': [{'identifier': 'iphone16', 'name': 'iPhone 16'}]},
            {'identifier': 'ios26.2', 'version': '26.2', 'isAvailable': True, 'supportedDeviceTypes': [{'identifier': 'iphone17', 'name': 'iPhone 17'}]},
            {'identifier': 'ios27', 'version': '27.0', 'isAvailable': True, 'supportedDeviceTypes': [{'identifier': 'iphone18', 'name': 'iPhone 18'}]},
        ]}
        self.assertEqual(check.select_simulator(data, {'devicetypes': []}), ('ios26.2', 'iphone17'))

    def test_unavailable_runtime_or_missing_compatible_phone_is_unsupported(self):
        with self.assertRaises(check.UnsupportedInfrastructure):
            check.select_simulator({'runtimes': []}, {'devicetypes': []})
        runtime = {'identifier': 'ios26', 'version': '26.0', 'isAvailable': True, 'supportedDeviceTypes': []}
        with self.assertRaises(check.UnsupportedInfrastructure):
            check.select_simulator({'runtimes': [runtime]}, {'devicetypes': []})

    def test_runtime_selection_falls_back_to_device_minimum_runtime(self):
        runtime = {'identifier': 'ios26', 'version': '26.0', 'isAvailable': True}
        types = {'devicetypes': [{'identifier': 'phone', 'name': 'iPhone 16', 'minRuntimeVersion': 26 << 16}]}
        self.assertEqual(check.select_simulator({'runtimes': [runtime]}, types), ('ios26', 'phone'))

    def test_only_two_upgrade_test_targets_receive_environment(self):
        value = {'TestConfigurations': [{'TestTargets': [
            {'BlueprintName': 'AsterionVeyraTests', 'EnvironmentVariables': {'EXISTING': '1'}},
            {'BlueprintName': 'AsterionVeyraUITests', 'UITargetAppEnvironmentVariables': {'EXISTING': '2'}},
        ]}], '__xctestrun_metadata__': {'FormatVersion': 2}}
        patched = check.configure_test_run(value)
        for target in patched['TestConfigurations'][0]['TestTargets']:
            self.assertEqual(target['EnvironmentVariables']['ASTERION_UPGRADE_SMOKE'], '1')
        self.assertEqual(patched['TestConfigurations'][0]['TestTargets'][0]['EnvironmentVariables']['EXISTING'], '1')
        self.assertNotIn('ASTERION_UPGRADE_SMOKE', value['TestConfigurations'][0]['TestTargets'][0]['EnvironmentVariables'])

    def test_legacy_xctestrun_supported_and_missing_target_rejected(self):
        value = {'AsterionVeyraTests': {}, 'AsterionVeyraUITests': {}}
        self.assertEqual(check.configure_test_run(value)['AsterionVeyraTests']['EnvironmentVariables']['ASTERION_UPGRADE_SMOKE'], '1')
        with self.assertRaises(ValueError):
            check.configure_test_run({'TestConfigurations': []})
        with self.assertRaises(ValueError):
            check.configure_test_run({'AsterionVeyraTests': {}})

    def test_app_metadata_rejects_different_bundle_or_non_simulator(self):
        valid = {'CFBundleIdentifier': check.BUNDLE_ID, 'CFBundleVersion': '18', 'CFBundleShortVersionString': '0.3.2', 'CFBundleSupportedPlatforms': ['iPhoneSimulator']}
        app = self.root / 'App.app'; app.mkdir()
        for value, passes in [(valid, True), (dict(valid, CFBundleIdentifier='wrong'), False), (dict(valid, CFBundleSupportedPlatforms=['iPhoneOS']), False)]:
            (app / 'Info.plist').write_bytes(plistlib.dumps(value))
            if passes:
                self.assertEqual(check.app_metadata(app)['build'], '18')
            else:
                with self.assertRaises(ValueError):
                    check.app_metadata(app)

    def test_result_requires_both_native_and_ui_tests_and_no_skips(self):
        summary = {'result': 'Passed', 'passedTests': 2, 'failedTests': 0, 'skippedTests': 0, 'totalTestCount': 2}
        check.validate_test_summary(summary)
        for invalid in [dict(summary, passedTests=0), dict(summary, skippedTests=2), dict(summary, result='Failed'), dict(summary, totalTestCount=1)]:
            with self.assertRaises(ValueError):
                check.validate_test_summary(invalid)


    def test_failed_command_is_logged_and_does_not_become_success(self):
        runner = check.Runner(self.root, 10)
        with self.assertRaisesRegex(RuntimeError, 'Command failed'):
            runner.run([sys.executable, '-c', 'print("synthetic failure"); raise SystemExit(3)'])
        self.assertEqual(runner.steps[0]['exit_code'], 3)
        self.assertIn('synthetic failure', (self.root / runner.steps[0]['log']).read_text())

    def test_timed_out_owned_command_is_recorded(self):
        runner = check.Runner(self.root, 10)
        with self.assertRaises(subprocess.TimeoutExpired):
            runner.run([sys.executable, '-c', 'import time; time.sleep(10)'], timeout=0.05)
        self.assertEqual(len(runner.steps), 1)
        self.assertTrue(runner.steps[0]['timed_out'])
        self.assertNotEqual(runner.steps[0]['exit_code'], 0)

    @unittest.skipUnless(os.name == 'posix', 'Process-group cleanup requires POSIX')
    def test_timeout_kills_term_ignoring_descendant_after_leader_exits(self):
        heartbeat = self.root / 'heartbeat'
        group_file = self.root / 'owned-group'
        child_code = (
            'import os, signal, time; from pathlib import Path; '
            'signal.signal(signal.SIGTERM, signal.SIG_IGN); '
            f'path = Path({str(heartbeat)!r}); '
            '\nwhile True: path.write_text(str(time.monotonic_ns())); time.sleep(0.01)'
        )
        parent_code = (
            'import os, subprocess, sys, time; from pathlib import Path; '
            f'Path({str(group_file)!r}).write_text(str(os.getpgrp())); '
            f'subprocess.Popen([sys.executable, "-c", {child_code!r}]); '
            'time.sleep(30)'
        )
        runner = check.Runner(self.root, 10)
        try:
            with patch.object(check.Runner, 'termination_grace_seconds', 0.1, create=True):
                with self.assertRaises(subprocess.TimeoutExpired):
                    runner.run([sys.executable, '-c', parent_code], timeout=0.6)
            self.assertTrue(heartbeat.exists(), 'The descendant must run before timeout')
            time.sleep(0.05)
            after = heartbeat.read_text()
            time.sleep(0.1)
            self.assertEqual(heartbeat.read_text(), after, 'A descendant survived after its leader exited')
            self.assertTrue(runner.steps[0]['timed_out'])
        finally:
            # Ensure a failing regression never leaks the synthetic child it created.
            if group_file.exists():
                try:
                    os.killpg(int(group_file.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_local_candidate_provenance_records_head_and_dirty_without_paths(self):
        repo = self.root / 'repo'; repo.mkdir()
        def git(*args):
            return subprocess.run(['git', *args], cwd=repo, capture_output=True, text=True, check=True).stdout.strip()
        git('init')
        (repo / 'tracked.txt').write_text('synthetic fixture')
        git('add', 'tracked.txt')
        git('-c', 'user.name=Upgrade Fixture', '-c', 'user.email=fixture@example.invalid',
            '-c', 'commit.gpgsign=false', 'commit', '-m', 'Synthetic fixture')
        head = git('rev-parse', 'HEAD')
        with patch.dict(check.os.environ, {'GITHUB_SHA': 'f' * 40}):
            clean = check.candidate_provenance(repo)
        self.assertEqual(clean['candidate_commit'], head)
        self.assertFalse(clean['candidate_dirty'])
        private_name = 'sensitive-local-file-name.txt'
        (repo / private_name).write_text('synthetic content must not be reported')
        dirty = check.candidate_provenance(repo)
        self.assertTrue(dirty['candidate_dirty'])
        self.assertNotIn(private_name, json.dumps(dirty))
        self.assertNotIn(str(repo), json.dumps(dirty))
        self.assertNotIn('synthetic content', json.dumps(dirty))

    def test_linux_is_explicit_nonpassing_infrastructure_result(self):
        output = self.root / 'unsupported'
        with patch.object(check.platform, 'system', return_value='Linux'), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(check.main(['--output', str(output)]), 2)
        report = json.loads((output / 'result.json').read_bytes())
        self.assertEqual(report['status'], 'unsupported_infrastructure')
        self.assertEqual(report['model_inference'], 'not_tested')
        self.assertEqual(report['commands'], [])

    def test_reusing_evidence_directory_is_refused(self):
        with self.assertRaises(FileExistsError):
            check.main(['--output', str(self.root)])


if __name__ == '__main__':
    unittest.main()
