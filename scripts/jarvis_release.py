#!/usr/bin/env python3
"""Fail-closed, branch-only unsigned candidate publisher. Never replaces a tag/release."""
import argparse
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

REPOSITORY = 'R347H4CK3R/GhostAI'
BRANCH = 'feature/unified-assistant-planning'
WORKFLOW = '.github/workflows/jarvis-release-candidate.yml'
VERSION = '0.4.0'
ASSET = 'Jarvis-unsigned.ipa'
PREREQUISITES = {'desktop-companion (ubuntu-latest)', 'desktop-companion (windows-latest)', 'desktop-companion (macos-latest)', 'android', 'ios-pairing-tls-preflight'}
NATIVE_GATES = {'Verify app icon source', 'Compile simulator test bundles', 'Unit tests', 'Export test screenshots', 'Verify encrypted Swift-to-desktop transfer', 'Verify install-over-existing simulator upgrade', 'Verify live release simulator upgrade', 'Compile unsigned device app'}


def validate_context(env, run, jobs, *, phase="stage"):
    if phase not in ("stage", "finalize"):
        raise ValueError("Unknown release phase")
    expected = {'GITHUB_REPOSITORY': REPOSITORY, 'GITHUB_REF': 'refs/heads/'+BRANCH,
                'GITHUB_WORKFLOW_REF': REPOSITORY+'/'+WORKFLOW+'@refs/heads/'+BRANCH}
    if any(env.get(k) != v for k, v in expected.items()):
        raise ValueError('Wrong repository, branch or workflow')
    for key in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_RUN_NUMBER'):
        if not re.fullmatch(r'[1-9][0-9]*', env.get(key, '')):
            raise ValueError('Invalid run identity')
    sha = env.get('GITHUB_SHA', '')
    if not re.fullmatch('[0-9a-f]{40}', sha):
        raise ValueError('Invalid commit')
    checks = {'id': int(env['GITHUB_RUN_ID']), 'run_attempt': int(env['GITHUB_RUN_ATTEMPT']),
              'run_number': int(env['GITHUB_RUN_NUMBER']), 'head_sha': sha, 'head_branch': BRANCH,
              'path': WORKFLOW, 'event': env.get('GITHUB_EVENT_NAME'), 'status': 'in_progress', 'conclusion': None}
    if (any(run.get(k) != v for k, v in checks.items())
            or run.get('event') not in ('push', 'workflow_dispatch')
            or run.get('repository', {}).get('full_name') != REPOSITORY
            or run.get('repository', {}).get('private') is not False
            or run.get('head_repository', {}).get('full_name') != REPOSITORY):
        raise ValueError('Untrusted or stale run')
    required = PREREQUISITES | {'ios'}
    selected = [j for j in jobs if j.get('name') in required]
    if len(selected) != len(required) or {j['name'] for j in selected} != required:
        raise ValueError('Missing or duplicate verification job')
    for job in selected:
        if job.get('run_attempt') != run['run_attempt'] or job.get('head_sha') != sha:
            raise ValueError('Job does not belong to current attempt/commit')
        if job['name'] != 'ios':
            if job.get('status') != 'completed' or job.get('conclusion') != 'success':
                raise ValueError('Prerequisite did not pass')
        else:
            expected_status, expected_conclusion = ('in_progress', None) if phase == 'stage' else ('completed', 'success')
            if job.get('status') != expected_status or job.get('conclusion') != expected_conclusion:
                raise ValueError('Native job has not reached the required release phase')
            for name in NATIVE_GATES:
                matches = [s for s in job.get('steps', []) if s.get('name') == name]
                if len(matches) != 1 or matches[0].get('status') != 'completed' or matches[0].get('conclusion') != 'success':
                    raise ValueError('Native gate did not pass: '+name)
    return run['run_number']


def validate_ipa(path, build):
    if not 0 < path.stat().st_size <= 536_870_912:
        raise ValueError('IPA size outside bounds')
    prefix = 'Payload/AsterionVeyra.app/'
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > 20000 or sum(e.file_size for e in entries) > 1_073_741_824:
            raise ValueError('Expanded IPA outside bounds')
        names = [e.filename for e in entries]
        if len(names) != len(set(names)):
            raise ValueError('Duplicate ZIP entry')
        for entry in entries:
            name = entry.filename
            if ('\\' in name or '\x00' in name or '..' in PurePosixPath(name).parts
                    or name.startswith('/') or (name != 'Payload/' and not name.startswith(prefix))
                    or stat.S_ISLNK(entry.external_attr >> 16) or entry.flag_bits & 1
                    or '/_CodeSignature/' in name or name.endswith('/embedded.mobileprovision')):
                raise ValueError('Unsafe or signed IPA entry')
        target = prefix+'Info.plist'
        if target not in names or archive.getinfo(target).file_size > 1_048_576:
            raise ValueError('Missing or oversized metadata')
        info = plistlib.loads(archive.read(target))
        expected = {'CFBundleIdentifier':'dev.asterionveyra.assistant', 'CFBundleDisplayName':'Jarvis',
                    'CFBundleExecutable':'AsterionVeyra', 'CFBundleShortVersionString': VERSION,
                    'CFBundleVersion':str(build), 'CFBundleSupportedPlatforms':['iPhoneOS']}
        if any(info.get(k) != v for k,v in expected.items()):
            raise ValueError('IPA identity/version/build/platform mismatch')
        executable = prefix+'AsterionVeyra'
        if executable not in names or archive.getinfo(executable).file_size == 0:
            raise ValueError('Missing app executable')
        if archive.testzip() is not None:
            raise ValueError('ZIP CRC verification failed')
    return info


def checksum_manifest(paths):
    return ''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in paths)


def verify_checksums(folder, manifest):
    for line in manifest.splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  ([A-Za-z0-9_.-]+)', line)
        if not match or hashlib.sha256((folder/match[2]).read_bytes()).hexdigest() != match[1]:
            raise ValueError('Release checksum mismatch')


def gh(*args):
    return subprocess.check_output(['gh', *args], text=True)


def api(path, *args):
    return json.loads(gh('api', f'repos/{REPOSITORY}/{path}', *args))


def main(phase="stage"):
    # Require explicit release-step credential, never discover saved credentials.
    if not os.environ.get('GH_TOKEN'):
        raise ValueError('Explicit release token required')
    run_id = os.environ.get('GITHUB_RUN_ID', '')
    attempt = os.environ.get('GITHUB_RUN_ATTEMPT', '')
    if not re.fullmatch(r'[1-9][0-9]*', run_id) or not re.fullmatch(r'[1-9][0-9]*', attempt):
        raise ValueError('Invalid run ID or attempt')
    run = api(f'actions/runs/{run_id}')
    pages = api(f'actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100', '--paginate', '--slurp')
    build = validate_context(os.environ, run, [j for p in pages for j in p['jobs']], phase=phase)
    sha = run['head_sha']
    if api(f'git/ref/heads/{BRANCH}')['object']['sha'] != sha:
        raise ValueError('Branch moved; do not release a stale commit')
    tag = f'jarvis-v{VERSION}-build-{build}'
    if phase == 'finalize':
        return finalize(tag, sha, build)
    if not os.environ.get('GITHUB_OUTPUT'):
        raise ValueError('Staging requires workflow output destination')
    path = Path(ASSET)
    validate_ipa(path, build)
    notes = Path('VERIFICATION.md')
    notes.write_text(f'''# Jarvis {VERSION}, build {build}

Unsigned iPhone/iPad candidate. Commit: {sha}
Verification: https://github.com/{REPOSITORY}/actions/runs/{run_id}/attempts/{attempt}

Passed before packaging/publication: desktop companion tests on Ubuntu, Windows and macOS;
Android unit tests, lint and debug assembly; native pairing TLS preflight; complete native
unit/UI suite; encrypted Swift-to-desktop transfer; retained simulator install-over-existing
upgrades from 0.3.0/build17 and 0.3.6/build44 using synthetic canonical fixtures;
source and packaged app icon validation; unsigned device compilation and IPA ZIP,
identity, version and build validation. SHA256SUMS covers the IPA and this document.
Release uploads were downloaded and hash-checked before the draft became a prerelease.

Requirements: iOS 26 or later. Generative chat needs Apple Intelligence-capable hardware, enabled Apple Intelligence and downloaded OS-managed model assets; those Apple assets are not bundled in this IPA. Local notes and fixed offline planning templates remain usable when inference is unavailable. No ChatGPT model/account or unrestricted device access is included.

Limitations: this is unsigned, not an App Store/TestFlight installation. SideStore or another
signing method and your signing account are still needed. Keep the existing app installed,
use the same signing account and export important chats/notes before updating. Simulator
retention is not proof of physical-device or SideStore retention, real private-sync keys,
remote state, or actual user-data retention. Physical-device voice,
background behavior and signing have not been verified by this workflow. Online models,
network services, platform permissions and paired desktop execution still require their
normal setup; no provider credentials or external services are bundled. This prerelease
does not change the stable update feeds, latest stable release, or default branch.
The separate opt-in Jarvis Preview source advances only after verified publication.
''', encoding='utf-8')
    manifest = checksum_manifest([path, notes])
    sums = Path('SHA256SUMS'); sums.write_text(manifest, encoding='utf-8')
    # Atomic ref creation rejects all existing tags, even after partial publication.
    api('git/refs', '--method', 'POST', '-f', f'ref=refs/tags/{tag}', '-f', f'sha={sha}')
    if api(f'git/ref/tags/{tag}')['object'] != {'sha':sha, 'type':'commit', 'url':f'https://api.github.com/repos/{REPOSITORY}/git/commits/{sha}'}:
        raise ValueError('Created tag does not resolve to exact commit')
    gh('release', 'create', tag, str(path), str(sums), str(notes), '--repo', REPOSITORY,
       '--verify-tag', '--draft', '--prerelease', '--latest=false', '--title', f'Jarvis {VERSION} build {build}', '--notes-file', str(notes))
    with tempfile.TemporaryDirectory(prefix='jarvis-release-verify-') as temp:
        gh('release', 'download', tag, '--repo', REPOSITORY, '--dir', temp)
        folder = Path(temp)
        if (folder/'SHA256SUMS').read_text(encoding='utf-8') != manifest:
            raise ValueError('Uploaded manifest changed')
        verify_checksums(folder, manifest)
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
        for key, asset in [('ipa_sha256', path), ('notes_sha256', notes), ('sums_sha256', sums)]:
            output.write(key+'='+hashlib.sha256(asset.read_bytes()).hexdigest()+'\n')


def release_snapshot(release):
    # Verification downloads may increment counters without changing release contents.
    result = dict(release)
    result['assets'] = [{k:v for k,v in asset.items() if k != 'download_count'}
                        for asset in release.get('assets', [])]
    return result


def draft_by_tag(tag):
    # The tag endpoint excludes drafts. Enumerate authenticated releases, then pin ID.
    pages = api('releases?per_page=100', '--paginate', '--slurp')
    matches = [r for page in pages for r in page if r.get('tag_name') == tag]
    if len(matches) != 1 or type(matches[0].get('id')) is not int:
        raise ValueError('Expected one uniquely identified candidate release')
    release = api(f"releases/{matches[0]['id']}")
    if release.get('id') != matches[0]['id'] or release.get('tag_name') != tag:
        raise ValueError('Release identity changed')
    return release


def finalize(tag, sha, build):
    expected = {}
    for key, name in [('IPA_SHA256', ASSET), ('NOTES_SHA256', 'VERIFICATION.md'), ('SUMS_SHA256', 'SHA256SUMS')]:
        digest = os.environ.get('EXPECTED_'+key, '')
        if not re.fullmatch('[0-9a-f]{64}', digest):
            raise ValueError('Missing trusted native job hash output')
        expected[name] = digest
    ref = api(f'git/ref/tags/{tag}')['object']
    if ref.get('type') != 'commit' or ref.get('sha') != sha:
        raise ValueError('Staged tag does not point at verified commit')
    release = draft_by_tag(tag)
    assets = [a.get('name') for a in release.get('assets', [])]
    if (release.get('draft') is not True or release.get('prerelease') is not True
            or release.get('tag_name') != tag or len(assets) != 3 or set(assets) != set(expected)):
        raise ValueError('Expected unique untouched draft candidate with exactly three assets')
    with tempfile.TemporaryDirectory(prefix='jarvis-finalize-') as temp:
        gh('release', 'download', tag, '--repo', REPOSITORY, '--dir', temp)
        folder = Path(temp)
        for name, digest in expected.items():
            if hashlib.sha256((folder/name).read_bytes()).hexdigest() != digest:
                raise ValueError('Draft asset differs from successful native job output')
        verify_checksums(folder, (folder/'SHA256SUMS').read_text(encoding='utf-8'))
        validate_ipa(folder/ASSET, build)
    # Recheck identity immediately before publishing; never edit an existing public release.
    ref = api(f'git/ref/tags/{tag}')['object']
    if ref.get('type') != 'commit' or ref.get('sha') != sha or release_snapshot(api(f"releases/{release['id']}")) != release_snapshot(release):
        raise ValueError('Draft or tag changed during verification')
    gh('release', 'edit', tag, '--repo', REPOSITORY, '--draft=false', '--prerelease', '--latest=false')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=('stage', 'finalize'))
    main(parser.parse_args().phase)
