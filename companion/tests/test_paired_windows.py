"""Native Windows protection tests use disposable synthetic state only."""
import importlib.util
import os
from pathlib import Path
import ssl
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.find_spec('companion.paired_windows')
if SPEC:
    from companion import paired_windows as windows

class AvailabilityTests(unittest.TestCase):
    def test_candidate_exists(self):
        self.assertIsNotNone(SPEC, 'native protected storage candidate is missing')

    @unittest.skipIf(os.name == 'nt', 'non-Windows fail-closed boundary')
    def test_no_plaintext_dpapi_emulation(self):
        self.assertIsNotNone(SPEC, 'native protected storage candidate is missing')
        for call in (lambda: windows.protect(b'0' * 64), lambda: windows.unprotect(b'invalid blob')):
            with self.assertRaises(windows.WindowsStorageError): call()

@unittest.skipUnless(os.name == 'nt', 'requires actual Windows APIs and a local fixed drive')
class NativeWindowsTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(SPEC, 'native protected storage candidate is missing')
        from companion import paired_identity
        self.identity = paired_identity
        gate = mock.patch.object(paired_identity, 'WINDOWS_PROTECTED_STORAGE_RELEASED', True)
        gate.start(); self.addCleanup(gate.stop)
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / 'private'

    def initialize(self):
        self.identity.create_private_state_directory(self.state, approved=True)
        return self.identity.initialize_identity(self.state, 'https://10.1.2.3:8443', approved=True)

    def test_dpapi_roundtrip_and_tamper_rejection(self):
        clear = b'0' * 64
        cipher = windows.protect(clear)
        self.assertNotIn(clear, cipher)
        self.assertEqual(windows.unprotect(cipher), clear)
        for wrong in (cipher[:-1], b'invalid'):
            with self.assertRaises(windows.WindowsStorageError): windows.unprotect(wrong)

    def test_encrypted_identity_and_ssl_context_leave_no_plaintext_copy(self):
        result = self.initialize()
        before = {p.name: p.read_bytes() for p in self.state.iterdir()}
        self.assertIn(b'BEGIN ENCRYPTED PRIVATE KEY', before['identity-key.pem'])
        self.assertIn('identity-key-protection.bin', before)
        self.assertNotIn(b'BEGIN PRIVATE KEY', b''.join(before.values()))
        self.assertEqual(self.identity.load_identity(self.state), result)
        self.assertEqual(self.identity.server_ssl_context(self.state).num_tickets, 0)
        self.assertEqual({p.name: p.read_bytes() for p in self.state.iterdir()}, before)

    def test_approval_and_existing_directory_are_not_bypassed(self):
        with self.assertRaises(self.identity.IdentityError):
            self.identity.create_private_state_directory(self.state)
        self.assertFalse(self.state.exists())
        self.state.mkdir()
        with self.assertRaises(self.identity.IdentityError):
            self.identity.create_private_state_directory(self.state, approved=True)

    def test_read_handle_denies_write_delete_and_hardlinks(self):
        self.initialize()
        with windows.private_directory(self.state) as directory:
            with directory.open_file('identity-key.pem'):
                with self.assertRaises(OSError): (self.state / 'identity-key.pem').unlink()
                with self.assertRaises(OSError): (self.state / 'identity-key.pem').write_bytes(b'tamper')
        os.link(self.state / 'identity-key.pem', self.root / 'alias')
        with self.assertRaises(self.identity.IdentityError): self.identity.load_identity(self.state)

    def test_dpapi_envelope_mismatch_and_missing_file_are_not_repaired(self):
        self.initialize()
        envelope = self.state / 'identity-key-protection.bin'
        envelope.write_bytes(windows.protect(b'1' * 64))
        with self.assertRaises(self.identity.IdentityError): self.identity.load_identity(self.state)
        envelope.unlink()
        with self.assertRaises(self.identity.IdentityError): self.identity.load_identity(self.state)
        self.assertFalse(envelope.exists())

    def test_broad_directory_or_key_acl_is_rejected(self):
        self.initialize()
        import ctypes
        from ctypes import wintypes
        api = windows._api()
        setter = api.advapi.SetNamedSecurityInfoW
        setter.argtypes = [wintypes.LPWSTR, wintypes.DWORD, wintypes.DWORD,
                           ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
        setter.restype = wintypes.DWORD
        get_dacl = api.advapi.GetSecurityDescriptorDacl
        get_dacl.argtypes = [ctypes.c_void_p, ctypes.POINTER(wintypes.BOOL),
                            ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(wintypes.BOOL)]
        get_dacl.restype = wintypes.BOOL
        def replace(path, broad):
            sddl = 'D:P(A;;FA;;;WD)' if broad else api.sddl(directory=path.is_dir())
            with api.security_descriptor(sddl) as descriptor:
                present, defaulted, dacl = wintypes.BOOL(), wintypes.BOOL(), ctypes.c_void_p()
                self.assertTrue(get_dacl(descriptor, ctypes.byref(present), ctypes.byref(dacl), ctypes.byref(defaulted)))
                self.assertEqual(setter(str(path), 1, 0x80000004, None, None, dacl, None), 0)
        for path in (self.state, self.state / 'identity-key.pem', self.state / 'identity-key-protection.bin'):
            replace(path, True)
            try:
                with self.assertRaises(self.identity.IdentityError): self.identity.load_identity(self.state)
            finally:
                replace(path, False)

    def test_native_encrypted_key_completes_tls_in_memory(self):
        self.initialize()
        client_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        client_context.load_verify_locations(cadata=self.identity.certificate_pem(self.state).decode())
        ci, co, si, so = (ssl.MemoryBIO() for _ in range(4))
        client = client_context.wrap_bio(ci, co, server_hostname='10.1.2.3')
        server = self.identity.server_ssl_context(self.state).wrap_bio(si, so, server_side=True)
        done = set()
        for _ in range(20):
            for name, endpoint in (('client', client), ('server', server)):
                if name not in done:
                    try: endpoint.do_handshake(); done.add(name)
                    except ssl.SSLWantReadError: pass
            si.write(co.read()); ci.write(so.read())
            if len(done) == 2:
                self.assertIn(client.version(), ('TLSv1.2', 'TLSv1.3'))
                return
        self.fail('Native TLS handshake did not finish')

    def test_symlinked_state_is_rejected_if_creation_privilege_is_available(self):
        self.initialize()
        alias = self.root / 'state-alias'
        try: alias.symlink_to(self.state, target_is_directory=True)
        except OSError as error:
            if getattr(error, 'winerror', None) == 1314:
                self.skipTest('Windows symlink privilege unavailable')
            raise
        with self.assertRaises(self.identity.IdentityError): self.identity.load_identity(alias)

    def test_native_direct_storage_rejects_git_marker(self):
        repo = self.root / 'repo'; repo.mkdir()
        (repo / '.git').write_text('gitdir: /do/not/read')
        with self.assertRaises(self.identity.IdentityError) as caught:
            windows.create_private_directory(repo / 'state')
        self.assertEqual(caught.exception.code, 'state_inside_git_worktree')
        self.assertFalse((repo / 'state').exists())

if __name__ == '__main__': unittest.main()
