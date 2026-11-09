#!/usr/bin/env python3
"""Synthetic-only seed CI evidence helpers. Never enables or certifies writers."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess

from companion.private_sync_codec import MAXIMUM_DOCUMENT_BYTES, strict_json
from scripts.private_sync_interop import FORMAT


def select_export(attachments: Path, output: Path) -> dict:
    if attachments.is_symlink() or not attachments.is_dir():
        raise ValueError('Missing regular attachment directory')
    found = []
    inspected = total_bytes = 0
    for directory, directories, files in os.walk(attachments, followlinks=False):
        for name in directories + files:
            path = Path(directory) / name
            info = path.lstat()
            inspected += 1
            if inspected > 1024 or stat.S_ISLNK(info.st_mode):
                raise ValueError('Unsupported or excessive attachment entries')
            if not stat.S_ISREG(info.st_mode):
                if not stat.S_ISDIR(info.st_mode):
                    raise ValueError('Nonregular attachment')
                continue
            if not 0 < info.st_size <= MAXIMUM_DOCUMENT_BYTES:
                continue
            with path.open('rb') as stream:
                raw = stream.read(MAXIMUM_DOCUMENT_BYTES + 1)
            total_bytes += len(raw)
            if total_bytes > 32 * 1024 * 1024:
                raise ValueError('Attachment scan budget exceeded')
            try:
                value = strict_json(raw)
            except ValueError:
                continue
            if isinstance(value, dict) and value.get('format') == FORMAT:
                if value.get('status') != 'native-export':
                    raise ValueError('Pending or invalid native export cannot seed conformance')
                found.append((path, raw))
    if len(found) != 1:
        raise ValueError('Exactly one synthetic native export is required')
    path, raw = found[0]
    # Preserve the oracle's bytes, never generate a replacement expected encoding.
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('xb') as stream:
        stream.write(raw)
    return {'attachment': str(path.relative_to(attachments)), 'bytes': len(raw),
            'sha256': hashlib.sha256(raw).hexdigest(), 'phase': 'seed', 'release_ready': False}


def provenance(root: Path, expected_sha: str) -> dict:
    if not re.fullmatch('[0-9a-f]{40}', expected_sha):
        raise ValueError('An exact 40-character source SHA is required')
    def git(*args):
        return subprocess.run(['git', *args], cwd=root, check=True, text=True,
                              capture_output=True, timeout=15).stdout.strip()
    source_sha = git('rev-parse', 'HEAD')
    summary = git('diff', '--stat', 'HEAD', '--')
    names = git('diff', '--name-status', 'HEAD', '--')
    tracked_status = git('status', '--porcelain=v1', '--untracked-files=no')
    return {
        'phase': 'seed', 'release_ready': False, 'source_sha': source_sha,
        'expected_sha': expected_sha, 'source_tree': git('rev-parse', 'HEAD^{tree}'),
        'tracked_diff_summary': summary, 'tracked_diff_name_status': names,
        'staged_diff_summary': git('diff', '--cached', '--stat', '--'),
        'unstaged_diff_summary': git('diff', '--stat', '--'),
        'tracked_status': tracked_status,
        'source_verified': source_sha == expected_sha and not tracked_status and not summary and not names,
        'run_id': os.environ.get('GITHUB_RUN_ID', ''),
        'run_attempt': os.environ.get('GITHUB_RUN_ATTEMPT', ''),
        'job': os.environ.get('GITHUB_JOB', ''), 'runner_os': os.environ.get('RUNNER_OS', ''),
    }


def foundation_result(summary) -> dict:
    """Check only the isolated native helper suite, never overall sync readiness."""
    expected = {'passedTests': 14, 'totalTestCount': 14, 'failedTests': 0, 'skippedTests': 0}
    summary = summary if isinstance(summary, dict) else {}
    passed = summary.get('result') == 'Passed' and all(
        type(summary.get(field)) is int and summary[field] == count for field, count in expected.items())
    return {'phase': 'unwired-foundation', 'suite': 'KnowledgeSyncJoinTests', 'passed': passed,
            'counts': {field: summary.get(field) for field in expected}, 'release_ready': False,
            'legacy_convergence': 'blocked by seven known divergences; checked separately'}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    source = commands.add_parser('provenance')
    source.add_argument('--root', type=Path, default=Path.cwd())
    source.add_argument('--expected-sha', required=True)
    source.add_argument('--output', type=Path, required=True)
    select = commands.add_parser('select-export')
    select.add_argument('--attachments', type=Path, required=True)
    select.add_argument('--output', type=Path, required=True)
    foundation = commands.add_parser('check-foundation')
    foundation.add_argument('--summary', type=Path, required=True)
    foundation.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == 'provenance':
            result = provenance(args.root, args.expected_sha)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            with args.output.open('x') as stream:
                json.dump(result, stream, indent=2); stream.write('\n')
            print(json.dumps(result, indent=2))
            return 0 if result['source_verified'] else 1
        if args.command == 'check-foundation':
            with args.summary.open('rb') as stream:
                summary = strict_json(stream.read(MAXIMUM_DOCUMENT_BYTES + 1))
            result = foundation_result(summary)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            with args.output.open('x') as stream:
                json.dump(result, stream, indent=2); stream.write('\n')
            print(json.dumps(result, indent=2))
            return 0 if result['passed'] else 1
        result = select_export(args.attachments, args.output)
        print(json.dumps(result, indent=2))
        return 0
    except (OSError, ValueError, subprocess.SubprocessError):
        # Do not dump data, credentials, environment variables or an arbitrary file.
        print('Seed conformance evidence failed; no release or writer approval.')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
