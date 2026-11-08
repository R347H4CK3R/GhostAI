"""Bounded native diagnostics for default versus explicitly owned synthetic files."""
from contextlib import closing
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from companion import paired_windows as windows


@unittest.skipUnless(os.name == 'nt', 'requires native Windows token and file security descriptors')
class NativeCreationTests(unittest.TestCase):
    def test_report_synthetic_default_owner_and_dacl_presence(self):
        api = windows._api()
        def classification(sid):
            return 'current_user' if sid == api.sid else 'administrators' if sid == 'S-1-5-32-544' else 'other'
        token = wintypes.HANDLE()
        self.assertTrue(api.advapi.OpenProcessToken(api.kernel.GetCurrentProcess(), 0x0008, ctypes.byref(token)))
        try:
            size = wintypes.DWORD()
            api.advapi.GetTokenInformation(token, 4, None, 0, ctypes.byref(size))
            self.assertTrue(0 < size.value <= 65536)
            data = ctypes.create_string_buffer(size.value)
            self.assertTrue(api.advapi.GetTokenInformation(token, 4, data, size, ctypes.byref(size)))
            default_owner = classification(api._sid_text(ctypes.cast(data, ctypes.POINTER(ctypes.c_void_p)).contents))
        finally: api.kernel.CloseHandle(token)
        getter = api.advapi.GetNamedSecurityInfoW
        pointer = ctypes.c_void_p
        getter.argtypes = [wintypes.LPWSTR, wintypes.DWORD, wintypes.DWORD,
                           ctypes.POINTER(pointer), ctypes.POINTER(pointer), ctypes.POINTER(pointer),
                           ctypes.POINTER(pointer), ctypes.POINTER(pointer)]
        getter.restype = wintypes.DWORD
        def descriptor(path):
            owner, dacl, security = pointer(), pointer(), pointer()
            self.assertEqual(getter(str(path), 1, 5, ctypes.byref(owner), None,
                                    ctypes.byref(dacl), None, ctypes.byref(security)), 0)
            try: return dict(owner=classification(api._sid_text(owner)), nonnull_dacl=bool(dacl.value))
            finally: api.kernel.LocalFree(security)
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / 'synthetic-private'
            windows.create_private_directory(state)
            fd = os.open(state / 'ordinary.lock', os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(fd)
            fd, checkpoint = tempfile.mkstemp(prefix='.veyra-job-', dir=state); os.close(fd)
            with windows.private_directory(state) as directory: directory.write_new('explicit.bin', b'Synthetic')
            with closing(sqlite3.connect(state / 'audit.sqlite')) as db:
                db.execute('CREATE TABLE synthetic(value INTEGER)')
                db.execute('INSERT INTO synthetic VALUES(1)')
                report = dict(token_default_owner=default_owner, ordinary=descriptor(state / 'ordinary.lock'),
                              temporary=descriptor(checkpoint), database=descriptor(state / 'audit.sqlite'),
                              journal=descriptor(state / 'audit.sqlite-journal'), explicit=descriptor(state / 'explicit.bin'))
                # Only classifications of disposable synthetic objects, no paths,
                # account identifiers, content or credentials are printed.
                print('WINDOWS_SYNTHETIC_CREATION ' + json.dumps(report, sort_keys=True), flush=True)
                self.assertEqual(report['explicit'], dict(owner='current_user', nonnull_dacl=True))
