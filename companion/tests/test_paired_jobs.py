"""Paired execution must use the existing bounded executor and actual files."""
import importlib.util
import json
from unittest.mock import patch
from companion.tests.test_paired_host import HostCase,PROJECT,encoded
from companion.tests.test_autonomy import plan,read,complete
SPEC=importlib.util.find_spec('companion.paired_jobs')
if SPEC:from companion.paired_jobs import run_next

class ExecutionTests(HostCase):
    def setUp(self):
        super().setUp();self.assertIsNotNone(SPEC,'paired executor must be reconstructed');self.enroll()
    def submit(self):return self.request('/v1/jobs/submit',self.submission())[1]
    def get(self,job):return self.request('/v1/jobs/get',dict(v=1,project_id=PROJECT,job_id=job['job_id']))[1]
    def transport(self,replies):
        replies=iter(replies)
        def respond(raw):
            payload=json.loads(raw);self.assertEqual(json.loads(payload['prompt'])['project_memories'],[])
            return encoded(dict(done=True,response=json.dumps(next(replies))))
        return respond
    def test_signed_submission_runs_real_file_read_and_queryable_result(self):
        job=self.submit();run_next(self.host,transport=self.transport([plan(read()),complete('Synthetic observation.')]))
        result=self.get(job);self.assertEqual(result['status'],'completed');self.assertEqual(result['summary'],'Synthetic observation.')
        self.assertEqual(result['counters']['tool_calls'],1);self.assertIsNone(run_next(self.host,transport=lambda _:self.fail('must not rerun')))
    def test_model_cannot_expand_read_only_scope(self):
        job=self.submit()
        proposal=plan({'tool':'write_draft','path':'out.txt','content':'Not authorized'},writes=['out.txt'])
        run_next(self.host,transport=self.transport([proposal]))
        self.assertEqual(self.get(job)['status'],'refused');self.assertFalse((self.work/'out.txt').exists())
    def test_revoked_queued_job_never_contacts_model(self):
        self.submit();self.host.revoke_device(self.device)
        result=run_next(self.host,transport=lambda _:self.fail('revoked job executed'))
        self.assertEqual(result['status'],'cancelled')
    def test_revocation_during_model_response_stops_before_file_read(self):
        job=self.submit()
        def respond(_):
            self.host.revoke_device(self.device)
            return encoded(dict(done=True,response=json.dumps(plan(read()))))
        result=run_next(self.host,transport=respond)
        self.assertEqual(result['status'],'cancelled');self.assertEqual(result['counters']['tool_calls'],0)
    def test_restart_recovers_accepted_queue_without_fresh_job_id(self):
        job=self.submit();self.reopen()
        run_next(self.host,transport=self.transport([complete('No files needed.')]))
        self.assertEqual(self.get(job)['status'],'completed')
    def test_missing_checkpoint_for_previously_running_job_never_reexecutes(self):
        job=self.submit()
        with self.host.transaction() as db:db.execute("UPDATE jobs SET status='running'")
        result=run_next(self.host,transport=lambda _:self.fail('uncertain job restarted'))
        self.assertEqual(result['status'],'failed');self.assertEqual(result['error_code'],'checkpoint_unavailable')
    def test_corrupt_job_snapshot_is_failed_before_dispatch(self):
        self.submit()
        with self.host.transaction() as db:db.execute("UPDATE jobs SET config='{}'")
        result=run_next(self.host,transport=lambda _:self.fail('invalid snapshot executed'))
        self.assertEqual(result['status'],'failed')
    def test_expired_queue_does_not_execute(self):
        self.submit()
        with self.host.transaction() as db:db.execute('UPDATE jobs SET created=0')
        result=run_next(self.host,transport=lambda _:self.fail('expired job executed'))
        self.assertEqual(result['status'],'expired')
    def test_corrupt_persisted_job_identifier_cannot_escape_private_checkpoint_directory(self):
        self.submit()
        with self.host.transaction() as db:db.execute("UPDATE jobs SET job_id='../outside-state'")
        result=run_next(self.host,transport=self.transport([complete('Synthetic only')]))
        self.assertEqual(result['status'],'failed')
        self.assertEqual(result['error_code'],'invalid_persisted_identity')
        self.assertFalse((self.root/'outside-state.json').exists())
        self.assertFalse((self.root/'outside-state.json.lock').exists())
    def test_terminal_checkpoint_recovers_lost_final_database_publication_without_reexecution(self):
        job=self.submit();run_next(self.host,transport=self.transport([complete('Durable synthetic result')]))
        with self.host.transaction() as db:db.execute("UPDATE jobs SET status='running',summary=NULL WHERE job_id=?",(job['job_id'],))
        result=run_next(self.host,transport=lambda _:self.fail('terminal checkpoint must not execute again'))
        self.assertEqual(result['status'],'completed');self.assertEqual(result['summary'],'Durable synthetic result')
        self.assertIsNone(run_next(self.host,transport=lambda _:self.fail('recovery must not loop')))
    def test_non_text_persisted_snapshot_is_failed_before_any_model_or_tool(self):
        self.submit()
        with self.host.transaction() as db:db.execute('UPDATE jobs SET config=?',(b'{}',))
        result=run_next(self.host,transport=lambda _:self.fail('malformed snapshot executed'))
        self.assertEqual(result['status'],'failed');self.assertEqual(result['error_code'],'invalid_snapshot')
    def test_actual_process_exit_during_initial_checkpoint_link_fails_closed(self):
        import os
        from pathlib import Path
        import subprocess
        import sys
        job=self.submit();self.host.close()
        source='''import json,os,sys
from unittest.mock import patch
from companion.paired_host import PairedHost
from companion.paired_jobs import run_next
host=PairedHost(sys.argv[1],sys.argv[2],[json.loads(sys.argv[3])])
original=os.link
def interrupted(*args,**kwargs):
 original(*args,**kwargs)
 os._exit(77)
with patch.object(os,'link',interrupted):
 run_next(host,transport=lambda _:b'{}')
'''
        result=subprocess.run([sys.executable,'-c',source,str(self.state),self.host.host_id,json.dumps(self.project)],cwd=Path(__file__).resolve().parents[2],capture_output=True,timeout=10)
        self.assertEqual(result.returncode,77,result.stderr.decode(errors='replace'))
        checkpoint=self.state/(job['job_id']+'.json');self.assertEqual(checkpoint.stat().st_nlink,2)
        self.reopen();result=run_next(self.host,transport=lambda _:self.fail('uncertain checkpoint reexecuted'))
        self.assertEqual(result['status'],'failed');self.assertEqual(result['error_code'],'checkpoint_unavailable')
