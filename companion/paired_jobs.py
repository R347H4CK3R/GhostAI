"""One local dispatcher; fixed bounded read-only executor, no imported memories."""
import json
import math
import os
import sqlite3
from .autonomy import AutonomousJob,read_job,_job_lock
from .core import Memory
from .paired_host import JOB_TERMINAL,QUEUE_TTL,counters,dump,regular
from . import paired_protocol as wire

class JobAudit(Memory):
    def search(self,project,query):return []  # Grants never imply access to old notes.

class Cancellation:
    def __init__(self,host,job):self.host=host;self.job=job
    def is_set(self):return not self.host.authorized_job(self.job)

class PairedJob(AutonomousJob):
    def __init__(self,host,row,snapshot,memory,transport):
        self.host=host;self.job_id=wire.identifier(row['job_id']);self.internal_id=row['internal_id']
        if self.internal_id is not None:wire.identifier(self.internal_id)
        project=snapshot['project']
        super().__init__(project['workspace'],memory,host.state_dir/(self.job_id+'.json'),trust_local_model=True,write_paths=(),limits=snapshot['limits'],cancel=Cancellation(host,self.job_id),transport=transport)
    def _save(self,*,create=False):
        wire.identifier(self.state['id'])
        if self.internal_id is not None and self.state['id']!=self.internal_id:raise wire.ProtocolError('checkpoint_unavailable')
        super()._save(create=create)
        self.publish()
    def publish(self):
        # A terminal checkpoint may outlive its final SQLite publication.
        # Republish its already validated state, never rerun a model or tool.
        wire.identifier(self.state['id'])
        if self.internal_id is not None and self.state['id']!=self.internal_id:raise wire.ProtocolError('checkpoint_unavailable')
        with self.host.transaction() as db:
            db.execute('UPDATE jobs SET internal_id=?,status=?,counters=?,summary=?,error_code=? WHERE job_id=?',(self.state['id'],self.state['status'],dump(counters(self.state)),self.state['summary'],'execution_stopped' if self.state['error'] else None,self.job_id))
        self.internal_id=self.state['id']

def finish(host,job,status,error=None):
    with host.transaction() as db:
        db.execute('UPDATE jobs SET status=?,error_code=? WHERE job_id=?',(status,error,job))
        return host.job_result(db.execute('SELECT * FROM jobs WHERE job_id=?',(job,)).fetchone())

def run_next(host,*,transport=None):
    """Synthetic model injection is local trusted code only, never a wire field."""
    with _job_lock(host.state_dir/'paired-dispatch.lock'):
        with host.transaction() as db:
            row=db.execute("SELECT * FROM jobs WHERE status IN ('starting','running','queued') ORDER BY CASE WHEN status='queued' THEN 1 ELSE 0 END,created,job_id LIMIT 1").fetchone()
            if row is None:return None
            row=dict(row)
        job_id=row['job_id']
        # SQLite is private but can be corrupted. Never derive a filesystem path
        # from a persisted identifier until every identity has been validated.
        try:
            for name in ('job_id','device_id','project_id','submission_id'):
                wire.identifier(row[name])
            if row['internal_id'] is not None:wire.identifier(row['internal_id'])
        except (ValueError,KeyError,TypeError):
            with host.transaction() as db:
                db.execute("UPDATE jobs SET status='failed',error_code='invalid_persisted_identity' WHERE job_id=?",(job_id,))
            return dict(v=1,status='failed',error_code='invalid_persisted_identity')
        try:
            if type(row['created']) not in (int,float) or not math.isfinite(row['created']) or row['created']<0:raise wire.ProtocolError()

            if type(row['config']) is not str or type(row['raw']) is not bytes:raise wire.ProtocolError()
            snapshot=wire.load_object(row['config'].encode());wire.exact(snapshot,('project','goal','limits'))
            project=host._validate_project(snapshot['project']);wire.text(snapshot['goal'],8192);wire.exact(snapshot['limits'],project['limits'])
            for name,value in snapshot['limits'].items():wire.integer(value,project['limits'][name])
            submitted=wire.load_object(row['raw']);wire.exact(submitted,('v','project_id','submission_id','goal','requested_write_paths','limits'));wire.version(submitted['v'])
            if submitted!=dict(v=1,project_id=row['project_id'],submission_id=row['submission_id'],goal=snapshot['goal'],requested_write_paths=[],limits=snapshot['limits']) or project['project_id']!=row['project_id']:raise wire.ProtocolError()
        except (ValueError,OSError,KeyError,TypeError):return finish(host,job_id,'failed','invalid_snapshot')
        if not host.authorized_job(job_id):return finish(host,job_id,'cancelled','access_revoked_or_cancelled')
        if row['status']=='queued' and host.clock()-row['created']>=QUEUE_TTL:return finish(host,job_id,'expired','queue_expired')
        path=host.state_dir/(job_id+'.json');resume=row['status']!='queued'
        if resume:
            try:
                checkpoint=read_job(path)
                wire.identifier(checkpoint['id'])
                if row['internal_id'] is not None and checkpoint['id']!=row['internal_id']:raise wire.ProtocolError()
            except (ValueError,OSError):return finish(host,job_id,'failed','checkpoint_unavailable')
        elif path.exists() or path.is_symlink():return finish(host,job_id,'failed','checkpoint_unavailable')
        with host.transaction() as db:db.execute("UPDATE jobs SET status='starting' WHERE job_id=?",(job_id,))
        memory=None
        try:
            audit=host.state_dir/'paired-audit.sqlite'
            if audit.exists() or audit.is_symlink():regular(audit)
            else:
                descriptor=os.open(audit,os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,'O_NOFOLLOW',0),0o600);os.close(descriptor)
            memory=JobAudit(audit)
            runner=PairedJob(host,row,snapshot,memory,transport)
            result=runner.run(snapshot['goal'],row['project_id'],project['model'],resume=resume)
            if result['status'] not in JOB_TERMINAL:raise wire.ProtocolError('checkpoint_unavailable')
            runner.publish()
        except (OSError,ValueError,KeyError,TypeError,sqlite3.Error):return finish(host,job_id,'failed','checkpoint_or_executor_unavailable')
        finally:
            if memory is not None:memory.close()
        with host.transaction() as db:return host.job_result(db.execute('SELECT * FROM jobs WHERE job_id=?',(job_id,)).fetchone())
