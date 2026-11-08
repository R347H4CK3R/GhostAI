"""Native DACL and user-bound DPAPI candidate, behind the identity release gate.

No shell or plaintext fallback. Only fixed local drives; reparse ancestry and
hardlinks are rejected. Identity handles deny file writes/deletes and ancestor
renames. Mutable state uses separate metadata-only checks, preserving SQLite and
checkpoint writes. This code still requires actual Windows CI and independent review.
"""
from contextlib import contextmanager, ExitStack
import ctypes
from ctypes import wintypes
from functools import lru_cache
import os
from pathlib import Path
import re


class WindowsStorageError(ValueError):
    def __init__(self):
        super().__init__('windows_protected_storage_unavailable')


class _Attributes(ctypes.Structure):
    _fields_ = [('length', wintypes.DWORD), ('descriptor', ctypes.c_void_p), ('inherit', wintypes.BOOL)]


class _Blob(ctypes.Structure):
    _fields_ = [('size', wintypes.DWORD), ('data', ctypes.POINTER(ctypes.c_ubyte))]


class _SidAndAttributes(ctypes.Structure):
    _fields_ = [('sid', ctypes.c_void_p), ('attributes', wintypes.DWORD)]


class _ACL(ctypes.Structure):
    _fields_ = [('revision', ctypes.c_ubyte), ('reserved', ctypes.c_ubyte),
                ('size', wintypes.WORD), ('count', wintypes.WORD), ('reserved2', wintypes.WORD)]


class _ACE(ctypes.Structure):
    _fields_ = [('type', ctypes.c_ubyte), ('flags', ctypes.c_ubyte), ('size', wintypes.WORD), ('mask', wintypes.DWORD)]


class _FileInfo(ctypes.Structure):
    _fields_ = [('attributes', wintypes.DWORD), ('created', wintypes.FILETIME),
                ('accessed', wintypes.FILETIME), ('written', wintypes.FILETIME),
                ('volume', wintypes.DWORD), ('size_high', wintypes.DWORD), ('size_low', wintypes.DWORD),
                ('links', wintypes.DWORD), ('index_high', wintypes.DWORD), ('index_low', wintypes.DWORD)]


def _require(value):
    if not value:
        raise WindowsStorageError()
    return value


class _API:
    def __init__(self):
        if os.name != 'nt' or not hasattr(ctypes, 'WinDLL'):
            raise WindowsStorageError()
        self.kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        self.advapi = ctypes.WinDLL('advapi32', use_last_error=True)
        self.crypt = ctypes.WinDLL('crypt32', use_last_error=True)
        P, D, H, B = ctypes.c_void_p, wintypes.DWORD, wintypes.HANDLE, wintypes.BOOL
        PD, PP = ctypes.POINTER(D), ctypes.POINTER(P)
        for library, name, arguments, result in (
            (self.kernel, 'GetCurrentProcess', [], H),
            (self.kernel, 'CloseHandle', [H], B),
            (self.kernel, 'LocalFree', [P], P),
            (self.kernel, 'GetDriveTypeW', [wintypes.LPCWSTR], wintypes.UINT),
            (self.kernel, 'CreateDirectoryW', [wintypes.LPCWSTR, ctypes.POINTER(_Attributes)], B),
            (self.kernel, 'CreateFileW', [wintypes.LPCWSTR, D, D, P, D, D, H], H),
            (self.kernel, 'GetFileInformationByHandle', [H, ctypes.POINTER(_FileInfo)], B),
            (self.kernel, 'GetFileType', [H], D),
            (self.kernel, 'ReadFile', [H, P, D, PD, P], B),
            (self.kernel, 'WriteFile', [H, P, D, PD, P], B),
            (self.kernel, 'FlushFileBuffers', [H], B),
            (self.advapi, 'OpenProcessToken', [H, D, ctypes.POINTER(H)], B),
            (self.advapi, 'GetTokenInformation', [H, ctypes.c_int, P, D, PD], B),
            (self.advapi, 'ConvertSidToStringSidW', [P, PP], B),
            (self.advapi, 'ConvertStringSecurityDescriptorToSecurityDescriptorW', [wintypes.LPCWSTR, D, PP, PD], B),
            (self.advapi, 'GetSecurityInfo', [H, ctypes.c_int, D, PP, PP, PP, PP, PP], D),
            (self.advapi, 'GetSecurityDescriptorControl', [P, ctypes.POINTER(wintypes.WORD), PD], B),
            (self.advapi, 'GetAce', [P, D, PP], B),
            (self.advapi, 'IsValidSid', [P], B),
            (self.advapi, 'GetLengthSid', [P], D),
            (self.crypt, 'CryptProtectData', [ctypes.POINTER(_Blob), wintypes.LPCWSTR,
                  ctypes.POINTER(_Blob), P, P, D, ctypes.POINTER(_Blob)], B),
            (self.crypt, 'CryptUnprotectData', [ctypes.POINTER(_Blob), PP,
                  ctypes.POINTER(_Blob), P, P, D, ctypes.POINTER(_Blob)], B),
        ):
            function = getattr(library, name)
            function.argtypes, function.restype = arguments, result
        self.sid = self._user_sid()

    def _sid_text(self, sid):
        _require(sid and self.advapi.IsValidSid(sid))
        value = ctypes.c_void_p()
        _require(self.advapi.ConvertSidToStringSidW(sid, ctypes.byref(value)))
        try:
            return ctypes.wstring_at(value)
        finally:
            self.kernel.LocalFree(value)

    def _user_sid(self):
        token = wintypes.HANDLE()
        _require(self.advapi.OpenProcessToken(self.kernel.GetCurrentProcess(), 0x0008, ctypes.byref(token)))
        try:
            size = wintypes.DWORD()
            self.advapi.GetTokenInformation(token, 1, None, 0, ctypes.byref(size))
            _require(0 < size.value <= 65536)
            data = ctypes.create_string_buffer(size.value)
            _require(self.advapi.GetTokenInformation(token, 1, data, size, ctypes.byref(size)))
            return self._sid_text(ctypes.cast(data, ctypes.POINTER(_SidAndAttributes)).contents.sid)
        finally:
            self.kernel.CloseHandle(token)

    def sddl(self, *, directory):
        flags = 'OICI' if directory else ''
        return f'O:{self.sid}D:P(A;{flags};FA;;;{self.sid})(A;{flags};FA;;;SY)'

    @contextmanager
    def security_descriptor(self, sddl):
        descriptor = ctypes.c_void_p()
        _require(self.advapi.ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl, 1, ctypes.byref(descriptor), None))
        try:
            yield descriptor
        finally:
            self.kernel.LocalFree(descriptor)

    def verify_acl(self, handle, *, directory, mutable=False):
        owner, dacl, descriptor = ctypes.c_void_p(), ctypes.c_void_p(), ctypes.c_void_p()
        _require(self.advapi.GetSecurityInfo(handle, 1, 0x00000005, ctypes.byref(owner), None,
                    ctypes.byref(dacl), None, ctypes.byref(descriptor)) == 0)
        try:
            _require(self._sid_text(owner) == self.sid and dacl.value)
            control, revision = wintypes.WORD(), wintypes.DWORD()
            _require(self.advapi.GetSecurityDescriptorControl(descriptor, ctypes.byref(control), ctypes.byref(revision)))
            _require(control.value & 0x0004)
            # Identity and directory ACLs stay protected and exact. Mutable files
            # are normally created by SQLite/Python and inherit the private DACL.
            if not mutable: _require(control.value & 0x1000)
            acl = ctypes.cast(dacl, ctypes.POINTER(_ACL)).contents
            _require(1 <= acl.count <= 2 and acl.size >= ctypes.sizeof(_ACL))
            found = set()
            for index in range(acl.count):
                pointer = ctypes.c_void_p()
                _require(self.advapi.GetAce(dacl, index, ctypes.byref(pointer)))
                ace = ctypes.cast(pointer, ctypes.POINTER(_ACE)).contents
                _require(ace.type == 0 and ace.size >= ctypes.sizeof(_ACE) + 8)
                allowed_flags = (0, 0x10) if mutable and not directory else (0x03 if directory else 0,)
                _require(ace.flags in allowed_flags and ace.mask == 0x001F01FF)
                sid = ctypes.c_void_p(pointer.value + ctypes.sizeof(_ACE))
                _require(self.advapi.IsValidSid(sid))
                _require(ctypes.sizeof(_ACE) + self.advapi.GetLengthSid(sid) <= ace.size)
                text = self._sid_text(sid)
                _require(text in (self.sid, 'S-1-5-18') and text not in found)
                found.add(text)
            _require(self.sid in found)
        finally:
            self.kernel.LocalFree(descriptor)

    def information(self, handle, *, directory):
        info = _FileInfo()
        _require(self.kernel.GetFileInformationByHandle(handle, ctypes.byref(info)))
        _require(self.kernel.GetFileType(handle) == 1 and not info.attributes & 0x400)
        _require(bool(info.attributes & 0x10) == directory)
        if not directory:
            _require(info.links == 1)
        return info

    @contextmanager
    def open_existing(self, path, *, directory, private=False):
        # SHARE_READ|WRITE on directories, SHARE_READ on files, never SHARE_DELETE.
        handle = self.kernel.CreateFileW(str(path), 0x80000000, 3 if directory else 1,
                                        None, 3, 0x02200000, None)
        _require(handle not in (None, ctypes.c_void_p(-1).value))
        try:
            self.information(handle, directory=directory)
            if private: self.verify_acl(handle, directory=directory)
            yield handle
            self.information(handle, directory=directory)
            if private: self.verify_acl(handle, directory=directory)
        finally:
            self.kernel.CloseHandle(handle)


    def verify_mutable_file(self, path):
        # READ_CONTROL only; SHARE_READ|WRITE|DELETE permits SQLite journals,
        # held byte-range locks and atomic checkpoint replacement. Unlike the
        # identity reader, this is a metadata check, not a lifetime write lock.
        handle = self.kernel.CreateFileW(str(path), 0x00020000, 7, None, 3, 0x02200000, None)
        _require(handle not in (None, ctypes.c_void_p(-1).value))
        try:
            self.information(handle, directory=False)
            self.verify_acl(handle, directory=False, mutable=True)
        finally:
            self.kernel.CloseHandle(handle)


@lru_cache(maxsize=1)
def _api():
    try:
        return _API()
    except (AttributeError, OSError):
        raise WindowsStorageError() from None


def _guard(value):
    from .paired_identity import require_non_repository_state
    require_non_repository_state(value)


def _path(value):
    api = _api()
    raw = os.fspath(value)
    _require(type(raw) is str and '\x00' not in raw and not raw.startswith(('\\\\', '//')))
    _require(not any(part in ('.', '..') or part.endswith((' ', '.')) for part in re.split(r'[\\/]', raw) if part))
    path = Path(os.path.abspath(raw))
    _require(re.fullmatch('[A-Za-z]:', path.drive) is not None)
    _require(all(':' not in part for part in path.parts[1:]))
    _require(api.kernel.GetDriveTypeW(path.anchor) == 3)
    return path


def _name(value):
    _require(type(value) is str and re.fullmatch(r'[a-z][a-z0-9-]{0,62}\.[a-z0-9]{1,8}', value))
    _require(value.split('.')[0].upper() not in {'CON', 'PRN', 'AUX', 'NUL',
                    *(f'COM{i}' for i in range(10)), *(f'LPT{i}' for i in range(10))})
    return value


@contextmanager
def _ancestry(path):
    with ExitStack() as stack:
        for parent in reversed((path, *path.parents)):
            stack.enter_context(_api().open_existing(parent, directory=True))
        yield


class _PrivateFile:
    def __init__(self, path, handle):
        self.path, self.handle = path, handle

    def read(self, maximum):
        _guard(self.path.parent)
        api = _api()
        before = api.information(self.handle, directory=False)
        size = before.size_low | (before.size_high << 32)
        _require(type(maximum) is int and 0 < maximum <= 16 * 1024 * 1024 and 0 < size <= maximum)
        storage, count = ctypes.create_string_buffer(size), wintypes.DWORD()
        _require(api.kernel.ReadFile(self.handle, storage, size, ctypes.byref(count), None))
        _require(count.value == size)
        api.verify_acl(self.handle, directory=False)
        after = api.information(self.handle, directory=False)
        _require((before.size_low, before.size_high, before.written.dwLowDateTime, before.written.dwHighDateTime)
                 == (after.size_low, after.size_high, after.written.dwLowDateTime, after.written.dwHighDateTime))
        return storage.raw


class _PrivateDirectory:
    def __init__(self, path):
        self.path = path

    def names(self):
        return os.listdir(self.path)

    @contextmanager
    def open_file(self, name):
        _guard(self.path)
        path = self.path / _name(name)
        with _api().open_existing(path, directory=False, private=True) as handle:
            yield _PrivateFile(path, handle)

    def write_new(self, name, data):
        _guard(self.path)
        _require(type(data) is bytes and 0 < len(data) <= 16 * 1024 * 1024)
        api, path = _api(), self.path / _name(name)
        with api.security_descriptor(api.sddl(directory=False)) as descriptor:
            attrs = _Attributes(ctypes.sizeof(_Attributes), descriptor, False)
            handle = api.kernel.CreateFileW(str(path), 0xC0000000, 1, ctypes.byref(attrs), 1, 0x80200080, None)
            _require(handle not in (None, ctypes.c_void_p(-1).value))
            try:
                api.information(handle, directory=False)
                api.verify_acl(handle, directory=False)
                storage, count = ctypes.create_string_buffer(data), wintypes.DWORD()
                _require(api.kernel.WriteFile(handle, storage, len(data), ctypes.byref(count), None))
                _require(count.value == len(data) and api.kernel.FlushFileBuffers(handle))
            finally:
                api.kernel.CloseHandle(handle)


@contextmanager
def private_directory(value):
    _guard(value)
    try:
        path = _path(value)
        with _ancestry(path.parent), _api().open_existing(path, directory=True, private=True):
            yield _PrivateDirectory(path)
            _guard(value)
    except (OSError, TypeError):
        raise WindowsStorageError() from None


def create_mutable_file(value):
    """Atomically create an empty current-user-owned file; never adopt an old one.

    Windows token default ownership may be Administrators even inside a private
    directory. Supplying an explicit owner/DACL avoids changing token policy or
    repairing a file after creation. The caller owns the returned CRT descriptor.
    """
    path, api = _path(value), _api()
    import msvcrt
    fd = None
    try:
        with private_directory(path.parent), api.security_descriptor(api.sddl(directory=False)) as descriptor:
            attrs = _Attributes(ctypes.sizeof(_Attributes), descriptor, False)
            handle = api.kernel.CreateFileW(str(path), 0xC0000000, 3, ctypes.byref(attrs), 1, 0x80200080, None)
            _require(handle not in (None, ctypes.c_void_p(-1).value))
            try:
                api.information(handle, directory=False)
                api.verify_acl(handle, directory=False)
                fd = msvcrt.open_osfhandle(handle, os.O_RDWR | os.O_BINARY | os.O_NOINHERIT)
                handle = None  # open_osfhandle transfers ownership to the CRT.
            finally:
                if handle is not None: api.kernel.CloseHandle(handle)
        return fd
    except BaseException:
        if fd is not None: os.close(fd)
        raise


def validate_mutable_state(value):
    """Refuse unsafe existing state, including sidecars, locks and temporary files.

    The protected directory establishes safe inheritance for newly created files.
    Check every direct child rather than relying on its parent ACL: Windows
    bypass-traverse privileges can expose a known permissive child. No ACL is
    repaired. Concurrent hostile changes by the same OS account are out of scope.
    """
    with private_directory(value) as directory:
        for name in directory.names():
            _api().verify_mutable_file(directory.path / name)


def create_private_directory(value):
    _guard(value)
    try:
        path, api = _path(value), _api()
        with _ancestry(path.parent), api.security_descriptor(api.sddl(directory=True)) as descriptor:
            attrs = _Attributes(ctypes.sizeof(_Attributes), descriptor, False)
            _guard(value)
            _require(api.kernel.CreateDirectoryW(str(path), ctypes.byref(attrs)))
        with private_directory(path):
            pass
    except (OSError, TypeError):
        raise WindowsStorageError() from None


def _blob(value):
    storage = ctypes.create_string_buffer(value)
    return storage, _Blob(len(value), ctypes.cast(storage, ctypes.POINTER(ctypes.c_ubyte)))


def _dpapi(value, *, decrypt):
    _require(type(value) is bytes and 0 < len(value) <= 4096)
    api = _api()
    storage, source = _blob(value)
    extra, entropy = _blob(b'Veyra paired TLS private-key envelope v1')
    result = _Blob()
    try:
        if decrypt:
            success = api.crypt.CryptUnprotectData(ctypes.byref(source), None, ctypes.byref(entropy),
                                                  None, None, 1, ctypes.byref(result))
        else:
            success = api.crypt.CryptProtectData(ctypes.byref(source), 'Veyra TLS key envelope',
                                                 ctypes.byref(entropy), None, None, 1, ctypes.byref(result))
        _require(success and result.data and 0 < result.size <= 4096)
        return ctypes.string_at(result.data, result.size)
    finally:
        ctypes.memset(storage, 0, len(storage)); ctypes.memset(extra, 0, len(extra))
        if result.data:
            ctypes.memset(result.data, 0, result.size)
            api.kernel.LocalFree(result.data)


def protect(value):
    """User-bound DPAPI with UI forbidden; never machine-wide protection."""
    return _dpapi(value, decrypt=False)


def unprotect(value):
    return _dpapi(value, decrypt=True)
