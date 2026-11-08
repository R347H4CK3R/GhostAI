"""Only disposable synthetic setup; no LAN listener or real service identity."""
import asyncio
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
SPEC=importlib.util.find_spec('companion.paired_server')
if SPEC:from companion import paired_server as server

class SetupTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(SPEC,'reviewed setup console must be reconstructed')
        if os.name=='nt':
            gate=patch.object(server.identity_store,'WINDOWS_PROTECTED_STORAGE_RELEASED',True);gate.start();self.addCleanup(gate.stop)
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name).resolve()
        self.state=self.root/'private';self.work=self.root/'work';self.work.mkdir();self.calls=[]
    def configure(self,approved):return server.configure(self.state,'https://10.1.2.3:8443',self.work,'Synthetic project','local-model',approve=lambda preview:self.calls.append(preview) or approved)
    def test_declining_setup_creates_no_state_or_listener(self):
        with patch('socket.socket',side_effect=AssertionError('setup must not listen')):self.assertIsNone(self.configure(False))
        self.assertFalse(self.state.exists());self.assertIn(str(self.work),self.calls[0]);self.assertIn('persistent',self.calls[0].lower())
    def test_explicit_setup_reopens_same_identity_and_cannot_reset_state(self):
        with patch('socket.socket',side_effect=AssertionError('setup must not listen')):identity=self.configure(True)
        host,loaded=server.open_host(self.state)
        try:self.assertEqual(loaded,identity);self.assertEqual(next(iter(host._projects.values()))['workspace'],str(self.work))
        finally:host.close()
        before=(self.state/'identity.json').read_bytes()
        with self.assertRaises(ValueError):self.configure(True)
        self.assertEqual((self.state/'identity.json').read_bytes(),before)
    def test_invalid_workspace_and_remote_model_fail_before_files(self):
        for work,model in ((self.root,'local-model'),(self.work,'cloud-model'),(self.work,'https://remote.invalid')):
            with self.assertRaises(ValueError):server.configure(self.state,'https://10.1.2.3:8443',work,'Synthetic',model,approve=lambda _:True)
        self.assertFalse(self.state.exists())
    def test_unrelated_git_directory_or_worktree_file_blocks_before_approval_or_creation(self):
        for kind in ('directory','file'):
            repository=self.root/kind;nested=repository/'nested';nested.mkdir(parents=True)
            marker=repository/'.git'
            if kind=='directory':marker.mkdir()
            else:marker.write_bytes(b'gitdir: do not read or resolve\n')
            self.state=nested/'private'
            with self.subTest(kind=kind),self.assertRaisesRegex(ValueError,'state_inside_git_worktree'):self.configure(True)
            self.assertFalse(self.state.exists());self.assertEqual(list(nested.iterdir()),[])
        self.assertEqual(self.calls,[])
    def test_moved_state_under_git_cannot_open_or_load_tls_without_mutation(self):
        self.configure(True);repository=self.root/'unrelated';repository.mkdir();(repository/'.git').write_bytes(b'gitdir: not read\n');moved=repository/'private';self.state.rename(moved)
        before={p.name:p.read_bytes() for p in moved.iterdir()}
        for operation in (server.open_host,server.identity_store.load_identity,server.identity_store.server_ssl_context):
            with self.subTest(operation=operation.__name__),self.assertRaisesRegex(ValueError,'state_inside_git_worktree'):
                result=operation(moved)
                if operation==server.open_host:result[0].close()
        self.assertEqual({p.name:p.read_bytes() for p in moved.iterdir()},before)
    def test_probe_permission_error_is_not_treated_as_no_repository(self):
        original=os.lstat
        def inspect(path,*args,**kwargs):
            if Path(path)==self.root/'.git':raise PermissionError('synthetic denial')
            return original(path,*args,**kwargs)
        with patch.object(os,'lstat',inspect),self.assertRaisesRegex(ValueError,'state_location_unavailable'):self.configure(True)
        self.assertEqual(self.calls,[]);self.assertFalse(self.state.exists())
    def test_repository_created_during_review_is_rechecked_before_creation(self):
        def approve(_):(self.root/'.git').mkdir();return True
        with self.assertRaisesRegex(ValueError,'state_inside_git_worktree'):server.configure(self.state,'https://10.1.2.3:8443',self.work,'Synthetic','local-model',approve=approve)
        self.assertFalse(self.state.exists())
    def test_invitation_is_local_display_only_and_console_cannot_run_shell(self):
        identity=self.configure(True);host,_=server.open_host(self.state);self.addCleanup(host.close);project=next(iter(host._projects));output=[]
        asyncio.run(server.local_command(host,identity,'invite '+project,confirm=lambda _:False,display=output.append))
        invitation=json.loads(output[-1]);self.assertEqual(invitation['origin'],identity['origin']);self.assertEqual(invitation['tls_leaf_sha256'],identity['tls_leaf_sha256'])
        self.assertNotIn(invitation['invite_secret'].encode(),(self.state/'paired.sqlite').read_bytes())
        with patch('subprocess.run',side_effect=AssertionError('not a shell')):asyncio.run(server.local_command(host,identity,'shell whoami',confirm=lambda _:True,display=output.append))
        self.assertIn('not available',output[-1].lower())
    def test_local_device_approval_shows_scope_and_requires_confirmation(self):
        from companion import paired_protocol as wire
        from companion.tests.test_paired_protocol import b64,public,sign
        from companion.tests.test_paired_host import encoded
        from cryptography.hazmat.primitives.asymmetric import ec
        import hmac
        identity=self.configure(True);host,_=server.open_host(self.state);self.addCleanup(host.close);project=next(iter(host._projects));invite=host.create_invitation([project]);key=ec.derive_private_key(1,ec.SECP256R1())
        body=dict(v=1,host_id=identity['host_id'],invite_id=invite['invite_id'],client_nonce=b64(bytes(32)),device_name='Synthetic',client_public_key=public(key));frame=wire.pair_message(body);body['proof']=b64(hmac.digest(wire.decode64(invite['invite_secret'],32),frame,'sha256'));body['signature']=sign(key,frame+body['proof'].encode()+b'\n')
        _,pending=host.handle('/v1/pair/begin',encoded(body),[]);line='approve '+pending['device_id']+' '+pending['safety_code'];previews=[]
        asyncio.run(server.local_command(host,identity,line,confirm=lambda text:previews.append(text) or False,display=lambda _:None))
        self.assertIn(str(self.work),previews[0]);self.assertIn('local-model',previews[0])
        with host.transaction() as db:self.assertEqual(db.execute('SELECT state FROM devices').fetchone()[0],'pending')
        asyncio.run(server.local_command(host,identity,line,confirm=lambda _:True,display=lambda _:None))
        with host.transaction() as db:self.assertEqual(db.execute('SELECT state FROM devices').fetchone()[0],'active')
        asyncio.run(server.local_command(host,identity,'revoke '+pending['device_id'],confirm=lambda _:True,display=lambda _:None))
        with host.transaction() as db:self.assertEqual(db.execute('SELECT state FROM devices').fetchone()[0],'rejected')
    def test_old_python_rejected_before_approval_or_state(self):
        with patch.object(server.sys,'version_info',(3,10,14)),self.assertRaisesRegex(ValueError,'python_3_11_required'):self.configure(True)
        self.assertEqual(self.calls,[]);self.assertFalse(self.state.exists())

class IgnoreSafetyTests(unittest.TestCase):
    def test_fixed_generated_host_files_are_ignored_without_hiding_source(self):
        import subprocess
        root=Path(__file__).resolve().parents[2]
        names=['identity-key.pem','identity-key-protection.bin','identity-cert.pem','identity.json','host-config.json','paired.sqlite','paired.sqlite-journal','paired.sqlite-wal','paired-audit.sqlite','paired-audit.sqlite-shm','paired-host.lock','paired-dispatch.lock']
        paths=['synthetic-private/'+name for name in names]
        # Binary NUL framing avoids platform newline translation and Git's
        # quoted-path output while preserving the exact protected filenames.
        result=subprocess.run(['git','check-ignore','--no-index','--stdin','-z'],input=('\0'.join(paths+['companion/paired_identity.py'])+'\0').encode('utf-8'),cwd=root,capture_output=True,check=False)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(set(result.stdout.decode('utf-8').split('\0')[:-1]),set(paths))
