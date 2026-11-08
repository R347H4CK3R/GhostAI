"""Host-only tests for the upgrade gate, including deliberate preservation failures."""
import copy
import contextlib
from datetime import datetime, timezone
import io
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

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

    def test_seeded_diagnostics_date_is_recent_and_not_in_the_future(self):
        check.seed_container(self.root)
        preferences = plistlib.loads((self.root / check.PREFERENCES_PATH).read_bytes())
        age = (datetime.now(timezone.utc).replace(tzinfo=None) - preferences[check.PREFERENCE_KEY]).total_seconds()
        self.assertGreaterEqual(age, 0, 'A future date makes production diagnostics due immediately')
        self.assertLess(age, 3 * 24 * 60 * 60, 'The seeded date must suppress the actual three-day schedule')

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

    def test_relocated_container_requires_retained_bytes_preferences_and_identity(self):
        before, after = self.root / 'old-uuid', self.root / 'new-uuid'
        before.mkdir()
        check.seed_container(before)
        shutil.copytree(before, after)
        shutil.rmtree(before)
        report = check.verify_retained_container(before, after)
        self.assertTrue(report['container_path_changed'])
        self.assertTrue(report['preference_preserved'])
        self.assertTrue(report['fixture_identity_preserved'])
        (after / check.STATE_PATH).write_bytes(b'changed state')
        with self.assertRaisesRegex(ValueError, 'state bytes'):
            check.verify_retained_container(before, after)

    def test_missing_or_replaced_fixture_identity_fails_even_with_matching_state(self):
        check.seed_container(self.root)
        marker = self.root / 'Library/Application Support/AsterionVeyra/upgrade-continuity-v1.txt'
        self.assertTrue(marker.is_file(), 'Seed the continuity marker only in the baseline')
        marker.write_bytes(b'not-the-original-fixture')
        with self.assertRaisesRegex(ValueError, 'identity'):
            check.verify_container(self.root)
        marker.unlink()
        with self.assertRaises(FileNotFoundError):
            check.verify_container(self.root)

    def test_seed_refuses_preexisting_continuity_marker_without_writing_state(self):
        marker = self.root / 'Library/Application Support/AsterionVeyra/upgrade-continuity-v1.txt'
        marker.parent.mkdir(parents=True)
        marker.write_bytes(b'preserve-existing-marker')
        with self.assertRaises(ValueError):
            check.seed_container(self.root)
        self.assertEqual(marker.read_bytes(), b'preserve-existing-marker')
        self.assertFalse((self.root / check.STATE_PATH).exists())

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

    def test_upgrade_records_preexisting_states_and_labels_boot_timeout(self):
        runner = Mock(output=self.root)
        identifier = '11111111-2222-3333-4444-555555555555'
        runtimes = {'runtimes': [{'identifier': 'ios26', 'version': '26.0', 'isAvailable': True,
                    'supportedDeviceTypes': [{'identifier': 'iphone17', 'name': 'iPhone 17'}]}]}
        devices = {'devices': {'ios26': [{'udid': 'other-device', 'state': 'Shutdown',
                                        'name': 'Unneeded private local name'}]}}
        def listing(args, **options):
            return {'runtimes': runtimes, 'devicetypes': {}, 'devices': devices}[args[3]]
        runner.json.side_effect = listing
        def run(args, **options):
            if args[2] == 'create':
                return identifier, 0
            if args[2] == 'bootstatus':
                raise subprocess.TimeoutExpired(args, options['timeout'])
            self.fail('Unexpected simulator operation: ' + repr(args))
        runner.run.side_effect = run
        result, owned = {'candidate_commit': 'a' * 40}, []
        with patch.object(check.platform, 'system', return_value='Darwin'), patch.object(check.shutil, 'which', return_value='/synthetic/tool'):
            with self.assertRaises(subprocess.TimeoutExpired):
                check.verify_upgrade(runner, result, owned)
        self.assertEqual(result['stage'], 'boot_isolated_simulator')
        self.assertEqual(result['simulators_before_upgrade'], [
            {'runtime': 'ios26', 'simulator_id': 'other-device', 'state': 'Shutdown'}])
        self.assertEqual(owned, [identifier])
        self.assertEqual(runner.run.call_count, 2, 'Do not retry uncertain boot or start a build')

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

    def test_native_targets_receive_the_exact_seeded_preference_timestamp(self):
        with patch.object(check, 'PREFERENCE_DATE', datetime(2026, 1, 2)):
            value = check.configure_test_run({'AsterionVeyraTests': {}, 'AsterionVeyraUITests': {}})
        for target in value.values():
            self.assertEqual(target['EnvironmentVariables'].get('ASTERION_UPGRADE_PREFERENCE_EPOCH'), '1767312000')
            self.assertEqual(target['EnvironmentVariables'].get('ASTERION_UPGRADE_CONTINUITY_ID'), check.CONTINUITY_ID)

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

    def test_cold_launch_has_bounded_headroom_and_still_requires_stop(self):
        runner = Mock(output=self.root)
        calls = []

        def simulate_simctl(args, **options):
            calls.append((args, options))
            if args[2] == 'launch' and options.get('timeout', 60) < 90:
                raise subprocess.TimeoutExpired(args, options.get('timeout', 60))
            return 'synthetic simulator response', 0

        runner.run.side_effect = simulate_simctl
        result = {}
        with patch.object(check.time, 'sleep'):
            check.launch_and_stop(runner, result, 'owned-simulator', 'launch_baseline')
        self.assertEqual(result['stage'], 'launch_baseline')
        self.assertEqual([args[2] for args, _ in calls], ['launch', 'terminate'])
        self.assertLessEqual(calls[0][1]['timeout'], 180)
        self.assertTrue(all('owned-simulator' in args for args, _ in calls))

    def test_uncertain_or_failed_launch_is_not_retried_or_reported_as_success(self):
        for error in [subprocess.TimeoutExpired('simctl launch', 180), RuntimeError('launch failed')]:
            runner = Mock(output=self.root)
            runner.run.side_effect = error
            result = {}
            with self.subTest(error=error), self.assertRaises(type(error)):
                check.launch_and_stop(runner, result, 'owned-simulator', 'launch_baseline')
            self.assertEqual(runner.run.call_count, 1)
            self.assertEqual(result['stage'], 'launch_baseline')

    def test_launch_failure_captures_scoped_diagnostics_and_stays_failed(self):
        output = self.root / 'failed-launch'
        runner = check.Runner(output, 10)
        calls = []

        def fail_launch(_, result, simulator):
            simulator.append('owned-simulator')
            result['stage'] = 'launch_baseline'
            raise subprocess.TimeoutExpired('synthetic launch', 180)

        def record(args, **options):
            calls.append((args, options))
            return '', 0

        with patch.object(check, 'Runner', return_value=runner), patch.object(runner, 'run', side_effect=record), patch.object(check, 'verify_upgrade', side_effect=fail_launch), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(check.main(['--output', str(output)]), 1)
        report = json.loads((output / 'result.json').read_text())
        self.assertEqual(report['status'], 'failed')
        self.assertEqual(report['stage'], 'launch_baseline')
        self.assertTrue(report['isolated_simulator_deleted'])
        screenshots = [args for args, _ in calls if 'screenshot' in args]
        self.assertEqual(len(screenshots), 1)
        logs = [args for args, _ in calls if '--predicate' in args]
        self.assertEqual(len(logs), 1)
        self.assertIn('runningboardd', logs[0][-1])
        self.assertIn(check.BUNDLE_ID, logs[0][-1])
        self.assertTrue(all('owned-simulator' in args for args, _ in calls))
        self.assertFalse(any('launch' in args for args, _ in calls), 'Failure diagnostics must not retry uncertain launch')
        self.assertLessEqual(sum(options['timeout'] for _, options in calls), 60)


    def test_failed_command_is_logged_and_does_not_become_success(self):
        runner = check.Runner(self.root, 10)
        with self.assertRaisesRegex(RuntimeError, 'Command failed'):
            runner.run([sys.executable, '-c', 'print("synthetic failure"); raise SystemExit(3)'])
        self.assertEqual(runner.steps[0]['exit_code'], 3)
        self.assertIn('synthetic failure', (self.root / runner.steps[0]['log']).read_text())

    def test_timed_out_owned_command_is_recorded(self):
        runner = check.Runner(self.root, 10)
        with patch.object(runner, 'termination_grace_seconds', 0.05), self.assertRaises(subprocess.TimeoutExpired):
            runner.run([sys.executable, '-c', 'import time; time.sleep(10)'], timeout=0.05)
        self.assertEqual(len(runner.steps), 1)
        self.assertTrue(runner.steps[0]['timed_out'])
        self.assertNotEqual(runner.steps[0]['exit_code'], 0)

    @unittest.skipUnless(os.name == 'posix', 'Process-group cleanup requires POSIX')
    def test_zombie_group_permission_error_needs_confirmed_disappearance(self):
        """A real child exits; only Darwin's zombie-group EPERM is simulated."""
        runner = check.Runner(self.root, 10)
        real_killpg = os.killpg
        real_popen = subprocess.Popen
        processes = []
        denied_probe = False

        def launch(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            processes.append(process)
            return process

        def darwin_killpg(group, requested_signal):
            nonlocal denied_probe
            if requested_signal == signal.SIGKILL:
                # The leader must still belong to us and be unreaped here.
                if hasattr(os, 'WNOWAIT'):
                    deadline = time.monotonic() + 2
                    while True:
                        exited = os.waitid(os.P_PID, group, os.WEXITED | os.WNOWAIT | os.WNOHANG)
                        if exited is not None or time.monotonic() >= deadline:
                            break
                        time.sleep(0.01)
                    self.assertIsNotNone(exited)
                raise PermissionError(1, 'simulated Darwin zombie-only group')
            if requested_signal == 0 and not denied_probe:
                denied_probe = True
                raise PermissionError(1, 'simulated transient zombie-only group')
            return real_killpg(group, requested_signal)

        try:
            with patch.object(runner, 'termination_grace_seconds', 0.05), patch.object(check.os, 'killpg', side_effect=darwin_killpg), patch.object(check.subprocess, 'Popen', side_effect=launch):
                with self.assertRaises(subprocess.TimeoutExpired):
                    runner.run([sys.executable, '-c', 'import time; time.sleep(10)'], timeout=0.05)
            self.assertTrue(denied_probe)
            self.assertEqual(runner.steps[0]['exit_code'], -signal.SIGTERM)
            self.assertTrue(runner.steps[0]['timed_out'])
        finally:
            # Synthetic child cleanup only, using the original system function.
            for process in processes:
                if process.returncode is None:
                    try:
                        real_killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=5)

    def test_permission_error_stays_failure_if_group_remains_or_cannot_be_reaped(self):
        for probe_result in [None, PermissionError(1, 'still uninspectable')]:
            with self.subTest(probe_result=probe_result):
                runner = check.Runner(self.root, 10)
                process = Mock(pid=123456, returncode=None)
                calls = []
                denied = PermissionError(1, 'synthetic signal denial')

                def signal_group(group, requested_signal):
                    calls.append((group, requested_signal))
                    if len(calls) == 1:
                        raise denied
                    self.assertEqual(requested_signal, 0, 'Never signal after reaping')
                    if isinstance(probe_result, Exception):
                        raise probe_result

                with patch.object(runner, 'termination_grace_seconds', 0.01), patch.object(check.os, 'killpg', side_effect=signal_group):
                    with self.assertRaises(PermissionError) as caught:
                        runner.terminate_owned_group(process)
                self.assertIs(caught.exception, denied)
                process.wait.assert_called_once_with(timeout=5)
                self.assertGreater(len(calls), 1)

        process = Mock(pid=123456, returncode=None)
        process.wait.side_effect = subprocess.TimeoutExpired('synthetic child', 5)
        denied = PermissionError(1, 'synthetic signal denial')
        with patch.object(check.os, 'killpg', side_effect=denied) as send:
            with self.assertRaises(PermissionError) as caught:
                runner.terminate_owned_group(process)
        self.assertIs(caught.exception, denied)
        self.assertEqual(send.call_count, 1, 'Do not probe or signal after an unreaped denial')

    def test_already_reaped_leader_is_never_signalled(self):
        runner = check.Runner(self.root, 10)
        process = Mock(pid=123456, returncode=0)
        with patch.object(check.os, 'killpg') as send:
            with self.assertRaisesRegex(RuntimeError, 'reaped'):
                runner.terminate_owned_group(process)
        send.assert_not_called()

    @unittest.skipUnless(os.name == 'posix', 'Process-group cleanup requires POSIX')
    def test_timeout_kills_term_ignoring_descendant_after_leader_exits(self):
        heartbeat = self.root / 'heartbeat'
        group_file = self.root / 'owned-group'
        stop_file = self.root / 'stop-descendant'
        child_code = (
            'import os, signal, time; from pathlib import Path; '
            'signal.signal(signal.SIGTERM, signal.SIG_IGN); '
            f'path = Path({str(heartbeat)!r}); '
            f'stop = Path({str(stop_file)!r}); deadline = time.monotonic() + 10; '
            '\nwhile not stop.exists() and time.monotonic() < deadline: '
            'path.write_text(str(time.monotonic_ns())); time.sleep(0.01)'
        )
        parent_code = (
            'import os, subprocess, sys, time; from pathlib import Path; '
            f'Path({str(group_file)!r}).write_text(str(os.getpgrp())); '
            f'subprocess.Popen([sys.executable, "-c", {child_code!r}]); '
            'time.sleep(30)'
        )
        runner = check.Runner(self.root, 10)
        signal_patch = patch.object(check.os, 'killpg', wraps=os.killpg)
        sent = signal_patch.start()
        self.addCleanup(signal_patch.stop)
        started = time.monotonic()
        try:
            with patch.object(check.Runner, 'termination_grace_seconds', 0.1, create=True):
                with self.assertRaises(subprocess.TimeoutExpired):
                    runner.run([sys.executable, '-c', parent_code], timeout=0.6)
            self.assertTrue(heartbeat.exists(), 'The descendant must run before timeout')
            time.sleep(0.05)
            after = heartbeat.read_text()
            time.sleep(0.1)
            self.assertLess(time.monotonic() - started, 8, 'Fixture must not self-expire during the assertion')
            self.assertEqual(heartbeat.read_text(), after, 'A descendant survived after its leader exited')
            self.assertTrue(runner.steps[0]['timed_out'])
        finally:
            # Never signal a saved PGID after Runner reaps it. A failing regression
            # can stop its synthetic child cooperatively; it also expires in 10 s.
            stop_file.write_text('stop')
        group = int(group_file.read_text())
        self.assertEqual([call.args for call in sent.call_args_list if call.args[1] != 0],
                         [(group, signal.SIGTERM), (group, signal.SIGKILL)],
                         'Do not send a third signal after reaping the owned group')

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
