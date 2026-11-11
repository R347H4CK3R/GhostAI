#!/usr/bin/env python3
"""Manual native evidence only. Never calls a publisher or impersonates GitHub."""
import argparse
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys

CONTROL = Path(__file__).resolve().parents[1]
SHA = 'e01f0b241818322daa661ecbd4c9f9cfdaabcde4'
TREE = '89507a6d99234659902035e0aea58e8e0e60d542'
sys.path.insert(0, str(CONTROL / 'scripts'))
from verify_simulator_upgrade import Runner


class StageRunner(Runner):
    cooperative = False

    def terminate_owned_group(self, process):
        if not self.cooperative:
            return super().terminate_owned_group(process)
        # This stage execs a cooperative Python leader. Signal only that leader;
        # it owns and unwinds the nested Runner sessions and simulator cleanup.
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=180)
            return
        except subprocess.TimeoutExpired:
            # Missing receipt remains a failure. Only our original group may
            # be forcefully terminated; never discover/kill unrelated processes.
            return super().terminate_owned_group(process)


def execute(stages, root, evidence):
    evidence.mkdir(parents=True, exist_ok=False)
    runner = StageRunner(evidence, 24 * 3600)
    results = []
    passed = True
    for stage in stages:
        dependencies = {r['name']: r['status'] for r in results}
        eligible = (stage.get('always') or
                    (dependencies.get(stage.get('after_success')) == 'passed') or
                    (passed and not stage.get('after_success')))
        result = {'name': stage['name'], 'status': 'skipped', 'deadline_seconds': stage['seconds']}
        if eligible:
            runner.cooperative = bool(stage.get('cooperative'))
            try:
                runner.run(['bash', '-euo', 'pipefail', '-c', stage['script']], cwd=root,
                           timeout=stage['seconds'])
                result['status'] = 'passed'
            except (Exception, KeyboardInterrupt) as error:
                result.update(status='failed', error=f'{type(error).__name__}: {error}')
                passed = False
            if stage.get('receipt'):
                try:
                    receipt_path = Path(os.path.expandvars(stage['receipt']))
                    receipt = json.loads(receipt_path.read_text())
                    result['cleanup_complete'] = receipt['cleanup_complete'] is True
                    if not result['cleanup_complete']:
                        raise ValueError('Entry cleanup was not confirmed')
                except Exception as error:
                    result.update(status='failed', cleanup_complete=False,
                                  cleanup_error=f'{type(error).__name__}: {error}')
                    passed = False
        results.append(result)
        (evidence / 'stages.json').write_text(json.dumps(results, indent=2) + '\n')
        (evidence / 'commands.json').write_text(json.dumps(runner.steps, indent=2) + '\n')
    return passed and all(r['status'] == 'passed' for r in results)


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True, timeout=120).strip()


def verify_source(root):
    if git(root, 'rev-parse', 'HEAD') != SHA or git(root, 'rev-parse', 'HEAD^{tree}') != TREE:
        raise ValueError('Candidate commit/tree mismatch')
    if git(root, 'status', '--porcelain', '--untracked-files=no'):
        raise ValueError('Tracked candidate source is modified')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['tls', 'native', 'package'])
    args = parser.parse_args()
    cancelled = False
    def interrupted(signum, frame):
        nonlocal cancelled
        if not cancelled:
            cancelled = True
            raise KeyboardInterrupt(f"Received signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    evidence = CONTROL / 'native-evidence'
    evidence.mkdir(exist_ok=False)
    status = {'phase':args.phase, 'status':'failed', 'tested_commit':SHA, 'tested_tree':TREE}
    try:
        status['config_commit'] = git(CONTROL, 'rev-parse', 'HEAD')
        status['config_tree'] = git(CONTROL, 'rev-parse', 'HEAD^{tree}')
        if git(CONTROL, 'status', '--porcelain', '--untracked-files=no'):
            raise ValueError('Configuration checkout is modified')
        if platform.system() != 'Darwin':
            raise RuntimeError('Unsupported infrastructure: macOS required')
        candidate = CONTROL / 'candidate'
        subprocess.run(['git', 'clone', '--no-hardlinks', '--no-checkout', str(CONTROL), str(candidate)], check=True, timeout=120)
        git(candidate, 'remote', 'set-url', 'origin', 'https://github.com/R347H4CK3R/GhostAI.git')
        git(candidate, 'fetch', '--no-tags', '--depth=1', 'origin', SHA)
        git(candidate, 'checkout', '--detach', SHA)
        verify_source(candidate)
        os.environ['NATIVE_CONTROL'] = str(CONTROL)
        os.environ['NATIVE_SIMULATOR_ENV'] = str(evidence / 'simulator.env')
        plans = json.loads((CONTROL / 'ci/codemagic_stages.json').read_text())
        success = execute(plans[args.phase], candidate, evidence / 'commands')
        verify_source(candidate)
        status['status'] = 'passed' if success else 'failed'
    except (Exception, KeyboardInterrupt) as error:
        status['error'] = f'{type(error).__name__}: {error}'
    finally:
        (evidence / 'result.json').write_text(json.dumps(status, indent=2) + '\n')
        print(json.dumps(status, indent=2), flush=True)
    return 0 if status['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
