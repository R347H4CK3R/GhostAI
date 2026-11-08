"""Native paired mutable storage: disposable files, real DACLs, no LAN or model."""
from concurrent.futures import ThreadPoolExecutor, TimeoutError
from contextlib import closing
import ctypes
from ctypes import wintypes
import hmac
import json
import os
import re
from pathlib import Path
import sqlite3
import tempfile
import threading
import unittest
from unittest.mock import patch
import uuid
from cryptography.hazmat.primitives.asymmetric import ec
from companion import paired_identity, paired_protocol as wire, paired_server, paired_windows as windows
from companion.paired_jobs import run_next
from companion.tests.test_autonomy import plan, read, complete
from companion.tests.test_paired_host import encoded
from companion.tests.test_paired_protocol import b64, public, sign


@unittest.skipUnless(os.name == 'nt', 'requires actual Windows ownership and DACL APIs')
class NativeMutableStorageTests(unittest.TestCase):
    def setUp(self):
        gate = patch.object(paired_identity, 'WINDOWS_PROTECTED_STORAGE_RELEASED', True)
        gate.start(); self.addCleanup(gate.stop)
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.state = self.root / 'private'; self.work = self.root / 'work'; self.work.mkdir()
        (self.work / 'input.txt').write_text('Synthetic native observation.', encoding='utf-8')
        self.identity = paired_server.configure(self.state, 'https://10.1.2.3:8443', self.work,
            'Synthetic native project', 'local-model', approve=lambda _: True)
        self.host = None
        self.addCleanup(lambda: self.host.close() if self.host else None)
        self.key = ec.derive_private_key(1, ec.SECP256R1()); self.sequence = 0

    def open(self):
        self.host, identity = paired_server.open_host(self.state)
        self.assertEqual(identity, self.identity)
        self.project = next(iter(self.host._projects))
        return self.host

    def enroll(self):
        invitation = self.host.create_invitation([self.project])
        body = dict(v=1, host_id=self.host.host_id, invite_id=invitation['invite_id'],
                    client_nonce=b64(bytes(32)), device_name='Synthetic native phone', client_public_key=public(self.key))
        frame = wire.pair_message(body)
        body['proof'] = b64(hmac.digest(wire.decode64(invitation['invite_secret'], 32), frame, 'sha256'))
        body['signature'] = sign(self.key, frame + body['proof'].encode() + b'\n')
        status, pending = self.host.handle('/v1/pair/begin', encoded(body), [])
        self.assertEqual(status, 200); self.device = pending['device_id']
        self.host.approve_device(self.device, pending['safety_code'])

    def request(self, route, body):
        self.sequence += 1; request = str(uuid.uuid4()); raw = encoded(body)
        headers = [('X-Veyra-Host', self.host.host_id), ('X-Veyra-Device', self.device),
                   ('X-Veyra-Sequence', str(self.sequence)), ('X-Veyra-Request', request),
                   ('X-Veyra-Signature', sign(self.key, wire.request_message(
                       self.host.host_id, self.device, self.sequence, request, route, raw)))]
        return self.host.handle(route, raw, headers)

    def submission(self):
        return dict(v=1, project_id=self.project, submission_id=str(uuid.uuid4()),
                    goal='Read input.txt', requested_write_paths=[],
                    limits=self.host._projects[self.project]['limits'])

    def set_security(self, path, kind):
        api = windows._api()
        setter = api.advapi.SetNamedSecurityInfoW
        setter.argtypes = [wintypes.LPWSTR, wintypes.DWORD, wintypes.DWORD,
                           ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
        setter.restype = wintypes.DWORD
        if kind == 'null':
            self.assertEqual(setter(str(path), 1, 0x80000004, None, None, None, None), 0)
            return
        flags = 'OICI' if path.is_dir() else ''
        sddl = {'private': api.sddl(directory=path.is_dir()),
                'broad': f'O:{api.sid}D:P(A;{flags};FA;;;WD)',
                'unsupported': f'O:{api.sid}D:P(A;{flags};FR;;;{api.sid})',
                'wrong-owner': f'O:BAD:P(A;{flags};FA;;;{api.sid})(A;{flags};FA;;;SY)'}[kind]
        get_dacl = api.advapi.GetSecurityDescriptorDacl
        get_dacl.argtypes = [ctypes.c_void_p, ctypes.POINTER(wintypes.BOOL),
                            ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(wintypes.BOOL)]
        get_dacl.restype = wintypes.BOOL
        get_owner = api.advapi.GetSecurityDescriptorOwner
        get_owner.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(wintypes.BOOL)]
        get_owner.restype = wintypes.BOOL
        with api.security_descriptor(sddl) as descriptor:
            present, defaulted = wintypes.BOOL(), wintypes.BOOL()
            dacl, owner = ctypes.c_void_p(), ctypes.c_void_p()
            self.assertTrue(get_dacl(descriptor, ctypes.byref(present), ctypes.byref(dacl), ctypes.byref(defaulted)))
            self.assertTrue(get_owner(descriptor, ctypes.byref(owner), ctypes.byref(defaulted)))
            # Only this disposable synthetic object. No account/privilege changes.
            information = 0x80000005 if kind == 'wrong-owner' else 0x80000004
            result = setter(str(path), 1, information, owner if kind == 'wrong-owner' else None, None, dacl, None)
            if kind == 'wrong-owner' and result == 1307:
                self.skipTest('Token cannot assign Administrators as an owner; native wrong-owner evidence remains required')
            self.assertEqual(result, 0)
            if kind == 'private':
                # Restore DACL first: the deliberately read-only case lacks
                # WRITE_OWNER until the test restores its full-control ACE.
                self.assertEqual(setter(str(path), 1, 1, owner, None, None, None), 0)

    def assert_inherited_private_acl(self, path):
        # Inspect the native security descriptor independently of the production
        # validator: generated mutable children must actually inherit safe ACEs.
        api = windows._api(); pointer = ctypes.c_void_p
        getter = api.advapi.GetNamedSecurityInfoW
        getter.argtypes = [wintypes.LPWSTR, wintypes.DWORD, wintypes.DWORD,
                           ctypes.POINTER(pointer), ctypes.POINTER(pointer), ctypes.POINTER(pointer),
                           ctypes.POINTER(pointer), ctypes.POINTER(pointer)]
        getter.restype = wintypes.DWORD
        convert = api.advapi.ConvertSecurityDescriptorToStringSecurityDescriptorW
        convert.argtypes = [pointer, wintypes.DWORD, wintypes.DWORD,
                            ctypes.POINTER(pointer), ctypes.POINTER(wintypes.DWORD)]
        convert.restype = wintypes.BOOL
        owner, dacl, descriptor, text = pointer(), pointer(), pointer(), pointer()
        self.assertEqual(getter(str(path), 1, 5, ctypes.byref(owner), None,
                                ctypes.byref(dacl), None, ctypes.byref(descriptor)), 0)
        try:
            self.assertEqual(api._sid_text(owner), api.sid)
            self.assertTrue(dacl.value)
            self.assertTrue(convert(descriptor, 1, 4, ctypes.byref(text), None))
            sddl = ctypes.wstring_at(text)
            self.assertEqual(set(re.findall(r'\([^)]*\)', sddl)),
                             {f'(A;ID;FA;;;{api.sid})', '(A;ID;FA;;;SY)'})
            self.assertNotIn('P', sddl.split('(', 1)[0], 'generated mutable file should inherit its DACL')
        finally:
            if text.value: api.kernel.LocalFree(text)
            api.kernel.LocalFree(descriptor)

    def snapshot(self):
        # Host locks can deny data reads; all snapshots below have a closed host.
        return {p.name: p.read_bytes() for p in self.state.iterdir()}

    def test_setup_enrollment_job_audit_checkpoint_and_reopen_recovery(self):
        self.open(); self.enroll()
        status, job = self.request('/v1/jobs/submit', self.submission()); self.assertEqual(status, 202)
        replies = iter([plan(read()), complete('Synthetic native observation.')])
        def model(_): return encoded(dict(done=True, response=json.dumps(next(replies))))
        result = run_next(self.host, transport=model)
        self.assertEqual(result['status'], 'completed'); self.assertEqual(result['counters']['tool_calls'], 1)
        with closing(sqlite3.connect(self.state / 'paired-audit.sqlite')) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM tasks').fetchone()[0], 1)
        # Lose only final publication, as a crash could. Recovery must not replay a model/tool.
        with self.host.transaction() as db:
            db.execute("UPDATE jobs SET status='running', summary=NULL WHERE job_id=?", (job['job_id'],))
        self.host.close(); before = self.snapshot()
        self.assertIn(job['job_id'] + '.json', before)
        self.assertIn(job['job_id'] + '.json.lock', before)
        self.assertIn('paired-dispatch.lock', before)
        for name in ('paired.sqlite', 'paired-audit.sqlite', 'paired-host.lock',
                     'paired-dispatch.lock', job['job_id'] + '.json', job['job_id'] + '.json.lock'):
            with self.subTest(artifact=name): self.assert_inherited_private_acl(self.state / name)
        windows.validate_mutable_state(self.state)
        self.open()
        recovered = run_next(self.host, transport=lambda _: self.fail('terminal checkpoint replayed'))
        self.assertEqual(recovered['status'], 'completed')
        self.assertEqual(recovered['summary'], 'Synthetic native observation.')
        self.assertEqual(self.request('/v1/jobs/get', dict(v=1, project_id=self.project, job_id=job['job_id']))[1], recovered)
        windows.validate_mutable_state(self.state)

    def test_status_waits_for_checkpoint_replacement_without_transient_refusal(self):
        self.open(); self.enroll()
        self.assertEqual(self.request('/v1/jobs/submit', self.submission())[0], 202)
        linked, release, querying = threading.Event(), threading.Event(), threading.Event()
        original = os.link
        replies = iter([plan(read()), complete('Synthetic native observation.')])
        def link(*args, **kwargs):
            original(*args, **kwargs)
            linked.set()
            if not release.wait(10): raise RuntimeError('synthetic checkpoint barrier timed out')
        def model(_): return encoded(dict(done=True, response=json.dumps(next(replies))))
        def status():
            acquired = self.host.lock.acquire(blocking=False)
            if acquired: self.host.lock.release()
            self.assertFalse(acquired, 'checkpoint replacement must hold the shared storage lock')
            querying.set()
            return self.request('/v1/pair/status', dict(v=1))
        with patch.object(os, 'link', link), ThreadPoolExecutor(max_workers=2) as executor:
            job = executor.submit(run_next, self.host, transport=model)
            try:
                self.assertTrue(linked.wait(10), 'initial checkpoint was not reached')
                response = executor.submit(status)
                self.assertTrue(querying.wait(10))
                # The short-lived two-link checkpoint is not a stable artifact.
                # A concurrent status request must wait, not reject that state.
                with self.assertRaises(TimeoutError): response.result(timeout=.05)
            finally: release.set()
            self.assertEqual(response.result(timeout=30)[0], 200)
            self.assertEqual(job.result(timeout=30)['status'], 'completed')
        windows.validate_mutable_state(self.state)

    def test_inherited_identity_and_config_acls_remain_rejected_by_strict_reader(self):
        for name in ('identity-cert.pem', 'host-config.json'):
            with self.subTest(artifact=name):
                path = self.state / name; before = path.read_bytes()
                if name == 'identity-cert.pem':
                    load = lambda: paired_identity.load_identity(self.state)
                    self.assertEqual(load(), self.identity)
                else:
                    load = lambda: paired_identity.read_private_file(self.state, name, 65536)
                    self.assertEqual(load(), before)
                path.unlink(); path.write_bytes(before)
                try:
                    self.assert_inherited_private_acl(path)
                    windows.validate_mutable_state(self.state)
                    with self.assertRaises(paired_identity.IdentityError): load()
                    self.assertEqual(path.read_bytes(), before)
                finally: self.set_security(path, 'private')

    def reject_artifacts(self, kind):
        names = ['paired.sqlite', 'paired.sqlite-journal', 'paired.sqlite-wal', 'paired.sqlite-shm',
                 'paired-audit.sqlite', 'paired-audit.sqlite-journal', 'paired-audit.sqlite-wal',
                 'paired-audit.sqlite-shm', 'paired-host.lock', 'paired-dispatch.lock',
                 str(uuid.uuid4()) + '.json', str(uuid.uuid4()) + '.json.lock', '.veyra-job-synthetic']
        for name in names:
            with self.subTest(kind=kind, artifact=name):
                path = self.state / name; created = not path.exists()
                if created: path.write_bytes(b'Synthetic existing artifact')
                try:
                    self.set_security(path, kind); before = self.snapshot()
                    with self.assertRaises(ValueError):
                        host, _ = paired_server.open_host(self.state)
                        host.close()
                    self.assertEqual(self.snapshot(), before, 'refusal must not mutate or reset state')
                    # The ACL must still be bad; the application never repairs it.
                    with self.assertRaises(ValueError): windows.validate_mutable_state(self.state)
                finally:
                    self.set_security(path, 'private')
                    if created: path.unlink()

    def test_broad_artifact_acls_are_refused_without_repair(self): self.reject_artifacts('broad')
    def test_null_artifact_dacls_are_refused_without_repair(self): self.reject_artifacts('null')
    def test_wrong_artifact_owners_are_refused_without_repair(self): self.reject_artifacts('wrong-owner')
    def test_unsupported_artifact_dacls_are_refused_without_repair(self): self.reject_artifacts('unsupported')

    def test_existing_audit_sidecar_is_refused_before_accepting_a_submission(self):
        self.open(); self.enroll()
        sidecar = self.state / 'paired-audit.sqlite-journal'; sidecar.write_bytes(b'Synthetic sidecar')
        before = (self.state / 'paired.sqlite').read_bytes(); self.set_security(sidecar, 'broad')
        try:
            self.assertEqual(self.request('/v1/jobs/submit', self.submission())[0], 503)
            self.assertEqual((self.state / 'paired.sqlite').read_bytes(), before)
        finally: self.set_security(sidecar, 'private'); sidecar.unlink()

    def test_directory_weakening_during_model_call_blocks_further_writes(self):
        self.open(); self.enroll()
        self.assertEqual(self.request('/v1/jobs/submit', self.submission())[0], 202)
        before = {}
        def model(_):
            before.update({p.name: p.read_bytes() for p in self.state.iterdir() if not p.name.endswith('.lock')})
            self.set_security(self.state, 'broad')
            return encoded(dict(done=True, response=json.dumps(complete('Must not be persisted'))))
        try:
            with self.assertRaises(ValueError): run_next(self.host, transport=model)
        finally: self.set_security(self.state, 'private')
        after = {p.name: p.read_bytes() for p in self.state.iterdir() if not p.name.endswith('.lock')}
        self.assertEqual(after, before)

    def test_new_checkpoint_temporary_acl_is_checked_before_sensitive_write(self):
        self.open(); self.enroll()
        self.assertEqual(self.request('/v1/jobs/submit', self.submission())[0], 202)
        original_create, original_unlink = tempfile.mkstemp, os.unlink
        discarded = []
        def create(*args, **kwargs):
            fd, name = original_create(*args, **kwargs)
            self.set_security(Path(name), 'broad')
            return fd, name
        def unlink(name, *args, **kwargs):
            if Path(name).name.startswith('.veyra-job-'): discarded.append(Path(name).read_bytes())
            return original_unlink(name, *args, **kwargs)
        with patch.object(tempfile, 'mkstemp', create), patch.object(os, 'unlink', unlink):
            result = run_next(self.host, transport=lambda _: self.fail('unsafe storage executed'))
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(discarded, [b''], 'no checkpoint contents may reach a permissive temporary file')
