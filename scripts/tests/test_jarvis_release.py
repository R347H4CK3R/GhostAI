import copy
import importlib.util
import plistlib
import tempfile
import unittest
import zipfile
import warnings
import shutil
import os
from unittest.mock import patch
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'jarvis_release.py'

class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.exists(), 'release verifier must exist')
        spec = importlib.util.spec_from_file_location('jarvis_release', SCRIPT)
        self.m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.m)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'Jarvis-unsigned.ipa'
        self.info = dict(CFBundleIdentifier='dev.asterionveyra.assistant', CFBundleDisplayName='Jarvis', CFBundleExecutable='AsterionVeyra', CFBundleShortVersionString='0.4.0', CFBundleVersion='12', CFBundleSupportedPlatforms=['iPhoneOS'])
    def ipa(self, info=None, extra=None):
        with zipfile.ZipFile(self.path, 'w') as z:
            z.writestr('Payload/AsterionVeyra.app/Info.plist', plistlib.dumps(info or self.info))
            z.writestr('Payload/AsterionVeyra.app/AsterionVeyra', b'\xcf\xfa\xed\xfeexecutable')
            if extra:
                with warnings.catch_warnings():
                    warnings.simplefilter('ignore', UserWarning)
                    z.writestr(extra, b'bad')
        return self.path
    def test_accepts_expected_ipa(self):
        self.assertEqual(self.m.validate_ipa(self.ipa(), 12), self.info)
    def test_rejects_wrong_identity_version_build_or_platform(self):
        for key, value in [('CFBundleIdentifier','evil'), ('CFBundleDisplayName','Wrong'), ('CFBundleExecutable','Wrong'), ('CFBundleShortVersionString','0.3.4'), ('CFBundleVersion','11'), ('CFBundleSupportedPlatforms',['iPhoneSimulator'])]:
            with self.subTest(key=key):
                info = dict(self.info, **{key:value})
                with self.assertRaises(ValueError): self.m.validate_ipa(self.ipa(info), 12)
    def test_rejects_traversal_extra_app_duplicate_and_signing(self):
        for extra in ['../bad', 'Payload/Other.app/Info.plist', 'Payload/AsterionVeyra.app/Info.plist', 'Payload/AsterionVeyra.app/embedded.mobileprovision', 'Payload/AsterionVeyra.app/_CodeSignature/CodeResources']:
            with self.subTest(extra=extra), self.assertRaises(ValueError): self.m.validate_ipa(self.ipa(extra=extra), 12)
    def fixture(self):
        env = dict(GITHUB_REPOSITORY=self.m.REPOSITORY, GITHUB_REF='refs/heads/'+self.m.BRANCH, GITHUB_SHA='a'*40, GITHUB_RUN_ID='123', GITHUB_RUN_ATTEMPT='1', GITHUB_RUN_NUMBER='12', GITHUB_EVENT_NAME='push', GITHUB_WORKFLOW_REF=self.m.REPOSITORY+'/'+self.m.WORKFLOW+'@refs/heads/'+self.m.BRANCH)
        run = dict(id=123, run_attempt=1, run_number=12, repository={'full_name':self.m.REPOSITORY,'private':False}, head_repository={'full_name':self.m.REPOSITORY}, head_branch=self.m.BRANCH, head_sha='a'*40, path=self.m.WORKFLOW, event='push', status='in_progress', conclusion=None)
        jobs = [dict(name=n,status='completed',conclusion='success',run_attempt=1,head_sha='a'*40) for n in self.m.PREREQUISITES]
        jobs.append(dict(name='ios',status='in_progress',conclusion=None,run_attempt=1,head_sha='a'*40, steps=[dict(name=n,status='completed',conclusion='success') for n in self.m.NATIVE_GATES]))
        return env, run, jobs
    def test_accepts_current_run_with_completed_gates(self):
        self.assertEqual(self.m.validate_context(*self.fixture()),12)
    def test_rejects_untrusted_or_stale_run(self):
        for key,value in [('head_sha','b'*40),('event','pull_request'),('head_branch','main'),('path','.github/workflows/ios.yml'),('run_attempt',2),('run_number',11),('status','completed')]:
            env,run,jobs=self.fixture();run[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError): self.m.validate_context(env,run,jobs)
    def test_rejects_private_repository(self):
        env,run,jobs=self.fixture();run['repository']['private']=True
        with self.assertRaises(ValueError): self.m.validate_context(env,run,jobs)
    def test_rejects_missing_failed_skipped_duplicate_or_old_jobs(self):
        for change in ['missing','failed','skipped','duplicate','old']:
            env,run,jobs=self.fixture()
            if change=='missing': jobs.pop(0)
            elif change=='duplicate': jobs.append(copy.deepcopy(jobs[0]))
            elif change=='old': jobs[0]['run_attempt']=2
            else: jobs[0]['conclusion']=change
            with self.subTest(change=change),self.assertRaises(ValueError): self.m.validate_context(env,run,jobs)
    def test_rejects_native_gate_failure_or_omission(self):
        for name in self.m.NATIVE_GATES:
            env,run,jobs=self.fixture();jobs[-1]['steps']=[s for s in jobs[-1]['steps'] if s['name']!=name]
            with self.subTest(name=name),self.assertRaises(ValueError):self.m.validate_context(env,run,jobs)
    def test_checksum_detects_tampering(self):
        self.ipa(); manifest=self.m.checksum_manifest([self.path]);self.m.verify_checksums(Path(self.tmp.name),manifest)
        self.path.write_bytes(b'tampered')
        with self.assertRaises(ValueError): self.m.verify_checksums(Path(self.tmp.name),manifest)

    def publish(self, fail=None):
        env, run, jobs = self.fixture()
        env['GH_TOKEN'] = 'test-token-not-a-credential'
        env['GITHUB_OUTPUT'] = str(Path(self.tmp.name)/'step-output')
        self.ipa()
        calls = []
        def fake_api(path, *args):
            calls.append(('api',path,args))
            if path == 'actions/runs/123': return run
            if '/jobs?' in path: return [{'jobs':jobs}]
            if path.startswith('git/ref/heads/'):
                return {'object':{'sha': 'b'*40 if fail=='stale' else 'a'*40}}
            if path == 'git/refs':
                if fail=='existing': raise RuntimeError('422 existing reference')
                return {}
            if path.startswith('git/ref/tags/'):
                return {'object':{'sha':'b'*40 if fail=='tag' else 'a'*40, 'type':'commit', 'url':f'https://api.github.com/repos/{self.m.REPOSITORY}/git/commits/'+ 'a'*40}}
            raise AssertionError(path)
        def fake_gh(*args):
            calls.append(('gh',args))
            if args[:2] == ('release','create') and fail=='upload': raise RuntimeError('upload failed')
            if args[:2] == ('release','download'):
                dest=Path(args[args.index('--dir')+1])
                for filename in ('Jarvis-unsigned.ipa','SHA256SUMS','VERIFICATION.md'):
                    shutil.copyfile(filename,dest/filename)
                if fail=='hash': (dest/'Jarvis-unsigned.ipa').write_bytes(b'corrupt')
            return ''
        old=os.getcwd()
        try:
            os.chdir(self.tmp.name)
            with patch.dict(os.environ,env,clear=True),patch.object(self.m,'api',side_effect=fake_api),patch.object(self.m,'gh',side_effect=fake_gh):
                if fail:
                    with self.assertRaises((ValueError,RuntimeError)): self.m.main()
                else: self.m.main()
        finally: os.chdir(old)
        return calls
    def test_publish_verifies_download_before_publishing_prerelease(self):
        calls=self.publish()
        gh_calls=[c[1] for c in calls if c[0]=='gh']
        self.assertEqual([c[1] for c in gh_calls],['create','download'])
        self.assertIn('--draft',gh_calls[0])
        self.assertIn('--verify-tag',gh_calls[0])
        self.assertIn('--latest=false',gh_calls[0])
        self.assertIn('--prerelease',gh_calls[0])
        self.assertFalse(any(c[:2]==('release','edit') for c in gh_calls))
        self.assertFalse(any('--clobber' in c for c in gh_calls))
    def test_fail_closed_without_publishing_on_every_external_failure(self):
        for failure in ('stale','existing','tag','upload','hash'):
            with self.subTest(failure=failure):
                calls=self.publish(failure)
                self.assertFalse(any(c[0]=='gh' and c[1][:2]==('release','edit') for c in calls))
                if failure in ('stale','existing','tag'):
                    self.assertFalse(any(c[0]=='gh' for c in calls))

    def test_finalizer_requires_completed_successful_ios_job(self):
        env,run,jobs=self.fixture()
        with self.assertRaises(ValueError): self.m.validate_context(env,run,jobs,phase='finalize')
        jobs[-1].update(status='completed',conclusion='success')
        self.assertEqual(self.m.validate_context(env,run,jobs,phase='finalize'),12)
        jobs[-1]['conclusion']='failure'
        with self.assertRaises(ValueError): self.m.validate_context(env,run,jobs,phase='finalize')

    def finalize(self, failure=None):
        self.publish()
        env,run,jobs=self.fixture();jobs[-1].update(status='completed',conclusion='success')
        env['GH_TOKEN']='test-token-not-a-credential'
        for line in (Path(self.tmp.name)/'step-output').read_text().splitlines():
            key,value=line.split('=',1);env['EXPECTED_'+key.upper()]=value
        if failure=='missing_hash':env.pop('EXPECTED_IPA_SHA256')
        if failure=='failed_ios':jobs[-1]['conclusion']='failure'
        calls=[]
        def fake_api(path,*args):
            if path=='actions/runs/123':return run
            if '/jobs?' in path:return [{'jobs':jobs}]
            if path.startswith('git/ref/'):
                return {'object':{'sha':'b'*40 if failure=='tag' and '/tags/' in path else 'a'*40,'type':'commit','url':f'https://api.github.com/repos/{self.m.REPOSITORY}/git/commits/'+'a'*40}}
            if path.startswith('releases/tags/'):
                return {'draft':failure!='published','prerelease':True,'tag_name':'jarvis-v0.4.0-build-12','assets':[{'name':n} for n in ('Jarvis-unsigned.ipa','SHA256SUMS','VERIFICATION.md')]}
            raise AssertionError(path)
        def fake_gh(*args):
            calls.append(args)
            if args[:2]==('release','download'):
                dest=Path(args[args.index('--dir')+1])
                for n in ('Jarvis-unsigned.ipa','SHA256SUMS','VERIFICATION.md'):shutil.copyfile(Path(self.tmp.name)/n,dest/n)
                if failure=='hash':(dest/'Jarvis-unsigned.ipa').write_bytes(b'tampered')
            return ''
        with patch.dict(os.environ,env,clear=True),patch.object(self.m,'api',side_effect=fake_api),patch.object(self.m,'gh',side_effect=fake_gh):
            if failure:
                with self.assertRaises(ValueError):self.m.main('finalize')
            else:self.m.main('finalize')
        return calls
    def test_finalizer_publishes_only_downloaded_verified_draft(self):
        calls=self.finalize()
        self.assertEqual([c[1] for c in calls],['download','edit'])
        self.assertIn('--draft=false',calls[-1]);self.assertIn('--latest=false',calls[-1]);self.assertIn('--prerelease',calls[-1])
    def test_finalizer_never_publishes_failed_ios_wrong_tag_or_changed_assets(self):
        for failure in ('missing_hash','failed_ios','tag','published','hash'):
            with self.subTest(failure=failure):
                calls=self.finalize(failure)
                self.assertFalse(any(c[:2]==('release','edit') for c in calls))

if __name__ == '__main__': unittest.main()
