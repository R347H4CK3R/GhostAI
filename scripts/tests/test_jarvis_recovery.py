import copy
import importlib.util
import sys
import hashlib
import plistlib
import tempfile
import zipfile
import os
from unittest.mock import patch
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue((SCRIPTS/'jarvis_recover_build6.py').exists(), 'Recovery verifier is missing')
        import jarvis_recover_build6 as m
        self.m=m

    def fixture(self):
        m=self.m
        run=dict(m.RUN_FIELDS, repository={'full_name':m.REPOSITORY,'private':False},
                 head_repository={'full_name':m.REPOSITORY})
        jobs=[dict(id=i, name=n, run_id=m.RUN_ID, run_attempt=1, head_sha=m.SHA,
                   status='completed', conclusion='failure' if n=='finalize' else 'success',
                   steps=[dict(name=s,status='completed',conclusion='failure' if n=='finalize' and s==m.FAILED_STEP else 'success') for s in steps])
              for n,(i,steps) in m.JOBS.items()]
        release=dict(id=m.RELEASE_ID,tag_name=m.TAG,draft=True,prerelease=True,published_at=None,
                     assets=[dict(id=i,name=n,size=z,digest='sha256:'+h,state='uploaded') for n,(i,z,h) in m.ASSETS.items()])
        return run,jobs,release

    def test_exact_verified_run_and_draft_pass(self):
        run,jobs,release=self.fixture()
        self.m.validate_origin(run,jobs)
        self.m.validate_release(release)

    def test_rejects_each_origin_field_drift(self):
        for field in self.m.RUN_FIELDS:
            run,jobs,_=self.fixture();run[field]='changed'
            with self.subTest(field=field),self.assertRaises(ValueError):self.m.validate_origin(run,jobs)

    def test_rejects_every_job_and_step_drift(self):
        _,baseline,_=self.fixture()
        for i,j in enumerate(baseline):
            for field in ('id','name','run_id','run_attempt','head_sha','status','conclusion'):
                run,jobs,_=self.fixture();jobs[i][field]='changed'
                with self.subTest(job=j['name'],field=field),self.assertRaises(ValueError):self.m.validate_origin(run,jobs)
            for k,s in enumerate(j['steps']):
                run,jobs,_=self.fixture();jobs[i]['steps'][k]['conclusion']='skipped'
                with self.subTest(step=s['name']),self.assertRaises(ValueError):self.m.validate_origin(run,jobs)
        run,jobs,_=self.fixture()
        for bad in (jobs[:-1],jobs+[jobs[0]]):
            with self.assertRaises(ValueError):self.m.validate_origin(run,bad)

    def test_rejects_draft_or_asset_drift(self):
        for field in ('id','tag_name','draft','prerelease','published_at'):
            _,_,release=self.fixture();release[field]='changed'
            with self.subTest(field=field),self.assertRaises(ValueError):self.m.validate_release(release)
        for index in range(3):
            for field in ('id','name','size','digest','state'):
                _,_,release=self.fixture();release['assets'][index][field]='changed'
                with self.subTest(index=index,field=field),self.assertRaises(ValueError):self.m.validate_release(release)
        _,_,release=self.fixture();release['assets'].append(release['assets'][0])
        with self.assertRaises(ValueError):self.m.validate_release(release)

    def exercise_main(self, failure=None):
        m=self.m
        env=dict(GITHUB_REPOSITORY=m.REPOSITORY,GITHUB_REF='refs/heads/'+m.RECOVERY_BRANCH,
                 GITHUB_WORKFLOW_REF=m.REPOSITORY+'/'+m.RECOVERY_WORKFLOW+'@refs/heads/'+m.RECOVERY_BRANCH,
                 GITHUB_RUN_ATTEMPT='1',GITHUB_EVENT_NAME='push',GH_TOKEN='test-not-a-credential')
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp)
            ipa=folder/'Jarvis-unsigned.ipa'
            info=dict(CFBundleIdentifier='dev.asterionveyra.assistant',CFBundleDisplayName='Jarvis',
                      CFBundleExecutable='AsterionVeyra',CFBundleShortVersionString='0.4.0',
                      CFBundleVersion='6',CFBundleSupportedPlatforms=['iPhoneOS'])
            with zipfile.ZipFile(ipa,'w') as z:
                z.writestr('Payload/AsterionVeyra.app/Info.plist',plistlib.dumps(info))
                z.writestr('Payload/AsterionVeyra.app/AsterionVeyra',b'executable')
            (folder/'VERIFICATION.md').write_text('verification fixture')
            (folder/'SHA256SUMS').write_text(''.join(hashlib.sha256((folder/n).read_bytes()).hexdigest()+'  '+n+'\n' for n in ('Jarvis-unsigned.ipa','VERIFICATION.md')))
            assets={n:(i,(folder/n).stat().st_size,hashlib.sha256((folder/n).read_bytes()).hexdigest()) for n,(i,_,_) in m.ASSETS.items()}
            mutations=[]
            with patch.object(m,'ASSETS',assets):
                run,jobs,release=self.fixture()
                lookup=[0];checks=[0]
                def api(path,*args):
                    if '--method' in args:
                        mutations.append((path,args))
                        if failure=='uncertain':raise RuntimeError('Connection lost after PATCH')
                        public=copy.deepcopy(release);public.update(draft=False,published_at='now');return public
                    if path==f'actions/runs/{m.RUN_ID}':
                        checks[0]+=1
                        if failure=='run_drift' and checks[0]>1:return dict(run,run_attempt=2)
                        return run
                    if '/jobs?' in path:return [{'jobs':jobs}]
                    if path.startswith('git/ref/'):return {'object':{'type':'commit','sha':m.SHA}}
                    if path==f'releases/{m.RELEASE_ID}':
                        public=copy.deepcopy(release);public.update(draft=False,published_at='now');return public
                    raise AssertionError(path)
                def draft(tag):
                    lookup[0]+=1
                    result=copy.deepcopy(release)
                    if lookup[0]>1:
                        result['assets'][0]['download_count']=1
                        if failure=='release_drift':result['body']='changed'
                    return result
                def download(identity,path):
                    content=(folder/path.name).read_bytes()
                    path.write_bytes(b'tampered' if failure=='hash' else content)
                with patch.dict(os.environ,env,clear=True),patch.object(m,'api',side_effect=api),patch.object(m,'draft_by_tag',side_effect=draft),patch.object(m,'download_asset',side_effect=download):
                    if failure:
                        with self.assertRaises((ValueError,RuntimeError)):m.main()
                    else:m.main()
            return mutations

    def test_main_only_patches_exact_release_after_all_checks(self):
        calls=self.exercise_main()
        self.assertEqual(len(calls),1)
        self.assertEqual(calls[0][0],f'releases/{self.m.RELEASE_ID}')
        self.assertIn('make_latest=false',calls[0][1])
        self.assertIn('draft=false',calls[0][1])
        self.assertIn('prerelease=true',calls[0][1])

    def test_main_stops_before_mutation_on_hash_or_evidence_drift(self):
        for failure in ('hash','run_drift','release_drift'):
            with self.subTest(failure=failure):self.assertEqual(self.exercise_main(failure),[])

    def test_uncertain_publication_is_never_retried(self):
        self.assertEqual(len(self.exercise_main('uncertain')),1)

    def test_rejects_untrusted_recovery_context(self):
        m=self.m
        env=dict(GITHUB_REPOSITORY=m.REPOSITORY,GITHUB_REF='refs/heads/'+m.RECOVERY_BRANCH,
                 GITHUB_WORKFLOW_REF=m.REPOSITORY+'/'+m.RECOVERY_WORKFLOW+'@refs/heads/'+m.RECOVERY_BRANCH,
                 GITHUB_RUN_ATTEMPT='1',GITHUB_EVENT_NAME='push')
        m.validate_recovery_context(env)
        for field in env:
            bad=dict(env);bad[field]='changed'
            with self.subTest(field=field),self.assertRaises(ValueError):m.validate_recovery_context(bad)

if __name__=='__main__':unittest.main()
