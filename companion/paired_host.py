"""Durable local-owner grants and signed requests. No listener or remote admin."""
from contextlib import contextmanager
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import stat
import threading
import time
import uuid
from .autonomy import DEFAULT_LIMITS,CEILINGS,_job_lock
from .core import check_links
from . import paired_protocol as wire

MAX_DATABASE_BYTES=32*1024*1024
MAX_DEVICES=64
MAX_JOBS=1000
QUEUE_TTL=600
JOB_TERMINAL=frozenset(('completed','refused','exhausted','cancelled','failed','awaiting_approval','expired'))

def dump(value):return json.dumps(value,ensure_ascii=False,separators=(',',':'),sort_keys=True)
def stored_object(value):
    if type(value) is not str:raise wire.ProtocolError('state_unavailable')
    try:return wire.load_object(value.encode('utf-8'))
    except (ValueError,UnicodeError):raise wire.ProtocolError('state_unavailable') from None

def regular(path):
    check_links(path);info=path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1:raise wire.ProtocolError('state_unavailable')

def counters(state=None):return {key:state[key] if state else 0 for key in ('iterations','tool_calls','io_bytes','output_bytes')}

class PairedHost:
    def __init__(self,state_dir,host_id,projects,*,create=False,clock=time.time):
        self.host_id=wire.identifier(host_id);self.state_dir=Path(os.path.abspath(state_dir));self.path=self.state_dir/'paired.sqlite'
        self.clock=clock;self.lock=threading.RLock();self.invites={};self._attempts=[];self._projects={};self._owner_lock=None
        self._location()
        if type(projects) is not list or not 1<=len(projects)<=16:raise wire.ProtocolError()
        for project in projects:
            checked=self._validate_project(project)
            if checked['project_id'] in self._projects:raise wire.ProtocolError()
            self._projects[checked['project_id']]=checked
        owner=_job_lock(self.state_dir/'paired-host.lock');owner.__enter__();self._owner_lock=owner
        try:
            if create:
                descriptor=os.open(self.path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,'O_NOFOLLOW',0),0o600);os.close(descriptor);self._initialize()
            elif not self.path.exists():raise wire.ProtocolError('state_unavailable')
            with self.transaction() as db:
                if db.execute('PRAGMA quick_check').fetchone()[0]!='ok':raise wire.ProtocolError('state_unavailable')
                if dict(db.execute('SELECT key,value FROM metadata'))!={'schema':'1','host_id':host_id}:raise wire.ProtocolError('state_unavailable')
                stored={row['project_id']:stored_object(row['config']) for row in db.execute('SELECT * FROM projects')}
                if stored!=self._projects:raise wire.ProtocolError('state_unavailable')
                db.execute("UPDATE devices SET state='expired' WHERE state='pending'")
        except BaseException:self.close();raise
    def _location(self):
        from .paired_identity import require_non_repository_state
        require_non_repository_state(self.state_dir);check_links(self.state_dir);info=self.state_dir.stat()
        if not stat.S_ISDIR(info.st_mode) or (os.name!='nt' and (info.st_mode&0o077 or info.st_uid!=os.geteuid())):raise wire.ProtocolError('state_unavailable')
    def close(self):
        with self.lock:
            self.invites.clear()
            if self._owner_lock is not None:self._owner_lock.__exit__(None,None,None);self._owner_lock=None
    def _connect(self):
        if self._owner_lock is None:raise wire.ProtocolError('state_unavailable')
        self._location();regular(self.path)
        if self.path.stat().st_size>MAX_DATABASE_BYTES:raise wire.ProtocolError('storage_full')
        for suffix in ('-journal','-wal','-shm'):
            path=Path(str(self.path)+suffix)
            if path.exists() or path.is_symlink():regular(path)
        db=sqlite3.connect(self.path,timeout=2,isolation_level=None);db.row_factory=sqlite3.Row
        db.execute('PRAGMA foreign_keys=ON');db.execute('PRAGMA synchronous=FULL');db.execute('PRAGMA max_page_count=8192')
        return db
    def _initialize(self):
        db=self._connect()
        try:
            db.executescript('''BEGIN IMMEDIATE;
CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE projects(project_id TEXT PRIMARY KEY,config TEXT NOT NULL);
CREATE TABLE devices(device_id TEXT PRIMARY KEY,public_key TEXT NOT NULL,name TEXT NOT NULL,state TEXT NOT NULL,highwater INTEGER NOT NULL DEFAULT 0,invite_id TEXT UNIQUE NOT NULL,expires INTEGER NOT NULL,transcript TEXT NOT NULL,safety_code TEXT NOT NULL,grants TEXT NOT NULL);
CREATE TABLE jobs(job_id TEXT PRIMARY KEY,device_id TEXT NOT NULL REFERENCES devices(device_id),project_id TEXT NOT NULL,submission_id TEXT NOT NULL,raw BLOB NOT NULL,config TEXT NOT NULL,status TEXT NOT NULL,created REAL NOT NULL,internal_id TEXT,cancel_requested INTEGER NOT NULL DEFAULT 0,counters TEXT NOT NULL,summary TEXT,error_code TEXT,UNIQUE(device_id,project_id,submission_id));
CREATE TABLE cancellations(device_id TEXT NOT NULL,cancellation_id TEXT NOT NULL,job_id TEXT NOT NULL REFERENCES jobs(job_id),raw BLOB NOT NULL,PRIMARY KEY(device_id,cancellation_id));
COMMIT;''')
            db.execute('BEGIN IMMEDIATE');db.executemany('INSERT INTO metadata VALUES (?,?)',[('schema','1'),('host_id',self.host_id)])
            db.executemany('INSERT INTO projects VALUES (?,?)',[(key,dump(value)) for key,value in self._projects.items()]);db.commit()
        finally:db.close()
    @contextmanager
    def transaction(self):
        with self.lock:
            db=self._connect()
            try:db.execute('BEGIN IMMEDIATE');yield db;db.commit()
            except BaseException:db.rollback();raise
            finally:db.close()
    def _validate_project(self,value):
        wire.exact(value,('project_id','label','workspace','permission_revision','model','trust_local_model','limits'))
        wire.identifier(value['project_id']);wire.text(value['label'],256,scalars=64);wire.integer(value['permission_revision'])
        wire.text(value['workspace'],16384);workspace=Path(value['workspace'])
        if not workspace.is_absolute() or str(workspace)!=value['workspace'] or str(Path(os.path.abspath(workspace)))!=str(workspace):raise wire.ProtocolError()
        if workspace==self.state_dir or workspace in self.state_dir.parents or self.state_dir in workspace.parents:raise wire.ProtocolError()
        check_links(workspace)
        if not workspace.is_dir():raise wire.ProtocolError()
        wire.text(value['model'],128)
        if not re.fullmatch('[A-Za-z0-9][A-Za-z0-9_.:-]*',value['model']) or 'cloud' in value['model'].lower() or value['trust_local_model'] is not True:raise wire.ProtocolError()
        wire.exact(value['limits'],DEFAULT_LIMITS)
        for name,limit in value['limits'].items():wire.integer(limit,CEILINGS[name])
        return json.loads(dump(value))
    def replace_project(self,value):
        normalized=self._validate_project(value)
        with self.lock:
            old=self._projects.get(normalized['project_id'])
            if not old or normalized['permission_revision']<=old['permission_revision']:raise wire.ProtocolError()
            with self.transaction() as db:
                db.execute('UPDATE projects SET config=? WHERE project_id=?',(dump(normalized),normalized['project_id']))
                db.execute("UPDATE jobs SET cancel_requested=1 WHERE project_id=? AND status IN ('queued','starting','running')",(normalized['project_id'],))
            self._projects[normalized['project_id']]=normalized
    def create_invitation(self,project_ids):
        if type(project_ids) is not list or not project_ids or len(set(project_ids))!=len(project_ids):raise wire.ProtocolError()
        with self.lock:
            self.invites={key:value for key,value in self.invites.items() if value['expires']>self.clock()}
            if len(self.invites)>=16:raise wire.ProtocolError('capacity')
            grants=[]
            for ident in project_ids:
                wire.identifier(ident);project=self._projects.get(ident)
                if project is None:raise wire.ProtocolError()
                grants.append(dict(project_id=ident,label=project['label'],capabilities=['jobs.read_only'],permission_revision=project['permission_revision']))
            ident=str(uuid.uuid4());secret=secrets.token_bytes(32);expires=self.clock()+600
            self.invites[ident]=dict(secret=secret,expires=expires,grants=grants)
            return dict(v=1,host_id=self.host_id,invite_id=ident,invite_secret=wire.encode64(secret),expires_at_ms=int(expires*1000))
    def _grants(self,row):
        try:
            grants=wire.load_object(('{"items":'+row['grants']+'}').encode())['items']
            if type(grants) is not list or not 1<=len(grants)<=16:raise ValueError()
            seen=set()
            for grant in grants:
                wire.exact(grant,('project_id','label','capabilities','permission_revision'));wire.identifier(grant['project_id']);wire.text(grant['label'],256,scalars=64);wire.integer(grant['permission_revision'])
                if grant['capabilities']!=['jobs.read_only'] or grant['project_id'] in seen:raise ValueError()
                seen.add(grant['project_id'])
            return grants
        except (ValueError,KeyError,TypeError):raise wire.ProtocolError('state_unavailable') from None
    def _current_grants(self,row):
        return [g for g in self._grants(row) if g['project_id'] in self._projects and self._projects[g['project_id']]['permission_revision']==g['permission_revision']]
    def _begin(self,raw):
        with self.lock:
            now=self.clock();self._attempts=[stamp for stamp in self._attempts if stamp>now-60]
            if len(self._attempts)>=30:raise wire.ProtocolError('capacity')
            self._attempts.append(now)
            try:
                body=wire.load_object(raw,wire.MAX_PAIR);wire.exact(body,('v','host_id','invite_id','client_nonce','device_name','client_public_key','proof','signature'))
                frame=wire.pair_message(body);proof=wire.decode64(body['proof'],32);signed=frame+body['proof'].encode('ascii')+b'\n'
                wire.verify_signature(body['client_public_key'],body['signature'],signed)
                if body['host_id']!=self.host_id:raise ValueError()
            except (ValueError,KeyError,TypeError):raise wire.ProtocolError('unauthorized') from None
            transcript=hashlib.sha256(signed).hexdigest()
            with self.transaction() as db:
                row=db.execute('SELECT * FROM devices WHERE invite_id=?',(body['invite_id'],)).fetchone()
                if row:
                    if row['state'] not in ('pending','active') or row['expires']<=int(now*1000) or not hmac.compare_digest(row['transcript'],transcript):raise wire.ProtocolError('unauthorized')
                    return self._begin_result(row)
                invite=self.invites.get(body['invite_id'])
                if invite is None or invite['expires']<=now or not hmac.compare_digest(hmac.digest(invite['secret'],frame,'sha256'),proof):raise wire.ProtocolError('unauthorized')
                if db.execute('SELECT count(*) FROM devices').fetchone()[0]>=MAX_DEVICES:raise wire.ProtocolError('capacity')
                device=str(uuid.uuid4())
                db.execute('INSERT INTO devices(device_id,public_key,name,state,invite_id,expires,transcript,safety_code,grants) VALUES (?,?,?,?,?,?,?,?,?)',(device,body['client_public_key'],body['device_name'],'pending',body['invite_id'],int(invite['expires']*1000),transcript,transcript[:16],dump(invite['grants'])))
                return self._begin_result(db.execute('SELECT * FROM devices WHERE device_id=?',(device,)).fetchone())
    @staticmethod
    def _begin_result(row):return dict(v=1,device_id=row['device_id'],state='pending_local_approval',expires_at_ms=row['expires'],safety_code=row['safety_code'])
    def approve_device(self,device_id,safety_code):
        wire.identifier(device_id)
        with self.transaction() as db:
            row=db.execute('SELECT * FROM devices WHERE device_id=?',(device_id,)).fetchone()
            if not row or row['state']!='pending' or row['expires']<=int(self.clock()*1000) or row['invite_id'] not in self.invites or type(safety_code) is not str or not hmac.compare_digest(row['safety_code'],safety_code):raise wire.ProtocolError('unauthorized')
            if self._current_grants(row)!=self._grants(row):raise wire.ProtocolError('unauthorized')
            db.execute("UPDATE devices SET state='active' WHERE device_id=?",(device_id,))
            self.invites.pop(row['invite_id'],None)
    def revoke_device(self,device_id):
        wire.identifier(device_id)
        with self.transaction() as db:
            if not db.execute('SELECT 1 FROM devices WHERE device_id=?',(device_id,)).fetchone():raise wire.ProtocolError('not_found')
            db.execute("UPDATE devices SET state='rejected' WHERE device_id=?",(device_id,))
            db.execute("UPDATE jobs SET cancel_requested=1 WHERE device_id=? AND status IN ('queued','starting','running')",(device_id,))
    def _grant(self,row,project):
        wire.identifier(project)
        if row['state']!='active' or not any(g['project_id']==project for g in self._current_grants(row)):raise wire.ProtocolError('unauthorized')
        return self._projects[project]
    @staticmethod
    def job_result(row):
        count=stored_object(row['counters'])
        wire.exact(count,('iterations','tool_calls','io_bytes','output_bytes'))
        if (any(type(v) is not int or v<0 for v in count.values())
                or type(row['status']) is not str or row['status'] not in JOB_TERMINAL|{'queued','starting','running'}
                or type(row['cancel_requested']) is not int or row['cancel_requested'] not in (0,1)):
            raise wire.ProtocolError('state_unavailable')
        try:
            wire.identifier(row['job_id'])
            if row['summary'] is not None:wire.text(row['summary'],65536)
            if row['error_code'] is not None:wire.text(row['error_code'],128)
        except ValueError:raise wire.ProtocolError('state_unavailable') from None
        return dict(v=1,job_id=row['job_id'],status=row['status'],cancel_requested=bool(row['cancel_requested']),counters=count,summary=row['summary'],error_code=row['error_code'],artifacts=[])
    def _route(self,db,row,route,raw):
        body=wire.load_object(raw);wire.version(body.get('v'))
        if route=='/v1/pair/status':
            wire.exact(body,('v',));return 200,dict(v=1,state=row['state'],expires_at_ms=None if row['state']=='active' else row['expires'],grants=self._current_grants(row) if row['state']=='active' else [])
        if route=='/v1/jobs/submit':
            wire.exact(body,('v','project_id','submission_id','goal','requested_write_paths','limits'))
            project=self._grant(row,body['project_id']);wire.identifier(body['submission_id']);wire.text(body['goal'],8192)
            if body['requested_write_paths']!=[]:raise wire.ProtocolError()
            wire.exact(body['limits'],DEFAULT_LIMITS)
            for name,value in body['limits'].items():wire.integer(value,project['limits'][name])
            existing=db.execute('SELECT * FROM jobs WHERE device_id=? AND project_id=? AND submission_id=?',(row['device_id'],body['project_id'],body['submission_id'])).fetchone()
            if existing:
                if existing['raw']!=raw:raise wire.ProtocolError('operation_conflict')
                snapshot=stored_object(existing['config'])
                return 202,dict(v=1,job_id=existing['job_id'],submission_id=existing['submission_id'],status=existing['status'],permission_revision=snapshot['project']['permission_revision'])
            if db.execute('SELECT count(*) FROM jobs').fetchone()[0]>=MAX_JOBS or db.execute("SELECT count(*) FROM jobs WHERE device_id=? AND status IN ('queued','starting','running')",(row['device_id'],)).fetchone()[0]>=4:raise wire.ProtocolError('capacity')
            ident=str(uuid.uuid4());snapshot=dict(project=project,goal=body['goal'],limits=body['limits'])
            db.execute('INSERT INTO jobs(job_id,device_id,project_id,submission_id,raw,config,status,created,counters) VALUES (?,?,?,?,?,?,?,?,?)',(ident,row['device_id'],body['project_id'],body['submission_id'],raw,dump(snapshot),'queued',self.clock(),dump(counters())))
            return 202,dict(v=1,job_id=ident,submission_id=body['submission_id'],status='queued',permission_revision=project['permission_revision'])
        keys=('v','project_id','job_id') if route=='/v1/jobs/get' else ('v','project_id','job_id','cancellation_id')
        wire.exact(body,keys);self._grant(row,body['project_id']);wire.identifier(body['job_id'])
        job=db.execute('SELECT * FROM jobs WHERE job_id=? AND device_id=? AND project_id=?',(body['job_id'],row['device_id'],body['project_id'])).fetchone()
        if not job:raise wire.ProtocolError('not_found')
        if route=='/v1/jobs/cancel':
            wire.identifier(body['cancellation_id'])
            previous=db.execute('SELECT * FROM cancellations WHERE device_id=? AND cancellation_id=?',(row['device_id'],body['cancellation_id'])).fetchone()
            if previous and previous['raw']!=raw:raise wire.ProtocolError('operation_conflict')
            if not previous:
                if db.execute('SELECT count(*) FROM cancellations').fetchone()[0]>=MAX_JOBS*4:raise wire.ProtocolError('capacity')
                db.execute('INSERT INTO cancellations VALUES (?,?,?,?)',(row['device_id'],body['cancellation_id'],body['job_id'],raw))
            db.execute('UPDATE jobs SET cancel_requested=1 WHERE job_id=?',(job['job_id'],));job=db.execute('SELECT * FROM jobs WHERE job_id=?',(job['job_id'],)).fetchone()
        return 200,self.job_result(job)
    @staticmethod
    def failure(error,request=None):
        code=error.code if isinstance(error,wire.ProtocolError) else 'state_unavailable'
        status={'unauthorized':403,'not_found':404,'replay':409,'operation_conflict':409,'capacity':429,'storage_full':503,'state_unavailable':503}.get(code,400)
        return status,dict(v=1,error=dict(code=code,request_id=request))
    def handle(self,route,raw,headers):
        request=None
        try:
            if route=='/v1/pair/begin':
                if headers:raise wire.ProtocolError()
                return 200,self._begin(raw)
            if route not in wire.ROUTES:raise wire.ProtocolError('not_found')
            auth=wire.auth_headers(headers);request=auth['request']
            if auth['host']!=self.host_id:raise wire.ProtocolError('unauthorized')
            with self.transaction() as db:
                row=db.execute('SELECT * FROM devices WHERE device_id=?',(auth['device'],)).fetchone()
                if not row or row['state'] not in ('pending','active') or (row['state']=='pending' and row['expires']<=int(self.clock()*1000)):raise wire.ProtocolError('unauthorized')
                wire.verify_signature(row['public_key'],auth['signature'],wire.request_message(self.host_id,auth['device'],auth['sequence'],request,route,raw))
                if type(row['highwater']) is not int or not 0<=row['highwater']<=wire.MAX_SEQUENCE:raise wire.ProtocolError('state_unavailable')
                if auth['sequence']<=row['highwater']:raise wire.ProtocolError('replay')
                db.execute('UPDATE devices SET highwater=? WHERE device_id=?',(auth['sequence'],auth['device']))
                # Authenticated malformed/denied requests still burn their counter.
                try:result=self._route(db,row,route,raw)
                except wire.ProtocolError as error:result=self.failure(error,request)
            return result
        except (wire.ProtocolError,OSError,ValueError,KeyError,TypeError,sqlite3.Error):
            import sys
            return self.failure(sys.exception(),request)
    def authorized_job(self,job_id):
        try:
            with self.transaction() as db:
                job=db.execute('SELECT * FROM jobs WHERE job_id=?',(job_id,)).fetchone()
                if not job or job['cancel_requested']:return False
                row=db.execute('SELECT * FROM devices WHERE device_id=?',(job['device_id'],)).fetchone()
                if not row:return False
                project=self._grant(row,job['project_id'])
                return project==stored_object(job['config'])['project']
        except (ValueError,OSError,KeyError,TypeError,sqlite3.Error):return False
