#!/usr/bin/env python3
"""Publish a SideStore source only for an already public, byte-verified release.

No release/tag creation or replacement. Source-only recovery must pass the same
checks as the normal post-release step. All network mutations are Git objects
plus one non-forced branch advance; interrupted writes leave the old feed intact.
"""
import base64
from datetime import datetime
import json
import os
from pathlib import Path
import re
import tempfile
import urllib.parse
import urllib.request

from publish_ios_update import ASSET, BRANCH, REPOSITORY, gh, validate_run
from sidestore_source import (SOURCE_BRANCH, SOURCE_URL, digest, make_provenance,
                              release_url, render_source, source_bytes, validate_previous)
from verify_app_icon import png_metadata

REQUIRED_JOBS = {'ios', 'ios-pairing-tls-preflight', 'android',
                 'desktop-companion (ubuntu-latest)', 'desktop-companion (windows-latest)',
                 'desktop-companion (macos-latest)'}


def api(path, payload=None, method='GET'):
    endpoint = f'repos/{REPOSITORY}' + ('/' + path if path else '')
    if payload is None:
        return json.loads(gh('api', endpoint))
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', encoding='utf-8') as file:
        json.dump(payload, file)
        file.flush()
        return json.loads(gh('api', '--method', method, endpoint, '--input', file.name))


def pages(path):
    return json.loads(gh('api', '--paginate', '--slurp', f'repos/{REPOSITORY}/{path}'))


def download_artifact(run_id, folder):
    gh('run', 'download', str(run_id), '--repo', REPOSITORY,
       '--name', 'AsterionVeyra-unsigned-IPA', '--dir', str(folder))


class PublicGitHubRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, url):
        validate_public_url(url)
        return super().redirect_request(request, file, code, message, headers, url)


def validate_public_url(url):
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme != 'https' or parsed.username or parsed.password or parsed.port
            or parsed.hostname not in ('github.com', 'raw.githubusercontent.com',
                                       'release-assets.githubusercontent.com', 'objects.githubusercontent.com')):
        raise ValueError('Unexpected public asset URL or redirect')


def download_public(url, path, limit):
    validate_public_url(url)
    opener = urllib.request.build_opener(PublicGitHubRedirects())
    # Deliberately anonymous: a source must work without the publisher's token.
    with opener.open(url, timeout=60) as response, path.open('wb') as output:
        total = 0
        while chunk := response.read(min(1_048_576, limit + 1 - total)):
            total += len(chunk)
            if total > limit:
                raise ValueError('Public download exceeds expected size')
            output.write(chunk)
    if total == 0:
        raise ValueError('Empty public download')


def utc(value):
    if not isinstance(value, str) or not value.endswith('Z'):
        raise ValueError('Expected UTC workflow timestamp')
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def verified_run(run_id):
    run = api(f'actions/runs/{run_id}')
    validate_run(run)
    if (run.get('id') != run_id or type(run.get('run_attempt')) is not int
            or run['run_attempt'] < 1):
        raise ValueError('Workflow run identity/attempt mismatch')
    jobs = [job for page in pages(f'actions/runs/{run_id}/jobs?filter=latest&per_page=100')
            for job in page['jobs']]
    for name in REQUIRED_JOBS:
        matching = [job for job in jobs if job.get('name') == name]
        if (len(matching) != 1 or matching[0].get('conclusion') != 'success'
                or matching[0].get('run_id') != run_id
                or type(matching[0].get('run_attempt')) is not int
                or not 1 <= matching[0]['run_attempt'] <= run['run_attempt']):
            raise ValueError('Latest attempt verification jobs did not all pass')
    packaging = next(job for job in jobs if job['name'] == 'ios')
    artifacts = [artifact for page in pages(f'actions/runs/{run_id}/artifacts?per_page=100')
                 for artifact in page['artifacts'] if artifact.get('name') == 'AsterionVeyra-unsigned-IPA']
    if len(artifacts) != 1:
        raise ValueError('Expected one exact CI IPA artifact')
    artifact = artifacts[0]
    if (artifact.get('expired') is not False
            or artifact.get('workflow_run', {}).get('id') != run_id
            or artifact.get('workflow_run', {}).get('head_sha') != run['head_sha']
            or not utc(packaging.get('started_at')) <= utc(artifact.get('created_at'))
            <= utc(packaging.get('completed_at'))):
        raise ValueError('CI artifact is expired, stale, or from another commit')
    run['_artifact'] = artifact
    run['_packaging_attempt'] = packaging['run_attempt']
    return run


def verify_release(run, path):
    build = run['run_number']
    tag = f'ios-build-{build}'
    reference = api('git/ref/tags/' + tag)
    obj = reference.get('object', {})
    if obj.get('type') != 'commit' or obj.get('sha') != run['head_sha']:
        raise ValueError('Release tag does not point at the verified CI commit')
    release = api('releases/tags/' + tag)
    if (release.get('tag_name') != tag or release.get('draft') is not False
            or release.get('prerelease') is not False):
        raise ValueError('Expected the exact public stable release')
    utc(release.get('published_at'))
    assets = [asset for asset in release.get('assets', []) if asset.get('name') == ASSET]
    if len(assets) != 1:
        raise ValueError('Expected one exact released IPA asset')
    asset = assets[0]
    if (asset.get('browser_download_url') != release_url(build)
            or asset.get('state') != 'uploaded' or asset.get('size') != path.stat().st_size
            or asset.get('digest') not in (None, 'sha256:' + digest(path))):
        raise ValueError('Release IPA URL/size/digest differs from verified CI artifact')
    for page in pages('releases?per_page=100'):
        for other in page:
            match = re.fullmatch(r'ios-build-([1-9][0-9]*)', other.get('tag_name', ''))
            if match and int(match[1]) > build:
                raise ValueError('A newer release exists; source publication cannot roll back')
    # Ignore mutable counters: anonymously verifying the asset changes its
    # download_count. Compare identity and distribution fields, not telemetry.
    return {'id': release['id'], 'tag_name': tag, 'published_at': release['published_at'],
            'asset': {key: asset.get(key) for key in
                      ('id', 'name', 'state', 'size', 'digest', 'browser_download_url')}}


def previous_source(build):
    refs = api('git/matching-refs/heads/' + SOURCE_BRANCH)
    matching = [ref for ref in refs if ref.get('ref') == 'refs/heads/' + SOURCE_BRANCH]
    if not matching:
        return None
    if len(matching) != 1 or matching[0].get('object', {}).get('type') != 'commit':
        raise ValueError('Invalid source branch reference')
    parent = matching[0]['object']['sha']
    if not re.fullmatch('[0-9a-f]{40}', parent):
        raise ValueError('Invalid source branch commit')
    documents = []
    for name in ('source.json', 'provenance.json'):
        result = api(f'contents/{name}?ref={parent}')
        if result.get('encoding') != 'base64' or len(result.get('content', '')) > 1_048_576:
            raise ValueError('Existing source metadata is not bounded base64 content')
        documents.append(json.loads(base64.b64decode(result['content'])))
    validate_previous(*documents, build)
    return parent


def publish(run_id):
    if type(run_id) is not int or run_id <= 0:
        raise ValueError('Expected positive run ID')
    repository = api('')
    if repository.get('private') is not False or repository.get('full_name') != REPOSITORY:
        raise ValueError('SideStore source requires this exact public repository')
    run = verified_run(run_id)
    build = run['run_number']
    parent = previous_source(build)
    with tempfile.TemporaryDirectory(prefix='verified-sidestore-source-') as directory:
        folder = Path(directory)
        download_artifact(run_id, folder)
        path = folder / ASSET
        release = verify_release(run, path)
        source = render_source(path, build, run['head_sha'], release['published_at'])
        public_path = folder / 'public.ipa'
        download_public(release_url(build), public_path, path.stat().st_size)
        if public_path.stat().st_size != path.stat().st_size or digest(public_path) != digest(path):
            raise ValueError('Anonymous released IPA bytes differ from the verified CI artifact')
        icon = folder / 'icon.png'
        download_public(source['apps'][0]['iconURL'], icon, 4_194_304)
        width, height, *_ = png_metadata(icon.read_bytes(), 'public source icon', require_rgb=True)
        if (width, height) != (1024, 1024):
            raise ValueError('Published source icon is not 1024 by 1024')
        # A rerun can start while assets download. Never publish evidence from an
        # obsolete attempt, replaced tag, asset, or now-stale release.
        current = verified_run(run_id)
        if any(current[key] != run[key] for key in ('head_sha', 'run_number', 'run_attempt', 'run_started_at', '_artifact', '_packaging_attempt')):
            raise ValueError('CI attempt changed while verifying source')
        if verify_release(run, path) != release:
            raise ValueError('Release changed while verifying source')
        provenance = make_provenance(source, run_id, run['run_attempt'], run['head_sha'])
        provenance.update(artifactID=run['_artifact']['id'], packagingAttempt=run['_packaging_attempt'],
                          releaseID=release['id'], releaseAssetID=release['asset']['id'])
        entries = [{'path': name, 'mode': '100644', 'type': 'blob',
                    'content': source_bytes(content).decode()}
                   for name, content in (('source.json', source), ('provenance.json', provenance))]
        # An intentionally tiny tree: no source-code history, credentials or app data.
        tree = api('git/trees', {'tree': entries}, 'POST')
        commit = api('git/commits', {'message': f'Publish verified SideStore build {build}',
                                   'tree': tree['sha'], 'parents': [parent] if parent else []}, 'POST')
        if parent:
            # Non-forced fast-forward is the atomic compare-and-swap: a racing
            # sibling commit is not an ancestor and GitHub refuses the update.
            api('git/refs/heads/' + SOURCE_BRANCH, {'sha': commit['sha'], 'force': False}, 'PATCH')
        else:
            api('git/refs', {'ref': 'refs/heads/' + SOURCE_BRANCH, 'sha': commit['sha']}, 'POST')
    return SOURCE_URL


def main():
    if os.environ.get('GITHUB_REPOSITORY') != REPOSITORY or os.environ.get('GITHUB_REF_NAME') != BRANCH:
        raise ValueError('Publish source from the authorized release branch in the original repository')
    value = os.environ['UPDATE_RUN_ID']
    if not re.fullmatch('[1-9][0-9]*', value):
        raise ValueError('Expected numeric workflow run ID')
    print(publish(int(value)))


if __name__ == '__main__':
    main()
