import base64
import copy
import hashlib
import importlib.util
import io
from types import SimpleNamespace
import json
import os
from pathlib import Path
import sys
import tempfile
from unittest import mock
import unittest

sys.path.insert(0, str(Path(__file__).parents[1]))
from test_sidestore_source import ipa_fixture

MODULE = Path(__file__).parents[1] / 'publish_sidestore_source.py'


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(MODULE.exists(), 'Verified source publication is not implemented')
        spec = importlib.util.spec_from_file_location('source_publisher', MODULE)
        self.publisher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.publisher)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.ipa = Path(self.directory.name) / 'input.ipa'
        ipa_fixture(self.ipa)
        self.data = self.ipa.read_bytes()
        self.run = {'id': 123, 'run_number': 40, 'run_attempt': 2,
                    'repository': {'full_name': 'R347H4CK3R/GhostAI'},
                    'head_repository': {'full_name': 'R347H4CK3R/GhostAI'},
                    'head_branch': 'feature/paired-execution-protocol',
                    'path': '.github/workflows/ios.yml', 'event': 'push',
                    'status': 'completed', 'conclusion': 'success', 'head_sha': 'a' * 40,
                    'run_started_at': '2026-11-08T12:00:00Z'}
        self.jobs = [{'name': name, 'conclusion': 'success', 'run_id': 123, 'run_attempt': 2,
                      'started_at': '2026-11-08T12:00:00Z', 'completed_at': '2026-11-08T12:45:00Z'}
                     for name in ('ios', 'ios-pairing-tls-preflight', 'android',
                                  'desktop-companion (ubuntu-latest)',
                                  'desktop-companion (windows-latest)',
                                  'desktop-companion (macos-latest)')]
        self.artifacts = [{'id': 456, 'name': 'AsterionVeyra-unsigned-IPA', 'expired': False,
                           'created_at': '2026-11-08T12:30:00Z',
                           'workflow_run': {'id': 123, 'head_sha': 'a' * 40}}]
        self.release = {'id': 5, 'tag_name': 'ios-build-40', 'draft': False, 'prerelease': False,
                        'published_at': '2026-11-08T13:00:00Z',
                        'assets': [{'id': 6, 'name': 'AsterionVeyra-unsigned.ipa', 'state': 'uploaded',
                                    'size': len(self.data), 'digest': 'sha256:' + hashlib.sha256(self.data).hexdigest(),
                                    'browser_download_url': 'https://github.com/R347H4CK3R/GhostAI/releases/download/ios-build-40/AsterionVeyra-unsigned.ipa'}]}
        self.tag = {'object': {'type': 'commit', 'sha': 'a' * 40}}
        self.previous = None
        self.calls = []
        self.public_data = self.data
        self.stale_run = False
        self.race = False
        self.newer_release = False
        self.mutable_download_count = False
        self.run_reads = 0
        self.tree = None
        self.commit = None
        self.advanced = None

    def api(self, path, payload=None, method='GET'):
        self.calls.append((path, payload, method))
        if path == '':
            return {'private': False, 'full_name': 'R347H4CK3R/GhostAI'}
        if path == 'actions/runs/123':
            self.run_reads += 1
            result = copy.deepcopy(self.run)
            if self.stale_run and self.run_reads > 1:
                result['run_attempt'] = 3
            return result
        if path == 'git/ref/tags/ios-build-40':
            return self.tag
        if path == 'releases/tags/ios-build-40':
            if self.mutable_download_count:
                asset = self.release['assets'][0]
                asset['download_count'] = asset.get('download_count', 0) + 1
            return copy.deepcopy(self.release)
        if path == 'git/matching-refs/heads/sidestore-source':
            return [] if self.previous is None else [{'ref': 'refs/heads/sidestore-source', 'object': {'sha': 'b' * 40, 'type': 'commit'}}]
        if path.startswith('contents/'):
            filename = path.split('/')[1].split('?')[0]
            content = self.previous[filename]
            return {'encoding': 'base64', 'content': base64.b64encode(json.dumps(content).encode()).decode()}
        if path == 'git/trees' and method == 'POST':
            self.tree = payload
            return {'sha': 'c' * 40}
        if path == 'git/commits' and method == 'POST':
            self.commit = payload
            return {'sha': 'd' * 40}
        if path in ('git/refs', 'git/refs/heads/sidestore-source'):
            if self.race:
                raise RuntimeError('Reference was concurrently changed; non-fast-forward refused')
            self.advanced = payload
            return {'object': {'sha': 'd' * 40}}
        self.fail(f'Unexpected API request: {path} {method}')

    def pages(self, path):
        if path == 'actions/runs/123/jobs?filter=latest&per_page=100':
            return [{'jobs': self.jobs}]
        if path == 'actions/runs/123/artifacts?per_page=100':
            return [{'artifacts': self.artifacts}]
        if path == 'releases?per_page=100':
            return [[self.release] + ([{'tag_name': 'ios-build-41'}] if self.newer_release else [])]
        self.fail(f'Unexpected pages request: {path}')

    def artifact(self, run_id, folder):
        (folder / 'AsterionVeyra-unsigned.ipa').write_bytes(self.data)

    def download(self, url, path, limit):
        if url.endswith('.ipa'):
            path.write_bytes(self.public_data)
        else:
            path.write_bytes((Path(__file__).parents[2] / 'App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png').read_bytes())

    def invoke(self):
        with mock.patch.object(self.publisher, 'api', side_effect=self.api), \
             mock.patch.object(self.publisher, 'pages', side_effect=self.pages), \
             mock.patch.object(self.publisher, 'download_artifact', side_effect=self.artifact), \
             mock.patch.object(self.publisher, 'download_public', side_effect=self.download):
            return self.publisher.publish(123)

    def test_first_publication_commits_source_and_provenance_atomically(self):
        result = self.invoke()
        self.assertEqual(result, 'https://raw.githubusercontent.com/R347H4CK3R/GhostAI/sidestore-source/source.json')
        self.assertEqual(self.commit['parents'], [])
        self.assertEqual(self.advanced, {'ref': 'refs/heads/sidestore-source', 'sha': 'd' * 40})
        entries = {entry['path']: json.loads(entry['content']) for entry in self.tree['tree']}
        self.assertEqual(set(entries), {'source.json', 'provenance.json'})
        self.assertEqual(entries['source.json']['apps'][0]['versions'][0]['buildVersion'], '40')
        self.assertEqual(entries['provenance.json']['runAttempt'], 2)
        self.assertEqual(entries['provenance.json']['commit'], 'a' * 40)
        self.assertTrue(all(entry['mode'] == '100644' for entry in self.tree['tree']))

    def test_every_verification_failure_leaves_source_ref_untouched(self):
        mutations = [lambda: self.tag['object'].update(sha='e' * 40),
                     lambda: self.release.update(draft=True),
                     lambda: self.release['assets'].append(copy.deepcopy(self.release['assets'][0])),
                     lambda: self.release['assets'][0].update(browser_download_url='https://evil.test/app.ipa'),
                     lambda: self.release['assets'][0].update(digest='sha256:' + '0' * 64),
                     lambda: setattr(self, 'public_data', b'wrong IPA'),
                     lambda: self.jobs.pop(),
                     lambda: self.jobs[0].update(run_attempt=3),
                     lambda: self.artifacts[0].update(expired=True),
                     lambda: self.artifacts[0]['workflow_run'].update(head_sha='e' * 40),
                     lambda: self.artifacts[0].update(created_at='2026-11-08T11:00:00Z'),
                     lambda: self.artifacts.append(copy.deepcopy(self.artifacts[0])),
                     lambda: setattr(self, 'stale_run', True),
                     lambda: setattr(self, 'newer_release', True)]
        for index, mutation in enumerate(mutations):
            with self.subTest(case=index):
                self.setUp()
                mutation()
                with self.assertRaises(ValueError):
                    self.invoke()
                self.assertIsNone(self.advanced)
                self.assertIsNone(self.tree)

    def test_asset_download_counter_changes_do_not_invalidate_exact_bytes(self):
        self.mutable_download_count = True
        self.invoke()
        self.assertIsNotNone(self.advanced)

    def test_retained_successful_jobs_from_prior_attempt_are_valid(self):
        self.jobs[1]['run_attempt'] = 1
        self.jobs[1]['started_at'] = '2026-11-08T11:00:00Z'
        self.jobs[1]['completed_at'] = '2026-11-08T11:45:00Z'
        self.invoke()
        self.assertIsNotNone(self.advanced)

    def test_artifact_from_earlier_than_latest_packaging_job_is_rejected(self):
        self.artifacts[0]['created_at'] = '2026-11-08T11:59:59Z'
        with self.assertRaises(ValueError):
            self.invoke()
        self.assertIsNone(self.advanced)

    def test_existing_source_advances_without_force_and_race_stops(self):
        import sidestore_source
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'old.ipa'
            from test_sidestore_source import info_fixture
            ipa_fixture(path, dict(info_fixture(), CFBundleVersion='39'))
            old = sidestore_source.render_source(path, 39, 'e' * 40, '2026-11-07T13:00:00Z')
        self.previous = {'source.json': old,
                         'provenance.json': sidestore_source.make_provenance(old, 122, 1, 'e' * 40)}
        self.invoke()
        self.assertEqual(self.commit['parents'], ['b' * 40])
        self.assertEqual(self.advanced, {'sha': 'd' * 40, 'force': False})
        self.advanced = None
        self.race = True
        with self.assertRaises(RuntimeError):
            self.invoke()
        self.assertIsNone(self.advanced)

    def test_public_downloads_reject_insecure_foreign_or_credential_urls(self):
        for url in ('http://github.com/asset', 'https://evil.test/asset',
                    'https://user:secret@github.com/asset', 'https://github.com:443/asset'):
            with self.subTest(url=url):
                with self.assertRaises(ValueError):
                    self.publisher.validate_public_url(url)
        self.publisher.validate_public_url('https://release-assets.githubusercontent.com/asset?signature=value')

    def test_public_download_is_bounded_and_preserves_exact_bytes(self):
        target = Path(self.directory.name) / 'download'
        for data, limit, succeeds in ((b'IPA', 3, True), (b'IPA!', 3, False), (b'', 3, False)):
            opener = SimpleNamespace(open=lambda url, timeout: io.BytesIO(data))
            with mock.patch.object(self.publisher.urllib.request, 'build_opener', return_value=opener):
                if succeeds:
                    self.publisher.download_public('https://github.com/asset', target, limit)
                    self.assertEqual(target.read_bytes(), b'IPA')
                else:
                    with self.assertRaises(ValueError):
                        self.publisher.download_public('https://github.com/asset', target, limit)

    def test_equal_or_newer_existing_source_never_updates(self):
        self.invoke()
        self.previous = {entry['path']: json.loads(entry['content']) for entry in self.tree['tree']}
        self.tree = self.advanced = None
        with self.assertRaises(ValueError):
            self.invoke()
        self.assertIsNone(self.tree)
        self.assertIsNone(self.advanced)


if __name__ == '__main__':
    unittest.main()
