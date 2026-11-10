import base64
import copy
import shutil
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).parents[1]
sys.path.insert(0, str(SCRIPTS))
import test_jarvis_release
from test_sidestore_source import ipa_fixture, info_fixture


class PreviewSourceTests(unittest.TestCase):
    def setUp(self):
        path = SCRIPTS / 'jarvis_preview_source.py'
        self.assertTrue(path.exists(), 'Dedicated Jarvis preview publisher is missing')
        spec = importlib.util.spec_from_file_location('preview', path)
        self.m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.m)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.folder = Path(self.tmp.name)
        self.ipa = self.folder / 'Jarvis-unsigned.ipa'
        self.info = dict(info_fixture(), CFBundleVersion='12', CFBundleShortVersionString='0.4.0', CFBundleDisplayName='Jarvis')
        ipa_fixture(self.ipa, self.info)

    def render(self):
        return self.m.render_source(self.ipa, 12, 'a' * 40, '2026-11-10T17:10:17Z')

    def fixture(self):
        helper = test_jarvis_release.ReleaseTests()
        helper.setUp()
        self.addCleanup(helper.doCleanups)
        env, run, jobs = helper.fixture()
        jobs[-1].update(status='completed', conclusion='success')
        jobs.append(dict(name='finalize', status='in_progress', conclusion=None,
                         run_attempt=1, head_sha='a' * 40, steps=[dict(name='Publish completed verified Jarvis prerelease', status='completed', conclusion='success')]))
        return env, run, jobs

    def test_source_is_distinct_preview_but_preserves_installed_identity(self):
        source = self.render()
        self.assertEqual(source['sourceURL'], 'https://raw.githubusercontent.com/R347H4CK3R/GhostAI/jarvis-preview-source/source.json')
        self.assertEqual(source['identifier'], 'dev.asterionveyra.jarvis.preview.source')
        app = source['apps'][0]
        self.assertEqual(app['name'], 'Jarvis Preview')
        self.assertEqual(app['bundleIdentifier'], 'dev.asterionveyra.assistant')
        self.assertIn('same app identity', app['localizedDescription'])
        self.assertIn('not verified', app['localizedDescription'])
        self.assertEqual(app['versions'][0]['downloadURL'], 'https://github.com/R347H4CK3R/GhostAI/releases/download/jarvis-v0.4.0-build-12/Jarvis-unsigned.ipa')
        self.assertEqual(app['versions'][0]['size'], self.ipa.stat().st_size)
        self.assertEqual(app['versions'][0]['sha256'], hashlib.sha256(self.ipa.read_bytes()).hexdigest())
        self.assertEqual(app['appPermissions']['privacy']['NSMicrophoneUsageDescription'], 'Record when requested.')

    def test_wrong_jarvis_identity_and_nested_extension_fail(self):
        for info, extra in [(dict(self.info, CFBundleDisplayName='Veyra'), None),
                            (self.info, {'Payload/AsterionVeyra.app/PlugIns/Thing.appex/Info.plist': b'x'})]:
            ipa_fixture(self.ipa, info, extra=extra)
            with self.assertRaises(ValueError): self.render()

    def test_all_existing_gates_and_successful_publication_step_required(self):
        self.assertEqual(self.m.validate_context(*self.fixture()), 12)
        for change in ('unpublished', 'duplicate', 'old-attempt', 'native-failed', 'private', 'wrong-branch'):
            env, run, jobs = self.fixture()
            if change == 'unpublished': jobs[-1]['steps'][0]['conclusion'] = 'failure'
            elif change == 'duplicate': jobs.append(copy.deepcopy(jobs[-1]))
            elif change == 'old-attempt': jobs[-1]['run_attempt'] = 2
            elif change == 'native-failed': jobs[-2]['conclusion'] = 'failure'
            elif change == 'private': run['repository']['private'] = True
            else: env['GITHUB_REF'] = 'refs/heads/main'
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.m.validate_context(env, run, jobs)

    def release(self):
        return {'id': 500, 'tag_name': 'jarvis-v0.4.0-build-12', 'draft': False, 'prerelease': True,
                'published_at': '2026-11-10T17:10:17Z',
                'assets': [{'id': n, 'name': name, 'state': 'uploaded', 'size': 1,
                            'digest': 'sha256:' + 'b' * 64,
                            'browser_download_url': 'https://github.com/R347H4CK3R/GhostAI/releases/download/jarvis-v0.4.0-build-12/' + name}
                           for n, name in enumerate(('Jarvis-unsigned.ipa', 'SHA256SUMS', 'VERIFICATION.md'), 1)]}

    def test_release_must_match_public_prerelease_tag_and_native_output_hashes(self):
        _, run, _ = self.fixture()
        expected = {a['name']: 'b' * 64 for a in self.release()['assets']}
        ref = {'object': {'type': 'commit', 'sha': 'a' * 40}}
        self.m.validate_release(run, self.release(), ref, expected)
        for change in ('draft', 'stable', 'tag', 'hash', 'url', 'duplicate', 'sha'):
            release = self.release(); tag = copy.deepcopy(ref)
            if change == 'draft': release['draft'] = True
            elif change == 'stable': release['prerelease'] = False
            elif change == 'tag': release['tag_name'] = 'jarvis-v0.4.0-build-11'
            elif change == 'hash': release['assets'][0]['digest'] = 'sha256:' + 'c' * 64
            elif change == 'url': release['assets'][0]['browser_download_url'] = 'https://evil.invalid/ipa'
            elif change == 'duplicate': release['assets'].append(copy.deepcopy(release['assets'][0]))
            else: tag['object']['sha'] = 'c' * 40
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.m.validate_release(run, release, tag, expected)

    def test_previous_provenance_and_monotonic_build_required(self):
        source = self.render()
        _, run, _ = self.fixture()
        provenance = self.m.provenance(source, run, self.release())
        self.m.validate_previous(source, provenance, 13)
        for build in (11, 12):
            with self.assertRaises(ValueError): self.m.validate_previous(source, provenance, build)
        for field, value in [('identifier', 'dev.asterionveyra.source'), ('sourceURL', 'https://example.com/source.json')]:
            changed = copy.deepcopy(source); changed[field] = value
            with self.assertRaises(ValueError): self.m.validate_previous(changed, provenance, 13)
        changed = copy.deepcopy(provenance); changed['ipaSHA256'] = '0' * 64
        with self.assertRaises(ValueError): self.m.validate_previous(source, changed, 13)

    def test_prior_version_provenance_survives_marketing_version_bump(self):
        source = self.render()
        _, run, _ = self.fixture()
        proof = self.m.provenance(source, run, self.release())
        with patch.object(self.m.release_checks, 'VERSION', '0.4.1'):
            self.m.validate_previous(source, proof, 13)
        for version in ('../invalid', '', '0.4.0?evil'):
            corrupt = copy.deepcopy(source)
            corrupt['apps'][0]['versions'][0]['version'] = version
            with self.assertRaises(ValueError): self.m.validate_previous(corrupt, proof, 13)

    def test_advance_preserves_readme_and_writes_only_dedicated_preview_branch(self):
        calls = []
        def api(path, payload=None, method='GET'):
            calls.append((path, payload, method))
            if path == 'git/commits/' + 'd' * 40: return {'tree': {'sha': 'e' * 40}}
            if path == 'git/trees': return {'sha': 'f' * 40}
            if path == 'git/commits': return {'sha': 'a' * 40}
            return {}
        with patch.object(self.m, 'api', side_effect=api):
            self.m.advance('d' * 40, self.render(), {'schemaVersion': 1})
        self.assertEqual(calls[1][1]['base_tree'], 'e' * 40)
        self.assertEqual({e['path'] for e in calls[1][1]['tree']}, {'source.json', 'provenance.json'})
        self.assertEqual(calls[-1], ('git/refs/heads/jarvis-preview-source', {'sha': 'a' * 40, 'force': False}, 'PATCH'))
        self.assertFalse(any('sidestore-source' in path or path.startswith('releases') for path, _, _ in calls))

    def test_post_commit_verification_retries_only_reads_and_never_masks_branch_move(self):
        self.assertTrue(hasattr(self.m, 'verify_publication'), 'Bounded publication verification needed')
        target = self.folder / 'public.json'; source = self.render(); reads = []
        def download(url, path, limit):
            reads.append(url)
            path.write_bytes(b'stale' if len(reads) == 1 else self.m.source_bytes(source))
        with patch.object(self.m, 'api', return_value={'object': {'sha': 'c' * 40}}), patch.object(self.m, 'download_public', side_effect=download), patch.object(self.m.time, 'sleep'):
            self.m.verify_publication('c' * 40, source, target)
        self.assertEqual(len(reads), 2)
        reads.clear()
        with patch.object(self.m, 'api', return_value={'object': {'sha': 'd' * 40}}), patch.object(self.m, 'download_public', side_effect=download), self.assertRaisesRegex(ValueError, 'branch changed'):
            self.m.verify_publication('c' * 40, source, target)
        self.assertEqual(reads, [])

    def test_post_commit_failure_is_explicit_and_does_not_repeat_writes(self):
        self.assertTrue(hasattr(self.m, 'verify_publication'), 'Bounded publication verification needed')
        reads = []
        def download(url, path, limit):
            reads.append(url); path.write_bytes(b'stale')
        with patch.object(self.m, 'api', return_value={'object': {'sha': 'c' * 40}}), patch.object(self.m, 'download_public', side_effect=download), patch.object(self.m.time, 'sleep'), self.assertRaisesRegex(ValueError, 'committed.*unverified'):
            self.m.verify_publication('c' * 40, self.render(), self.folder / 'public.json')
        self.assertEqual(len(reads), 3)

    def exercise_publish(self, fault=None):
        env, run, jobs = self.fixture()
        run['run_started_at'] = '2026-11-10T16:00:00Z'
        env['GH_TOKEN'] = 'test-fixture'
        notes = self.folder / 'VERIFICATION.md'; notes.write_text('Fixture verification only.')
        sums = self.folder / 'SHA256SUMS'
        sums.write_text(hashlib.sha256(self.ipa.read_bytes()).hexdigest() + '  Jarvis-unsigned.ipa\n' + hashlib.sha256(notes.read_bytes()).hexdigest() + '  VERIFICATION.md\n')
        release = self.release()
        for asset in release['assets']:
            data = (self.folder / asset['name']).read_bytes()
            asset.update(size=len(data), digest='sha256:' + hashlib.sha256(data).hexdigest())
        for key, name in [('IPA', 'Jarvis-unsigned.ipa'), ('NOTES', 'VERIFICATION.md'), ('SUMS', 'SHA256SUMS')]:
            env['EXPECTED_' + key + '_SHA256'] = hashlib.sha256((self.folder / name).read_bytes()).hexdigest()
        prior_ipa = self.folder / 'prior.ipa'
        ipa_fixture(prior_ipa, dict(self.info, CFBundleVersion='11'))
        prior_source = self.m.render_source(prior_ipa, 11, 'b' * 40, '2026-11-09T12:00:00Z')
        prior_run = dict(run, run_number=11, head_sha='b' * 40)
        prior_proof = self.m.provenance(prior_source, prior_run, dict(release, id=499))
        calls = []; published = {}; run_reads = 0; advanced = False
        def api(path, payload=None, method='GET'):
            nonlocal run_reads, advanced
            calls.append((path, payload, method))
            if path == 'actions/runs/123':
                run_reads += 1
                return dict(run, run_attempt=2) if fault == 'attempt-changed' and run_reads > 1 else copy.deepcopy(run)
            if path == 'git/ref/heads/feature/unified-assistant-planning': return {'object': {'sha': 'a' * 40}}
            if path == 'releases/tags/jarvis-v0.4.0-build-12': return copy.deepcopy(release)
            if path == 'git/ref/tags/jarvis-v0.4.0-build-12': return {'object': {'sha': 'a' * 40, 'type': 'commit'}}
            if path == 'git/ref/heads/jarvis-preview-source': return {'object': {'sha': ('c' if advanced else 'd') * 40, 'type': 'commit'}}
            if path.startswith('contents/'):
                document = prior_source if path.startswith('contents/source.json?') else prior_proof
                return {'encoding': 'base64', 'content': base64.b64encode(self.m.source_bytes(document)).decode()}
            if path == 'git/commits/' + 'd' * 40: return {'tree': {'sha': 'e' * 40}}
            if path == 'git/trees':
                published.update({entry['path']: entry['content'].encode() for entry in payload['tree']})
                return {'sha': 'f' * 40}
            if path == 'git/commits': return {'sha': 'c' * 40}
            if path == 'git/refs/heads/jarvis-preview-source':
                if fault == 'race': raise ValueError('GitHub rejected non-fast-forward')
                advanced = True
                return {}
            raise AssertionError(path)
        def pages(path):
            if path.startswith('actions/'): return [{'jobs': copy.deepcopy(jobs)}]
            if path == 'releases?per_page=100':
                return [[dict(release, tag_name='jarvis-v0.4.0-build-13')]] if fault == 'newer-release' else [[release]]
            raise AssertionError(path)
        def download(url, path, limit):
            if url.startswith(self.m.SOURCE_URL):
                self.assertEqual(url, self.m.SOURCE_URL + '?commit=' + 'c' * 40, 'Public branch verification must avoid stale raw-cache bytes')
                path.write_bytes(published['source.json']); return
            if url.endswith('/AppIcon-1024.png'):
                shutil.copyfile(SCRIPTS.parent / 'App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png', path); return
            name = url.rsplit('/', 1)[-1]
            shutil.copyfile(self.folder / name, path)
            if fault == 'tampered-ipa' and name == 'Jarvis-unsigned.ipa': path.write_bytes(b'tampered')
        if fault == 'missing-hash': env.pop('EXPECTED_IPA_SHA256')
        with patch.object(self.m, 'api', side_effect=api), patch.object(self.m, 'pages', side_effect=pages), patch.object(self.m, 'download_public', side_effect=download):
            if fault:
                with self.assertRaises(ValueError): self.m.publish(env)
            else:
                self.assertEqual(self.m.publish(env), 'https://raw.githubusercontent.com/R347H4CK3R/GhostAI/jarvis-preview-source/source.json')
        return calls, published

    def test_complete_publication_verifies_assets_and_atomically_advances_only_preview(self):
        calls, files = self.exercise_publish()
        writes = [(path, payload, method) for path, payload, method in calls if method != 'GET']
        self.assertEqual([path for path, _, _ in writes], ['git/trees', 'git/commits', 'git/refs/heads/jarvis-preview-source'])
        self.assertEqual(writes[-1][1]['force'], False)
        source = json.loads(files['source.json']); proof = json.loads(files['provenance.json'])
        self.assertEqual(source['apps'][0]['versions'][0]['buildVersion'], '12')
        self.assertEqual(proof['sourceSHA256'], hashlib.sha256(files['source.json']).hexdigest())

    def test_failed_verification_never_mutates_source(self):
        for fault in ['attempt-changed', 'newer-release', 'missing-hash', 'tampered-ipa']:
            with self.subTest(fault=fault):
                calls, files = self.exercise_publish(fault)
                self.assertEqual(files, {})
                self.assertFalse(any(method != 'GET' for _, _, method in calls))

    def test_racing_source_update_is_not_force_retried(self):
        calls, _ = self.exercise_publish('race')
        refs = [(path, payload, method) for path, payload, method in calls if method == 'PATCH']
        self.assertEqual(len(refs), 1)
        self.assertEqual(refs[0][1]['force'], False)

if __name__ == '__main__': unittest.main()
