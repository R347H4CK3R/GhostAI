import argparse
import getpass
import json
from pathlib import Path
import sqlite3
import sys

from .core import Memory, Runner, load_plan


def main():
    parser = argparse.ArgumentParser(description='Asterion Veyra offline memory and bounded task plans')
    parser.add_argument('--db', type=Path, required=True, help='Explicit local SQLite file; parent directory must exist')
    commands = parser.add_subparsers(dest='command', required=True)
    remember = commands.add_parser('remember', help='Save an explicit offline memory')
    for name in ('project', 'source', 'text'):
        remember.add_argument('--' + name, required=True)
    search = commands.add_parser('search')
    search.add_argument('--project', required=True)
    search.add_argument('--query', default='')
    forget = commands.add_parser('forget')
    forget.add_argument('id')
    commands.add_parser('history')
    run = commands.add_parser('run', help='Execute an explicit JSON plan locally')
    run.add_argument('--workspace', type=Path, required=True)
    run.add_argument('--plan', type=Path, required=True)
    run.add_argument('--allow-writes', action='store_true')
    plan_cmd = commands.add_parser('plan', help='Propose a plan using a trusted local Ollama model; never executes')
    plan_cmd.add_argument('--project', required=True)
    plan_cmd.add_argument('--model', required=True)
    plan_cmd.add_argument('--goal', required=True)
    plan_cmd.add_argument('--trust-local-model', action='store_true', required=True, help='Confirm your loopback Ollama daemon/model is trusted and configured offline; it receives this project’s notes')
    export = commands.add_parser('export-memory', help='Encrypt selected memories for manual transfer')
    scope = export.add_mutually_exclusive_group(required=True)
    scope.add_argument('--project')
    scope.add_argument('--all-projects', action='store_true')
    export.add_argument('--output', type=Path, required=True)
    imp = commands.add_parser('import-memory', help='Merge an encrypted memory snapshot without deleting existing data')
    imp.add_argument('--input', type=Path, required=True)
    args = parser.parse_args()
    memory = None
    try:
        memory = Memory(args.db)
        if args.command == 'remember':
            result = {'id': memory.add(args.project, args.text, args.source)}
        elif args.command == 'search':
            result = memory.search(args.project, args.query)
        elif args.command == 'forget':
            result = {'deleted': memory.delete(args.id)}
        elif args.command == 'history':
            result = memory.tasks()
        elif args.command == 'plan':
            from .planner import generate_plan
            result = generate_plan(args.goal, args.project, args.model, memory)
        elif args.command == 'export-memory':
            from .sync import export_snapshot
            password = getpass.getpass('Encryption passphrase: ')
            if password != getpass.getpass('Confirm passphrase: '):
                raise ValueError('Passphrases do not match')
            count = export_snapshot(memory, args.output, password, project=args.project, all_projects=args.all_projects)
            result = {'exported': count, 'encrypted': True, 'path': str(args.output)}
        elif args.command == 'import-memory':
            from .sync import import_snapshot
            password = getpass.getpass('Decryption passphrase: ')
            result = import_snapshot(memory, args.input, password)
        else:
            with args.plan.open('rb') as handle:
                raw = handle.read(1_048_577)
            plan = load_plan(raw.decode('utf-8'))
            result = Runner(args.workspace, memory, allow_writes=args.allow_writes).run(plan)
        print(json.dumps(result, ensure_ascii=True, indent=2))
        return 0 if args.command != 'run' or result['status'] == 'completed' else 1
    except (OSError, ValueError, sqlite3.Error, EOFError) as error:
        print(json.dumps({'status': 'failed', 'error': str(error)}), file=sys.stderr)
        return 1
    finally:
        if memory is not None:
            memory.close()


if __name__ == '__main__':
    sys.exit(main())
