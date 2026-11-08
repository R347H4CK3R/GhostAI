import argparse
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
        else:
            with args.plan.open('rb') as handle:
                raw = handle.read(1_048_577)
            plan = load_plan(raw.decode('utf-8'))
            result = Runner(args.workspace, memory, allow_writes=args.allow_writes).run(plan)
        print(json.dumps(result, ensure_ascii=True, indent=2))
        return 0 if args.command != 'run' or result['status'] == 'completed' else 1
    except (OSError, ValueError, sqlite3.Error) as error:
        print(json.dumps({'status': 'failed', 'error': str(error)}), file=sys.stderr)
        return 1
    finally:
        if memory is not None:
            memory.close()


if __name__ == '__main__':
    sys.exit(main())
