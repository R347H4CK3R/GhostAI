"""Real SQLite and signatures with disposable synthetic workspace only."""
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
import uuid
from cryptography.hazmat.primitives.asymmetric import ec
from companion.autonomy import DEFAULT_LIMITS
from companion.tests.test_paired_protocol import HOST,b64,public,sign

PROJECT='55555555-5555-4555-8555-555555555555'
SPEC=importlib.util.find_spec('companion.paired_host')
if SPEC:
    from companion.paired_host import PairedHost
    from companion import paired_protocol as wire

def encoded(value):return json.dumps(value,ensure_ascii=False,separators=(',',':')).encode()

class HostCase(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(SPEC,'paired host must be reconstructed')
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve();self.state=self.root/'state';self.state.mkdir(mode=0o700)
        self.work=self.root/'work';self.work.mkdir();(self.work/'input.txt').write_text('Synthetic observation.')
        self.project=dict(project_id=PROJECT,label='Synthetic',workspace=str(self.work),permission_revision=1,model='local-model',trust_local_model=True,limits=dict(DEFAULT_LIMITS))
        self.host=PairedHost(self.state,HOST,[self.project],create=True);self.addCleanup(lambda:self.host.close())
        self.key=ec.derive_private_key(1,ec.SECP256R1());self.sequence=0;self.device=None
    def enrollment(self):
        self.invite=self.host.create_invitation([PROJECT])
        body=dict(v=1,host_id=HOST,invite_id=self.invite['invite_id'],client_nonce=b64(os.urandom(32)),device_name='Synthetic phone',client_public_key=public(self.key))
        frame=wire.pair_message(body)
        body['proof']=b64(hmac.digest(wire.decode64(self.invite['invite_secret'],32),frame,'sha256'))
        body['signature']=sign(self.key,frame+body['proof'].encode()+b'\n')
        self.begin=body
        status,result=self.host.handle('/v1/pair/begin',encoded(body),[])
        self.assertEqual(status,200);self.device=result['device_id'];return result
    def enroll(self):
        pending=self.enrollment();self.host.approve_device(self.device,pending['safety_code']);return pending
    def request(self,route,body,sequence=None):
        if sequence is None:self.sequence+=1;sequence=self.sequence
        raw=encoded(body);rid=str(uuid.uuid4())
        headers=[('X-Veyra-Host',HOST),('X-Veyra-Device',self.device),('X-Veyra-Sequence',str(sequence)),('X-Veyra-Request',rid),('X-Veyra-Signature',sign(self.key,wire.request_message(HOST,self.device,sequence,rid,route,raw)))]
        return self.host.handle(route,raw,headers)
    def submission(self,**changes):
        return dict(dict(v=1,project_id=PROJECT,submission_id=str(uuid.uuid4()),goal='Read input.txt',requested_write_paths=[],limits=dict(DEFAULT_LIMITS)),**changes)
    def reopen(self):
        self.host.close();self.host=PairedHost(self.state,HOST,[self.project])

class EnrollmentTests(HostCase):
    def test_local_approval_required_and_paired_status_lists_exact_grant(self):
        pending=self.enrollment()
        self.assertEqual(self.request('/v1/pair/status',{'v':1})[1]['state'],'pending')
        self.assertEqual(self.request('/v1/jobs/submit',self.submission())[0],403)
        with self.assertRaises(ValueError):self.host.approve_device(self.device,'wrong')
        self.host.approve_device(self.device,pending['safety_code'])
        result=self.request('/v1/pair/status',{'v':1})[1]
        self.assertEqual(result['state'],'active');self.assertEqual(result['grants'][0]['capabilities'],['jobs.read_only'])
        self.assertNotIn('workspace',result['grants'][0])
    def test_replay_highwater_survives_restart_and_bad_body_burns_sequence(self):
        self.enroll();self.assertEqual(self.request('/v1/pair/status',{'v':1},sequence=8)[0],200)
        self.reopen();self.assertEqual(self.request('/v1/pair/status',{'v':1},sequence=8)[0],409)
        self.assertEqual(self.request('/v1/pair/status',{'v':1,'extra':1},sequence=9)[0],400)
        self.assertEqual(self.request('/v1/pair/status',{'v':1},sequence=9)[0],409)
    def test_pending_enrollment_does_not_survive_host_restart(self):
        pending=self.enrollment();self.reopen()
        with self.assertRaises(ValueError):self.host.approve_device(self.device,pending['safety_code'])
        self.assertEqual(self.request('/v1/pair/status',{'v':1})[0],403)
    def test_identical_begin_retries_are_idempotent_and_changes_rejected(self):
        first=self.enrollment()
        self.assertEqual(self.host.handle('/v1/pair/begin',encoded(self.begin),[]),(200,first))
        changed=dict(self.begin,device_name='different')
        self.assertEqual(self.host.handle('/v1/pair/begin',encoded(changed),[])[0],403)
    def test_submission_retries_survive_restart_without_creating_another_job(self):
        self.enroll();body=self.submission();status,first=self.request('/v1/jobs/submit',body)
        self.assertEqual(status,202);self.reopen()
        self.assertEqual(self.request('/v1/jobs/submit',body)[1]['job_id'],first['job_id'])
        self.assertEqual(self.request('/v1/jobs/submit',dict(body,goal='Changed'))[0],409)
        with self.host.transaction() as db:self.assertEqual(db.execute('SELECT count(*) FROM jobs').fetchone()[0],1)
    def test_revocation_rejects_future_requests_and_marks_queued_work(self):
        self.enroll();_,job=self.request('/v1/jobs/submit',self.submission());self.host.revoke_device(self.device)
        self.assertEqual(self.request('/v1/jobs/get',dict(v=1,project_id=PROJECT,job_id=job['job_id']))[0],403)
        with self.host.transaction() as db:self.assertEqual(db.execute('SELECT cancel_requested FROM jobs').fetchone()[0],1)
    def test_write_shell_unknown_fields_and_excess_budgets_are_rejected(self):
        self.enroll()
        for body in (self.submission(requested_write_paths=['out.txt']),self.submission(shell='whoami'),self.submission(limits=dict(DEFAULT_LIMITS,max_iterations=9)),self.submission(project_id=str(uuid.uuid4()))):
            self.assertIn(self.request('/v1/jobs/submit',body)[0],(400,403))
        with self.host.transaction() as db:self.assertEqual(db.execute('SELECT count(*) FROM jobs').fetchone()[0],0)
    def test_cancellation_is_immutable_and_only_for_owned_project_job(self):
        self.enroll();_,job=self.request('/v1/jobs/submit',self.submission())
        body=dict(v=1,project_id=PROJECT,job_id=job['job_id'],cancellation_id=str(uuid.uuid4()))
        self.assertTrue(self.request('/v1/jobs/cancel',body)[1]['cancel_requested'])
        self.assertTrue(self.request('/v1/jobs/cancel',body)[1]['cancel_requested'])
        self.assertEqual(self.request('/v1/jobs/get',dict(v=1,project_id=str(uuid.uuid4()),job_id=job['job_id']))[0],403)
    def test_queue_capacity_is_finite_and_durable(self):
        self.enroll()
        for _ in range(4):self.assertEqual(self.request('/v1/jobs/submit',self.submission())[0],202)
        self.assertEqual(self.request('/v1/jobs/submit',self.submission())[0],429)
    def test_corrupt_persisted_state_returns_bounded_error_not_raw_data(self):
        self.enroll()
        with self.host.transaction() as db:db.execute("UPDATE devices SET grants='PRIVATE-MARKER'")
        status,result=self.request('/v1/pair/status',{'v':1})
        self.assertEqual(status,503);self.assertNotIn('PRIVATE-MARKER',json.dumps(result))
    def test_failed_commit_never_acknowledges_or_partially_accepts_submission(self):
        import sqlite3
        from unittest.mock import patch
        self.enroll();body=self.submission();original=self.host._connect
        class FailingCommit:
            def __init__(self):self.db=original()
            def __getattr__(self,name):return getattr(self.db,name)
            def commit(self):raise sqlite3.OperationalError('synthetic commit failure')
        with patch.object(self.host,'_connect',side_effect=FailingCommit):
            self.assertEqual(self.request('/v1/jobs/submit',body,sequence=1)[0],503)
        with self.host.transaction() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM jobs').fetchone()[0],0)
            self.assertEqual(db.execute('SELECT highwater FROM devices').fetchone()[0],0)
        self.assertEqual(self.request('/v1/jobs/submit',body,sequence=1)[0],202)
