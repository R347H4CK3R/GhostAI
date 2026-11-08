#!/usr/bin/env python3
"""Create the main CI test simulator and shut down only that recorded device.

Never select, erase, delete or shut down preexisting/unrelated simulators. A
failed/uncertain command fails the step without retrying a simulator mutation.
"""
import argparse
import json
from pathlib import Path
import re
import uuid

from verify_simulator_upgrade import Runner, select_simulator


def owned_device(runner, ownership, identifier):
    """Validate selectors and recheck creation identity against current simctl state."""
    if (not re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', identifier)
            or identifier != ownership.get('simulator_id')
            or not re.fullmatch(r'Asterion CI [0-9a-f]{32}', ownership.get('name', ''))):
        raise ValueError('Refusing a missing, ambiguous or unowned simulator selector')
    listing = runner.json(['xcrun', 'simctl', 'list', 'devices', '-j'], timeout=15)
    matches = [(runtime, device) for runtime, devices in listing['devices'].items()
               for device in devices if device.get('udid') == identifier]
    if len(matches) != 1:
        raise ValueError('Owned simulator is missing or ambiguous')
    runtime, device = matches[0]
    if (runtime != ownership.get('runtime') or device.get('name') != ownership['name']
            or device.get('deviceTypeIdentifier') != ownership.get('device_type')
            or device.get('isAvailable') is not True):
        raise ValueError('Simulator does not match this workflow creation record')
    return device


def create_and_boot(runner, github_env):
    runtime, device_type = select_simulator(
        runner.json(['xcrun', 'simctl', 'list', 'runtimes', '-j']),
        runner.json(['xcrun', 'simctl', 'list', 'devicetypes', '-j']))
    name = 'Asterion CI ' + uuid.uuid4().hex
    identifier = runner.run(['xcrun', 'simctl', 'create', name, device_type, runtime])[0].strip()
    ownership = {'simulator_id': identifier, 'name': name, 'runtime': runtime, 'device_type': device_type}
    # Save ownership and export the exact identifier before boot. The always-run
    # handoff can then inspect this owned device even when its boot times out.
    device = owned_device(runner, ownership, identifier)
    if device.get('state') != 'Shutdown':
        raise ValueError('A newly created CI simulator must be Shutdown')
    with (runner.output / 'ownership.json').open('x') as stream:
        json.dump(ownership, stream, indent=2)
        stream.write('\n')
    with github_env.open('a') as stream:
        stream.write('SIMULATOR_ID=' + identifier + '\n')
    # Keep the existing six-minute workflow step allowance, with time reserved
    # for selection/ownership checks. Upgrade boot keeps its separate 180s cap.
    runner.run(['xcrun', 'simctl', 'bootstatus', identifier, '-b'], timeout=300)
    return ownership


def shutdown_owned(runner, ownership, identifier):
    before = owned_device(runner, ownership, identifier).get('state')
    if before not in {'Booted', 'Booting', 'Shutdown', 'Shutting Down'}:
        raise ValueError('Refusing shutdown from an unknown simulator state')
    if before in {'Booted', 'Booting'}:
        runner.run(['xcrun', 'simctl', 'shutdown', identifier], timeout=60)
    after = owned_device(runner, ownership, identifier).get('state')
    if after != 'Shutdown':
        raise RuntimeError('Owned simulator did not reach Shutdown; upgrade must not start')
    return {'simulator_id': identifier, 'state_before': before, 'state_after': after}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['boot', 'shutdown'])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--github-env', type=Path)
    parser.add_argument('--simulator-id')
    args = parser.parse_args(argv)
    if args.action == 'boot' and args.github_env is None:
        parser.error('boot requires --github-env')
    if args.action == 'shutdown' and not args.simulator_id:
        parser.error('shutdown requires --simulator-id')
    output = args.output.resolve()
    logs = output if args.action == 'boot' else output / 'handoff'
    logs.mkdir(parents=True, exist_ok=False)
    runner = Runner(logs, 330 if args.action == 'boot' else 90)
    result = {'status': 'running', 'action': args.action}
    code = 1
    try:
        if args.action == 'boot':
            result.update(create_and_boot(runner, args.github_env))
        else:
            ownership = json.loads((output / 'ownership.json').read_text())
            result.update(shutdown_owned(runner, ownership, args.simulator_id))
        result['status'] = 'passed'
        code = 0
    except (Exception, KeyboardInterrupt) as error:
        result.update(status='failed', error=f'{type(error).__name__}: {error}')
    finally:
        result['commands'] = runner.steps
        (logs / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2), flush=True)
    return code


if __name__ == '__main__':
    raise SystemExit(main())
