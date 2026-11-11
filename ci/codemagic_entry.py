#!/usr/bin/env python3
"""Cooperative signal boundary around an unchanged candidate Python entry point."""
import argparse
import json
from pathlib import Path
import runpy
import signal
import sys


def cleanup_complete(result, upgrade=False):
    commands = result.get('commands')
    return (isinstance(commands, list) and all(c.get('exit_code') is not None for c in commands)
            and not result.get('cleanup_warnings')
            and (not upgrade or not result.get('simulator_id')
                 or result.get('isolated_simulator_deleted') is True))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('entry',type=Path)
    parser.add_argument('--receipt',type=Path,required=True)
    parser.add_argument('--result',type=Path,required=True)
    parser.add_argument('--upgrade',action='store_true')
    args, forwarded=parser.parse_known_args()
    cancelled=False
    def interrupt(signum, frame):
        nonlocal cancelled
        if not cancelled:
            cancelled=True
            raise KeyboardInterrupt(f'Received signal {signum}')
    signal.signal(signal.SIGTERM,interrupt)
    signal.signal(signal.SIGINT,interrupt)
    code=1
    receipt={'cleanup_complete':False}
    try:
        sys.path.insert(0,str(args.entry.resolve().parent))
        sys.argv=[str(args.entry),*forwarded]
        try:
            runpy.run_path(str(args.entry),run_name='__main__')
            code=0
        except SystemExit as error:
            code=error.code if isinstance(error.code,int) else 1
    except (Exception,KeyboardInterrupt) as error:
        receipt['error']=f'{type(error).__name__}: {error}'
    finally:
        try:
            result=json.loads(args.result.read_text())
            receipt['cleanup_complete']=cleanup_complete(result,args.upgrade)
            receipt['candidate_status']=result.get('status')
            if result.get('status') != 'passed': code=1
        except Exception as error:
            receipt['error']=f'{type(error).__name__}: {error}'
        receipt.update(cancelled=cancelled,entry_exit_code=code)
        args.receipt.write_text(json.dumps(receipt,indent=2)+'\n')
    return 0 if code == 0 and not cancelled and receipt['cleanup_complete'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
