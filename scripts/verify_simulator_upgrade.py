#!/usr/bin/env python3
"""Bounded real install-over-existing gate. Requires macOS, Xcode 26 and XcodeGen.

No uninstall, product test hook, model request, permission grant, or account access.
Only the newly created simulator and this invocation's child processes are cleaned up.
Exit 0: verified; 1: failed; 2: unsupported infrastructure (never a passing CI skip).
"""
import argparse
import copy
from datetime import datetime, timedelta, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import signal
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
BASELINE_COMMIT = '8074b807a864a79e659200ee9521141c3c00df98'
BUNDLE_ID = 'dev.asterionveyra.assistant'
FIXTURE = ROOT / 'Tests/Fixtures/upgrade-state-v1.json'
STATE_PATH = Path('Library/Application Support/AsterionVeyra/state.json')
PREFERENCES_PATH = Path(f'Library/Preferences/{BUNDLE_ID}.plist')
CONTINUITY_PATH = Path('Library/Application Support/AsterionVeyra/upgrade-continuity-v1.txt')
CONTINUITY_ID = uuid.uuid4().hex
PREFERENCE_KEY = 'diagnostics.lastSuccessfulReport.v1'
# Production treats future dates as due. Seed a recent whole-second UTC date once
# per invocation and pass that exact value to the native preservation assertion.
# Voice settings are session-only in the baseline and are intentionally not fabricated here.
PREFERENCE_DATE = datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0) - timedelta(minutes=1)
TARGETS = {'AsterionVeyraTests', 'AsterionVeyraUITests'}


class UnsupportedInfrastructure(RuntimeError):
    pass


def validate_fixture(data):
    value = json.loads(data)
    if set(value) != {'version', 'notes', 'chats'} or value['version'] != 1:
        raise ValueError('Fixture must use the pinned release SavedState v1 schema')
    if len(value['notes']) != 2 or len(value['chats']) != 2:
        raise ValueError('Fixture needs two project notes and a two-message conversation')
    for kind, date_key, fields in [
        ('notes', 'savedAt', {'id', 'project', 'text', 'source', 'savedAt'}),
        ('chats', 'date', {'id', 'project', 'role', 'text', 'date'}),
    ]:
        ids = set()
        for record in value[kind]:
            if set(record) != fields or not all(isinstance(record[k], str) and record[k] for k in fields - {date_key}):
                raise ValueError('Invalid prior-format record fields')
            identity = uuid.UUID(record['id'])
            if identity in ids:
                raise ValueError('Duplicate fixture identity')
            ids.add(identity)
            date = record[date_key]
            if type(date) not in (int, float) or not math.isfinite(date):
                raise ValueError('Dates must be Swift reference-date seconds')
            if not record['text'].startswith('Upgrade fixture:'):
                raise ValueError('Only explicitly synthetic fixture text is allowed')
    if {n['project'] for n in value['notes']} != {'General', 'upgrade/second-project'}:
        raise ValueError('Fixture must cover two independent projects')
    if [c['role'] for c in value['chats']] != ['user', 'assistant']:
        raise ValueError('Fixture must contain both conversation roles')
    return value


def seed_container(container):
    data = FIXTURE.read_bytes()
    validate_fixture(data)
    state, preferences, marker = container / STATE_PATH, container / PREFERENCES_PATH, container / CONTINUITY_PATH
    # Never overwrite a file, even if a mistakenly selected container belongs to another run.
    if state.exists() or preferences.exists() or marker.exists():
        raise ValueError('Refusing to seed an existing state or preferences file')
    state.parent.mkdir(parents=True, exist_ok=True)
    preferences.parent.mkdir(parents=True, exist_ok=True)
    state.write_bytes(data)
    preferences.write_bytes(plistlib.dumps({PREFERENCE_KEY: PREFERENCE_DATE}, fmt=plistlib.FMT_BINARY))
    marker.write_text(CONTINUITY_ID, encoding='ascii')


def verify_container(container):
    data = (container / STATE_PATH).read_bytes()
    if data != FIXTURE.read_bytes():
        raise ValueError('Prior state bytes changed or were replaced during upgrade')
    value = validate_fixture(data)
    preferences = plistlib.loads((container / PREFERENCES_PATH).read_bytes())
    if preferences.get(PREFERENCE_KEY) != PREFERENCE_DATE:
        raise ValueError('Prior persisted diagnostics preference changed or disappeared')
    marker = (container / CONTINUITY_PATH).read_bytes()
    if marker != CONTINUITY_ID.encode('ascii'):
        raise ValueError('Prior installation fixture identity changed or was replaced')
    return {'state_sha256': hashlib.sha256(data).hexdigest(), 'notes': len(value['notes']),
            'chats': len(value['chats']), 'preference_preserved': True,
            'fixture_identity_preserved': True, 'fixture_identity_sha256': hashlib.sha256(marker).hexdigest()}


def verify_retained_container(previous, current):
    # iOS may relocate Application_Home during an update (Apple TN2285).
    # Verify the freshly resolved container, never copy/reseed data to make it pass.
    return dict(verify_container(current), container_path_changed=previous != current)


def select_simulator(runtime_listing, device_listing):
    def version(value):
        return tuple(int(n) for n in value.split('.'))
    runtimes = [r for r in runtime_listing.get('runtimes', [])
                if r.get('isAvailable') and 'ios' in r.get('identifier', '').lower()
                and str(r.get('version', '')).split('.')[0] == '26']
    for runtime in sorted(runtimes, key=lambda r: version(r['version']), reverse=True):
        types = runtime.get('supportedDeviceTypes')
        if types is None:
            numbers = (version(runtime['version']) + (0, 0))[:3]
            packed = (numbers[0] << 16) + (numbers[1] << 8) + numbers[2]
            types = [d for d in device_listing.get('devicetypes', [])
                     if d.get('minRuntimeVersion', 0) <= packed <= d.get('maxRuntimeVersion', 0xFFFFFFFF)]
        phones = [d for d in types if d.get('name', '').startswith('iPhone')]
        if phones:
            phone = sorted(phones, key=lambda d: tuple(int(n) for n in re.findall(r'\d+', d['name'])), reverse=True)[0]
            return runtime['identifier'], phone['identifier']
    raise UnsupportedInfrastructure('No available iOS 26 runtime with a compatible iPhone device type')


def configure_test_run(value):
    value = copy.deepcopy(value)
    if 'TestConfigurations' in value:
        targets = [(t.get('BlueprintName'), t) for c in value['TestConfigurations'] for t in c.get('TestTargets', [])]
    else:
        targets = [(name, value[name]) for name in TARGETS if name in value]
    found = set()
    for name, target in targets:
        if name in TARGETS:
            found.add(name)
            target.setdefault('EnvironmentVariables', {})['ASTERION_UPGRADE_SMOKE'] = '1'
            target['EnvironmentVariables']['ASTERION_UPGRADE_PREFERENCE_EPOCH'] = str(
                int(PREFERENCE_DATE.replace(tzinfo=timezone.utc).timestamp()))
            target['EnvironmentVariables']['ASTERION_UPGRADE_CONTINUITY_ID'] = CONTINUITY_ID
    if found != TARGETS:
        raise ValueError('Generated xctestrun does not contain both required upgrade test targets')
    return value


def app_metadata(app):
    value = plistlib.loads((app / 'Info.plist').read_bytes())
    if value.get('CFBundleIdentifier') != BUNDLE_ID:
        raise ValueError('Upgrade app bundle identity differs from the installed baseline')
    if 'iPhoneSimulator' not in value.get('CFBundleSupportedPlatforms', []):
        raise ValueError('Upgrade gate needs an actual iOS simulator app, not a device IPA')
    return {'bundle_id': value['CFBundleIdentifier'], 'version': str(value['CFBundleShortVersionString']),
            'build': str(value['CFBundleVersion'])}


def validate_test_summary(summary):
    if (summary.get('result') != 'Passed' or summary.get('passedTests') != 2
            or summary.get('failedTests') != 0 or summary.get('skippedTests') != 0
            or summary.get('totalTestCount') != 2):
        raise ValueError('Expected exactly two passing upgrade tests, with no failures or skips')


def candidate_provenance(root=ROOT):
    """Return only a revision and dirty boolean, never status paths or file contents."""
    try:
        head = subprocess.run(['git', 'rev-parse', '--verify', 'HEAD'], cwd=root,
                              capture_output=True, text=True, check=True, timeout=10).stdout.strip()
        if not re.fullmatch(r'[0-9a-fA-F]{40}|[0-9a-fA-F]{64}', head):
            raise ValueError('Unexpected Git revision')
        status = subprocess.run(['git', 'status', '--porcelain=v1', '-z', '--untracked-files=normal'],
                                cwd=root, capture_output=True, check=True, timeout=10).stdout
        return {'candidate_commit': head, 'candidate_dirty': bool(status),
                'candidate_provenance': 'local_git_head'}
    except (OSError, ValueError, subprocess.SubprocessError):
        return {'candidate_commit': None, 'candidate_dirty': None, 'candidate_provenance': 'unavailable'}


class Runner:
    termination_grace_seconds = 5

    def __init__(self, output, budget_seconds):
        self.output = output
        self.deadline = time.monotonic() + budget_seconds
        self.steps = []
        self.count = 0

    def terminate_owned_group(self, process):
        """Escalate only the owned group, keeping its leader unreaped until then."""
        if process.returncode is not None:
            raise RuntimeError('Cannot safely signal a group whose leader was already reaped')
        try:
            os.killpg(process.pid, signal.SIGTERM)
            # Reaping early permits PID reuse; probing zombie-only groups can report
            # EPERM on Darwin. Keep our leader reserved throughout the grace period.
            time.sleep(self.termination_grace_seconds)
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass  # Already gone. Never scan PIDs or signal another group.
        except PermissionError as denied:
            # Darwin excludes zombies from killpg and can return EPERM when every
            # member has exited. EPERM alone is NOT proof of successful cleanup.
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                raise denied
            deadline = time.monotonic() + self.termination_grace_seconds
            while True:
                # After reaping, only probe. Even if this PGID were reused, it must
                # never receive a real signal from us. Only ESRCH proves absence.
                try:
                    os.killpg(process.pid, 0)
                except ProcessLookupError:
                    return
                except PermissionError:
                    pass
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise denied
                time.sleep(min(0.05, remaining))
        process.wait(timeout=5)

    def run(self, args, *, cwd=ROOT, timeout=60, required=True, cleanup=False):
        self.count += 1
        args = [str(a) for a in args]
        log = self.output / f'{self.count:02d}-{Path(args[0]).name}.log'
        remaining = self.deadline - time.monotonic()
        if remaining <= 0 and not cleanup:
            raise TimeoutError('The total upgrade smoke budget was exhausted')
        limit = timeout if cleanup else min(timeout, max(1, remaining))
        print('+ ' + ' '.join(args), flush=True)
        start = time.monotonic()
        # Each command gets its own group. Timeout cleanup never signals other builds/jobs.
        with log.open('wb') as stream:
            process = subprocess.Popen(args, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
            timed_out = False
            try:
                code = process.wait(timeout=limit)
            except BaseException as error:
                timed_out = isinstance(error, subprocess.TimeoutExpired)
                self.terminate_owned_group(process)
                raise
            finally:
                self.steps.append({'command': args, 'log': log.name, 'exit_code': process.poll(),
                                   'timed_out': timed_out, 'seconds': round(time.monotonic() - start, 2)})
        output = log.read_text(errors='replace')
        if code and required:
            raise RuntimeError(f'Command failed ({code}); see {log.name}: {output[-3000:]}')
        return output, code

    def json(self, args, **kwargs):
        return json.loads(self.run(args, **kwargs)[0])


def launch_and_stop(runner, result, identifier, label, screenshot=False):
    result['stage'] = label
    # Cold iOS 26 simulators can spend over a minute initializing launch services.
    # This is one bounded attempt, still constrained by Runner's total deadline.
    runner.run(['xcrun', 'simctl', 'launch', '--terminate-running-process', identifier, BUNDLE_ID], timeout=180)
    time.sleep(3)
    if screenshot:
        runner.run(['xcrun', 'simctl', 'io', identifier, 'screenshot', runner.output / 'upgraded-app.png'])
    # simctl terminate fails if the app has already exited/crashed during this window.
    runner.run(['xcrun', 'simctl', 'terminate', identifier, BUNDLE_ID])


def verify_upgrade(runner, result, simulator):
    result['stage'] = 'infrastructure'
    if platform.system() != 'Darwin' or any(shutil.which(t) is None for t in ['xcrun', 'xcodebuild', 'xcodegen']):
        raise UnsupportedInfrastructure('Real upgrade verification requires macOS, Xcode 26 and XcodeGen')
    if not result.get('candidate_commit'):
        raise RuntimeError('Cannot verify an upgrade without the candidate Git revision')
    runtime, device_type = select_simulator(
        runner.json(['xcrun', 'simctl', 'list', 'runtimes', '-j']),
        runner.json(['xcrun', 'simctl', 'list', 'devicetypes', '-j']))
    result['runtime'] = runtime
    result['device_type'] = device_type
    result['stage'] = 'create_isolated_simulator'
    identifier = runner.run(['xcrun', 'simctl', 'create', 'Asterion upgrade ' + uuid.uuid4().hex[:8], device_type, runtime])[0].strip()
    uuid.UUID(identifier)  # Never act on an ambiguous or malformed device selector.
    simulator.append(identifier)
    result['simulator_id'] = identifier
    runner.run(['xcrun', 'simctl', 'bootstatus', identifier, '-b'], timeout=180)
    with tempfile.TemporaryDirectory(prefix='asterion-upgrade-') as directory:
        temporary = Path(directory)
        baseline = temporary / 'baseline'; baseline.mkdir()
        result['stage'] = 'build_pinned_baseline'
        _, exists = runner.run(['git', 'cat-file', '-e', BASELINE_COMMIT + '^{commit}'], required=False)
        if exists:
            runner.run(['git', 'fetch', '--no-tags', '--depth=1', 'origin', BASELINE_COMMIT], timeout=120)
        runner.run(['git', 'archive', '--format=tar', '--output=' + str(temporary / 'baseline.tar'), BASELINE_COMMIT])
        runner.run(['tar', '-xf', temporary / 'baseline.tar', '-C', baseline])
        runner.run(['xcodegen', 'generate'], cwd=baseline)
        old_build, new_build = temporary / 'old-build', temporary / 'new-build'
        common = ['-project', 'AsterionVeyra.xcodeproj', '-scheme', 'AsterionVeyra', '-configuration', 'Debug',
                  '-sdk', 'iphonesimulator', '-destination', 'platform=iOS Simulator,id=' + identifier,
                  '-destination-timeout', '120', 'CODE_SIGNING_ALLOWED=NO']
        runner.run(['xcodebuild', *common, '-derivedDataPath', old_build, 'CURRENT_PROJECT_VERSION=17', 'build'], cwd=baseline, timeout=420)
        result['stage'] = 'build_current_tests'
        runner.run(['xcodegen', 'generate'])
        build_number = os.environ.get('GITHUB_RUN_NUMBER', '18')
        runner.run(['xcodebuild', *common, '-derivedDataPath', new_build,
                    'CURRENT_PROJECT_VERSION=' + build_number, 'build-for-testing'], timeout=420)
        old_app = old_build / 'Build/Products/Debug-iphonesimulator/AsterionVeyra.app'
        new_app = new_build / 'Build/Products/Debug-iphonesimulator/AsterionVeyra.app'
        result['baseline_app'], result['current_app'] = app_metadata(old_app), app_metadata(new_app)
        if result['baseline_app']['version'] != '0.3.0' or result['baseline_app']['build'] != '17':
            raise ValueError('Pinned baseline is not the expected 0.3.0 build 17')
        if tuple(map(int, result['current_app']['version'].split('.'))) <= (0, 3, 0):
            raise ValueError('Current build must identify a newer release than the pinned baseline')

        def container():
            path = Path(runner.run(['xcrun', 'simctl', 'get_app_container', identifier, BUNDLE_ID, 'data'])[0].strip()).resolve()
            if identifier.lower() not in str(path).lower() or not path.is_dir():
                raise ValueError('Unexpected simulator data container path')
            return path

        result['stage'] = 'install_seed_baseline'
        runner.run(['xcrun', 'simctl', 'install', identifier, old_app])
        before = container()
        seed_container(before)
        result['fixture'] = verify_container(before)
        launch_and_stop(runner, result, identifier, 'launch_baseline')
        baseline_after_launch = container()
        result['baseline_post_launch'] = verify_retained_container(before, baseline_after_launch)
        result['stage'] = 'install_over_existing'
        # Intentionally no uninstall/reset/erase between these two installations.
        runner.run(['xcrun', 'simctl', 'install', identifier, new_app])
        after = container()
        result['post_install'] = verify_retained_container(baseline_after_launch, after)
        launch_and_stop(runner, result, identifier, 'launch_upgraded_app', screenshot=True)
        after_launch = container()
        result['post_launch'] = verify_retained_container(after, after_launch)
        result['stage'] = 'native_and_ui_readability'
        test_runs = list((new_build / 'Build/Products').glob('*.xctestrun'))
        if len(test_runs) != 1:
            raise ValueError('Expected exactly one current build xctestrun')
        original = test_runs[0]
        configured = original.with_name('Upgrade.xctestrun')
        configured.write_bytes(plistlib.dumps(configure_test_run(plistlib.loads(original.read_bytes()))))
        runner.run(['xcodebuild', 'test-without-building', '-xctestrun', configured,
                    '-destination', 'platform=iOS Simulator,id=' + identifier, '-destination-timeout', '120',
                    '-parallel-testing-enabled', 'NO', '-test-timeouts-enabled', 'YES',
                    '-default-test-execution-time-allowance', '90', '-maximum-test-execution-time-allowance', '120',
                    '-only-testing:AsterionVeyraTests/UpgradePersistenceTests/testInstalledUpgradeReadsPriorStateWithoutChangingBytes',
                    '-only-testing:AsterionVeyraUITests/UpgradeUITests/testRetainedChatNotesAndHomeIcon',
                    '-resultBundlePath', runner.output / 'Upgrade.xcresult'], timeout=360)
        summary = runner.json(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', runner.output / 'Upgrade.xcresult'])
        (runner.output / 'test-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
        validate_test_summary(summary)
        result['post_tests'] = verify_retained_container(after_launch, container())
        result['native_readability'] = 'passed'
        result['ui_readability'] = 'passed'
        result['home_icon_presence_and_launch'] = 'passed'
        result['home_icon_artwork'] = 'requires_visual_screenshot_review'
        result['stage'] = 'complete'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'upgrade-results')
    parser.add_argument('--budget-seconds', type=int, default=1080)
    args = parser.parse_args(argv)
    output = args.output.resolve()
    started = time.monotonic()
    # Snapshot before our output directory or build steps can change dirty state.
    provenance = candidate_provenance()
    # Refuse to reuse a previous run's evidence directory.
    output.mkdir(parents=True, exist_ok=False)
    runner = Runner(output, args.budget_seconds)
    runner.deadline = started + args.budget_seconds
    result = {'status': 'running', 'baseline_commit': BASELINE_COMMIT,
              **provenance, 'budget_seconds': args.budget_seconds,
              'model_inference': 'not_tested', 'voice_audio': 'not_tested',
              'home_icon_artwork': 'not_tested',
              'device_signing_and_keychain': 'not_tested'}
    simulator = []
    exit_code = 1
    try:
        verify_upgrade(runner, result, simulator)
        result['status'] = 'passed'
        exit_code = 0
    except UnsupportedInfrastructure as error:
        result.update(status='unsupported_infrastructure', error=str(error))
        exit_code = 2
    except (Exception, KeyboardInterrupt) as error:
        result.update(status='failed', error=f'{type(error).__name__}: {error}')
    finally:
        # Best-effort diagnostics and evidence, bounded separately so timeout still leaves a report.
        if simulator:
            predicate = ('process == "AsterionVeyra" OR '
                         '((process == "SpringBoard" OR process == "runningboardd" OR process == "launchd") AND '
                         f'(eventMessage CONTAINS[c] "{BUNDLE_ID}" OR eventMessage CONTAINS[c] "AsterionVeyra"))')
            commands = []
            if result['status'] != 'passed':
                commands.append((['xcrun', 'simctl', 'io', simulator[0], 'screenshot', output / 'failure-screen.png'], 10))
            commands.extend([
                (['xcrun', 'simctl', 'spawn', simulator[0], 'log', 'show', '--last', '5m', '--info', '--style', 'compact', '--predicate', predicate], 10),
                (['xcrun', 'simctl', 'shutdown', simulator[0]], 20),
                (['xcrun', 'simctl', 'delete', simulator[0]], 20),
            ])
            for command, timeout in commands:
                try:
                    _, code = runner.run(command, required=False, cleanup=True, timeout=timeout)
                    if command[2] == 'delete':
                        result['isolated_simulator_deleted'] = code == 0
                except Exception as error:
                    result.setdefault('cleanup_warnings', []).append(str(error))
        if (output / 'Upgrade.xcresult').is_dir():
            try:
                runner.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', output / 'Upgrade.xcresult',
                            '--output-path', output / 'screenshots'], required=False, cleanup=True, timeout=30)
            except Exception as error:
                result.setdefault('cleanup_warnings', []).append(str(error))
        result['elapsed_seconds'] = round(time.monotonic() - started, 2)
        result['commands'] = runner.steps
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps({k: v for k, v in result.items() if k != 'commands'}, indent=2), flush=True)
    return exit_code


if __name__ == '__main__':
    raise SystemExit(main())
