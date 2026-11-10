#!/usr/bin/env python3
"""One-shot publication recovery for an already verified, immutable build-6 candidate."""
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path
from jarvis_release import api, draft_by_tag, validate_ipa, verify_checksums, release_snapshot, REPOSITORY, BRANCH

RUN_ID = 42726846719
RELEASE_ID = 439832118
SHA = '250c0a59ad481322309ef796de8938286aed178b'
TAG = 'jarvis-v0.4.0-build-6'
RECOVERY_BRANCH = 'recovery/jarvis-build-6'
RECOVERY_WORKFLOW = '.github/workflows/jarvis-recover-build6.yml'
FAILED_STEP = 'Publish completed verified Jarvis prerelease'
RUN_FIELDS = {'id': 42726846719,
 'workflow_id': 412317942,
 'run_number': 6,
 'run_attempt': 1,
 'head_sha': '250c0a59ad481322309ef796de8938286aed178b',
 'head_branch': 'feature/unified-assistant-planning',
 'path': '.github/workflows/jarvis-release-candidate.yml',
 'event': 'push',
 'status': 'completed',
 'conclusion': 'failure'}
JOBS = {'desktop-companion (ubuntu-latest)': [129534548987,
                                       ['Set up job',
                                        'Run actions/checkout@v4',
                                        'Run actions/setup-python@v5',
                                        'Run python -m pip install -r '
                                        'companion/requirements-pairing.txt',
                                        'Run python -m unittest discover -s companion/tests -v',
                                        'Post Run actions/setup-python@v5',
                                        'Post Run actions/checkout@v4',
                                        'Complete job']],
 'desktop-companion (macos-latest)': [129534549294,
                                      ['Set up job',
                                       'Run actions/checkout@v4',
                                       'Run actions/setup-python@v5',
                                       'Run python -m pip install -r '
                                       'companion/requirements-pairing.txt',
                                       'Run python -m unittest discover -s companion/tests -v',
                                       'Post Run actions/setup-python@v5',
                                       'Post Run actions/checkout@v4',
                                       'Complete job']],
 'desktop-companion (windows-latest)': [129534549325,
                                        ['Set up job',
                                         'Run actions/checkout@v4',
                                         'Run actions/setup-python@v5',
                                         'Run python -m pip install -r '
                                         'companion/requirements-pairing.txt',
                                         'Run python -m unittest discover -s companion/tests -v',
                                         'Post Run actions/setup-python@v5',
                                         'Post Run actions/checkout@v4',
                                         'Complete job']],
 'ios-pairing-tls-preflight': [129534549331,
                               ['Set up job',
                                'Run actions/checkout@v4',
                                'Select Xcode 26',
                                'Run brew install xcodegen',
                                'Run xcodegen generate',
                                'Boot test simulator',
                                'Pairing TLS policy tests',
                                'Post Run actions/checkout@v4',
                                'Complete job']],
 'android': [129534549570,
             ['Set up job',
              'Run actions/checkout@v4',
              'Run actions/setup-java@v4',
              'Run android-actions/setup-android@v3',
              'Run gradle/actions/setup-gradle@v4',
              'Test, lint and build Android debug APK',
              'Post Run gradle/actions/setup-gradle@v4',
              'Post Run actions/setup-java@v4',
              'Post Run actions/checkout@v4',
              'Complete job']],
 'ios': [129538771000,
         ['Set up job',
          'Run actions/checkout@v4',
          'Select Xcode 26',
          'Run brew install xcodegen',
          'Verify app icon source',
          'Run xcodegen generate',
          'Boot owned test simulator',
          'Compile simulator test bundles',
          'Unit tests',
          'Export test screenshots',
          'Verify encrypted Swift-to-desktop transfer',
          'Shut down owned test simulator before upgrade',
          'Verify install-over-existing simulator upgrade',
          'Verify live release simulator upgrade',
          'Compile unsigned device app',
          'Stage verified Jarvis draft',
          'Post Run actions/checkout@v4',
          'Complete job']],
 'finalize': [129560084905,
              ['Set up job',
               'Run actions/checkout@v4',
               'Publish completed verified Jarvis prerelease',
               'Post Run actions/checkout@v4',
               'Complete job']]}
ASSETS = {'Jarvis-unsigned.ipa': [729630059,
                         3028695,
                         '294399347d825596d3fc797c353e5ea902ea9a736854645efc3e30d45104ca91'],
 'SHA256SUMS': [729630061, 168, '068131a7507bd95da97532806ec2e016d88883cde4edc485abd4abcc3034242e'],
 'VERIFICATION.md': [729630067,
                     1946,
                     'c8bfb87529e9b34e3889fde5442b3ffec8cd6791587ed6dc919dc8a4bea79bd8']}


def validate_recovery_context(env):
    expected = dict(GITHUB_REPOSITORY=REPOSITORY, GITHUB_REF='refs/heads/'+RECOVERY_BRANCH,
                    GITHUB_WORKFLOW_REF=REPOSITORY+'/'+RECOVERY_WORKFLOW+'@refs/heads/'+RECOVERY_BRANCH,
                    GITHUB_RUN_ATTEMPT='1', GITHUB_EVENT_NAME='push')
    if any(env.get(k) != v for k,v in expected.items()):
        raise ValueError('Not the first attempt of the isolated recovery push')


def validate_origin(run, jobs):
    if (any(run.get(k) != v for k,v in RUN_FIELDS.items())
            or run.get('repository',{}).get('full_name') != REPOSITORY
            or run.get('repository',{}).get('private') is not False
            or run.get('head_repository',{}).get('full_name') != REPOSITORY):
        raise ValueError('Original run identity or attempt changed')
    if len(jobs) != len(JOBS) or {j.get('name') for j in jobs} != set(JOBS):
        raise ValueError('Missing, extra or duplicate original jobs')
    for job in jobs:
        name = job['name']
        job_id, steps = JOBS[name]
        expected = dict(id=job_id, run_id=RUN_ID, run_attempt=1, head_sha=SHA,
                        status='completed', conclusion='failure' if name=='finalize' else 'success')
        if any(job.get(k) != v for k,v in expected.items()):
            raise ValueError('Original job changed: '+name)
        actual = job.get('steps',[])
        if len(actual) != len(steps) or {s.get('name') for s in actual} != set(steps):
            raise ValueError('Original steps changed: '+name)
        for step in actual:
            conclusion = 'failure' if name=='finalize' and step['name']==FAILED_STEP else 'success'
            if step.get('status') != 'completed' or step.get('conclusion') != conclusion:
                raise ValueError('Original verification step did not pass: '+step['name'])


def validate_release(release, *, published=False):
    if (release.get('id') != RELEASE_ID or release.get('tag_name') != TAG
            or release.get('draft') is not (not published) or release.get('prerelease') is not True
            or (not published and release.get('published_at') is not None)):
        raise ValueError('Expected the exact untouched draft prerelease')
    assets = release.get('assets',[])
    if len(assets) != len(ASSETS) or {a.get('name') for a in assets} != set(ASSETS):
        raise ValueError('Draft assets missing, duplicated or added')
    for asset in assets:
        identity, size, digest = ASSETS[asset['name']]
        if (asset.get('id') != identity or asset.get('size') != size
                or asset.get('digest') != 'sha256:'+digest or asset.get('state') != 'uploaded'):
            raise ValueError('Draft asset identity changed')


def check_origin_and_refs():
    run = api(f'actions/runs/{RUN_ID}')
    pages = api(f'actions/runs/{RUN_ID}/attempts/1/jobs?per_page=100', '--paginate', '--slurp')
    validate_origin(run, [j for page in pages for j in page['jobs']])
    for ref in ('heads/'+BRANCH, 'tags/'+TAG):
        obj = api('git/ref/'+ref)['object']
        if obj.get('type') != 'commit' or obj.get('sha') != SHA:
            raise ValueError('Verified source branch or tag moved')


def download_asset(identity, path):
    # Binary API download by immutable asset ID. No tag resolution or shell interpolation.
    with path.open('wb') as stream:
        subprocess.run(['gh','api',f'repos/{REPOSITORY}/releases/assets/{identity}',
                        '-H','Accept: application/octet-stream'], stdout=stream, check=True, timeout=120)


def main():
    validate_recovery_context(os.environ)
    if not os.environ.get('GH_TOKEN'):
        raise ValueError('Explicit workflow job token required')
    check_origin_and_refs()
    release = draft_by_tag(TAG)
    validate_release(release)
    with tempfile.TemporaryDirectory(prefix='jarvis-build6-recovery-') as temp:
        folder=Path(temp)
        for name,(identity,size,digest) in ASSETS.items():
            path=folder/name
            download_asset(identity,path)
            if path.stat().st_size != size or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                raise ValueError('Downloaded asset differs from original verified bytes')
        verify_checksums(folder,(folder/'SHA256SUMS').read_text(encoding='utf-8'))
        validate_ipa(folder/'Jarvis-unsigned.ipa',6)
    # Re-read all external gates immediately before the sole mutation.
    check_origin_and_refs()
    current=draft_by_tag(TAG)
    validate_release(current)
    if release_snapshot(current) != release_snapshot(release):
        raise ValueError('Draft changed while verifying; stop for review')
    # Exactly one ID-targeted PATCH; no retries, release recreation, uploads or ref writes.
    result=api(f'releases/{RELEASE_ID}', '--method','PATCH',
               '-F','draft=false','-F','prerelease=true','-f','make_latest=false')
    validate_release(result,published=True)
    validate_release(api(f'releases/{RELEASE_ID}'),published=True)
    print(f'Published verified unsigned prerelease: https://github.com/{REPOSITORY}/releases/tag/{TAG}')


if __name__ == '__main__':
    main()

