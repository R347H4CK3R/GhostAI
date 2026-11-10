#!/usr/bin/env python3
"""Advance only the opt-in preview feed after verified Jarvis publication.

No release mutations, no stable feed writes, no default-branch writes. Intended
as the final step in the existing finalizer job, with its native-job hash outputs.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import time
import urllib.error

import jarvis_release as release_checks
from publish_sidestore_source import api, pages, download_public, utc
from sidestore_source import render_source as render_classic_source, source_bytes, digest
from verify_app_icon import png_metadata

REPOSITORY = release_checks.REPOSITORY
SOURCE_BRANCH = 'jarvis-preview-source'
SOURCE_URL = f'https://raw.githubusercontent.com/{REPOSITORY}/{SOURCE_BRANCH}/source.json'
IDENTIFIER = 'dev.asterionveyra.jarvis.preview.source'
DESCRIPTION = ('Opt-in unsigned Jarvis prerelease for SideStore. Requires iOS 26 or later. '
               'This uses the same app identity as Asterion Veyra and may update an existing '
               'installation; it is not a separate sandboxed app. Export important chats and '
               'notes first, keep the existing app installed, and use the same signing account. '
               'Physical-device signing, voice/background behavior and retained-data upgrades '
               'are not verified. Generative chat requires supported Apple Intelligence '
               'hardware, enabled Apple Intelligence and downloaded OS model assets. '
               'The stable SideStore sources remain unchanged.')


def tag_for(build):
    return f'jarvis-v{release_checks.VERSION}-build-{build}'


def asset_url(build, name):
    return f'https://github.com/{REPOSITORY}/releases/download/{tag_for(build)}/{name}'


def render_source(path, build, commit, date):
    release_checks.validate_ipa(path, build)
    # The Classic renderer also checks every ZIP path, unsigned Mach-O, privacy
    # string, minimum OS and single-app/extension boundary. Never alter globals.
    source = render_classic_source(path, build, commit, date)
    source.update(name='Jarvis Preview (Unsigned)', identifier=IDENTIFIER, sourceURL=SOURCE_URL)
    app = source['apps'][0]
    app.update(name='Jarvis Preview', localizedDescription=DESCRIPTION)
    app['versions'][0]['downloadURL'] = asset_url(build, release_checks.ASSET)
    app['versions'][0]['localizedDescription'] = (
        f'Jarvis {release_checks.VERSION} build {build} unsigned preview. Full automated '
        'native/companion verification passed. Physical iPhone/SideStore installation '
        'and data retention remain unverified. Export important data before updating.')
    return source


def validate_context(env, run, jobs):
    build = release_checks.validate_context(env, run, jobs, phase='finalize')
    finalizers = [job for job in jobs if job.get('name') == 'finalize']
    if len(finalizers) != 1:
        raise ValueError('Expected one current finalizer')
    job = finalizers[0]
    steps = [step for step in job.get('steps', [])
             if step.get('name') == 'Publish completed verified Jarvis prerelease']
    if (job.get('head_sha') != run['head_sha'] or job.get('run_attempt') != run['run_attempt']
            or job.get('status') != 'in_progress' or job.get('conclusion') is not None
            or len(steps) != 1 or steps[0].get('status') != 'completed'
            or steps[0].get('conclusion') != 'success'):
        raise ValueError('Current finalizer has not successfully published the prerelease')
    return build


def validate_release(run, release, ref, expected):
    build = run['run_number']
    assets = release.get('assets', [])
    if (ref.get('object', {}).get('type') != 'commit'
            or ref['object'].get('sha') != run['head_sha']
            or release.get('tag_name') != tag_for(build)
            or release.get('draft') is not False or release.get('prerelease') is not True
            or type(release.get('id')) is not int or len(assets) != 3
            or set(expected) != {release_checks.ASSET, 'SHA256SUMS', 'VERIFICATION.md'}
            or {a.get('name') for a in assets} != set(expected)):
        raise ValueError('Expected exact public Jarvis prerelease and verified commit')
    utc(release.get('published_at'))
    for asset in assets:
        name = asset['name']
        if (not re.fullmatch('[0-9a-f]{64}', expected[name])
                or asset.get('browser_download_url') != asset_url(build, name)
                or asset.get('state') != 'uploaded' or type(asset.get('id')) is not int
                or type(asset.get('size')) is not int or not 0 < asset['size'] <= 536_870_912
                or asset.get('digest') != 'sha256:' + expected[name]):
            raise ValueError('Public asset differs from trusted native job outputs')


def provenance(source, run, release):
    version = source['apps'][0]['versions'][0]
    asset = next(a for a in release['assets'] if a['name'] == release_checks.ASSET)
    return dict(schemaVersion=1, channel='jarvis-preview', repository=REPOSITORY,
                commit=run['head_sha'], runID=run['id'], runAttempt=run['run_attempt'],
                runURL=f'https://github.com/{REPOSITORY}/actions/runs/{run["id"]}/attempts/{run["run_attempt"]}',
                tag=tag_for(run['run_number']), build=run['run_number'], version=version['version'],
                releaseID=release['id'], releaseAssetID=asset['id'], prerelease=True,
                ipaSHA256=version['sha256'], ipaSize=version['size'],
                sourceSHA256=hashlib.sha256(source_bytes(source)).hexdigest(),
                physicalDeviceVerified=False)


def validate_previous(source, proof, new_build):
    try:
        app = source['apps'][0]; version = app['versions'][0]; build = int(version['buildVersion'])
        prior_version = version['version']
        if not isinstance(prior_version, str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', prior_version):
            raise ValueError('Invalid previous version')
        prior_tag = f'jarvis-v{prior_version}-build-{build}'
        prior_url = f'https://github.com/{REPOSITORY}/releases/download/{prior_tag}/{release_checks.ASSET}'
        valid = (source['identifier'] == IDENTIFIER and source['sourceURL'] == SOURCE_URL
                 and len(source['apps']) == 1 and app['bundleIdentifier'] == 'dev.asterionveyra.assistant'
                 and len(app['versions']) == 1 and version['downloadURL'] == prior_url
                 and proof['schemaVersion'] == 1 and proof['channel'] == 'jarvis-preview'
                 and proof['repository'] == REPOSITORY and proof['prerelease'] is True
                 and proof['build'] == build and proof['tag'] == prior_tag
                 and proof['version'] == version['version']
                 and proof['ipaSHA256'] == version['sha256'] and proof['ipaSize'] == version['size']
                 and proof['sourceSHA256'] == hashlib.sha256(source_bytes(source)).hexdigest()
                 and new_build > build)
    except (KeyError, IndexError, TypeError, ValueError):
        valid = False
    if not valid:
        raise ValueError('Invalid preview provenance or non-monotonic update')


def current(env, expected):
    run_id = env.get('GITHUB_RUN_ID', '')
    if not re.fullmatch('[1-9][0-9]*', run_id):
        raise ValueError('Invalid run ID')
    run = api(f'actions/runs/{run_id}')
    jobs = [j for page in pages(f'actions/runs/{run_id}/jobs?filter=latest&per_page=100') for j in page['jobs']]
    build = validate_context(env, run, jobs)
    if api('git/ref/heads/' + release_checks.BRANCH)['object']['sha'] != run['head_sha']:
        raise ValueError('Release branch moved')
    release = api('releases/tags/' + tag_for(build))
    validate_release(run, release, api('git/ref/tags/' + tag_for(build)), expected)
    for page in pages('releases?per_page=100'):
        for other in page:
            match = re.fullmatch(r'jarvis-v[0-9.]+-build-([1-9][0-9]*)', other.get('tag_name', ''))
            if match and int(match[1]) > build:
                raise ValueError('A newer Jarvis release exists')
    return run, release


def previous(build):
    ref = api('git/ref/heads/' + SOURCE_BRANCH)['object']
    if ref.get('type') != 'commit' or not re.fullmatch('[0-9a-f]{40}', ref.get('sha', '')):
        raise ValueError('Invalid preview branch')
    documents = []
    for name in ('source.json', 'provenance.json'):
        result = api(f'contents/{name}?ref={ref["sha"]}')
        if result.get('encoding') != 'base64' or len(result.get('content', '')) > 1_048_576:
            raise ValueError('Invalid preview metadata encoding/size')
        documents.append(json.loads(base64.b64decode(result['content'])))
    validate_previous(*documents, build)
    return ref['sha']


def advance(parent, source, proof):
    base = api('git/commits/' + parent)['tree']['sha']
    tree = api('git/trees', {'base_tree': base, 'tree': [
        {'path': name, 'mode': '100644', 'type': 'blob', 'content': source_bytes(value).decode()}
        for name, value in [('source.json', source), ('provenance.json', proof)]]}, 'POST')
    commit = api('git/commits', {'message': f'Advance Jarvis preview to build {proof.get("build")}',
                               'tree': tree['sha'], 'parents': [parent]}, 'POST')
    # Non-forced branch movement rejects racing sibling commits. Preserve README.
    api('git/refs/heads/' + SOURCE_BRANCH, {'sha': commit['sha'], 'force': False}, 'PATCH')
    return commit['sha']


def verify_publication(commit, source, path):
    # Repeat anonymous reads only. Never roll back or repeat a ref update after
    # publication, even if GitHub's raw content has not propagated yet.
    for attempt in range(3):
        if api('git/ref/heads/' + SOURCE_BRANCH)['object']['sha'] != commit:
            raise ValueError('Preview branch changed after publication; inspect before retry')
        try:
            download_public(SOURCE_URL + '?commit=' + commit, path, 1_048_576)
            if path.read_bytes() == source_bytes(source):
                return
        except urllib.error.HTTPError as error:
            if error.code not in (404, 429, 500, 502, 503, 504):
                raise ValueError('Preview committed but public read is unverified; inspect before retry') from error
        except (OSError, ValueError):
            pass
        if attempt < 2:
            time.sleep(2 * (attempt + 1))
    raise ValueError('Preview committed but public serving remains unverified; inspect before retry')


def publish(env):
    if not env.get('GH_TOKEN'):
        raise ValueError('Explicit release token required')
    expected = {name: env.get('EXPECTED_' + key + '_SHA256', '') for key, name in
                [('IPA', release_checks.ASSET), ('NOTES', 'VERIFICATION.md'), ('SUMS', 'SHA256SUMS')]}
    run, release = current(env, expected)
    parent = previous(run['run_number'])
    with tempfile.TemporaryDirectory(prefix='jarvis-preview-source-') as directory:
        folder = Path(directory)
        for asset in release['assets']:
            path = folder / asset['name']
            download_public(asset['browser_download_url'], path, asset['size'])
            if path.stat().st_size != asset['size'] or digest(path) != expected[asset['name']]:
                raise ValueError('Anonymous asset bytes differ from native job output')
        source = render_source(folder / release_checks.ASSET, run['run_number'], run['head_sha'], release['published_at'])
        icon = folder / 'icon.png'
        download_public(source['apps'][0]['iconURL'], icon, 4_194_304)
        if png_metadata(icon.read_bytes(), 'preview source icon', require_rgb=True)[:2] != (1024, 1024):
            raise ValueError('Invalid preview icon')
        again, current_release = current(env, expected)
        if (any(again.get(k) != run.get(k) for k in ('id', 'run_number', 'run_attempt', 'head_sha', 'run_started_at'))
                or release_checks.release_snapshot(release) != release_checks.release_snapshot(current_release)):
            raise ValueError('Release or attempt changed during verification')
        commit = advance(parent, source, provenance(source, run, release))
        verify_publication(commit, source, folder / 'public-source.json')
    return SOURCE_URL


if __name__ == '__main__':
    print(publish(os.environ))
