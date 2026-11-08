"""Explicit, durable HTTPS identity with protected storage outside Git worktrees.

No listener, enrollment, silent reset, certificate rotation, or key-export API.
POSIX requires trusted local ancestry and owner-only state. Windows uses native
DACL/DPAPI storage but remains source-gated pending real Windows CI and review.
"""
from contextlib import contextmanager, ExitStack
from datetime import datetime, timedelta, timezone
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import ssl
import stat
import uuid

from cryptography import x509
from cryptography.exceptions import InvalidSignature, UnsupportedAlgorithm
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID, SignatureAlgorithmOID

METADATA_FILE = 'identity.json'
CERTIFICATE_FILE = 'identity-cert.pem'
PRIVATE_KEY_FILE = 'identity-key.pem'
KEY_PROTECTION_FILE = 'identity-key-protection.bin'
MAX_METADATA_BYTES = 4096
MAX_PEM_BYTES = 16384
LIFETIME = timedelta(days=30)
# No CLI or environment override. Native Windows storage/lifecycle evidence and
# independent review are recorded in docs/PAIRED_EXECUTION.md.
WINDOWS_PROTECTED_STORAGE_RELEASED = True
_ORIGIN = re.compile(r'https://([0-9]{1,3}(?:\.[0-9]{1,3}){3}):([1-9][0-9]{0,4})', re.ASCII)
_NETWORKS = tuple(ipaddress.IPv4Network(item) for item in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'))


class IdentityError(ValueError):
    """A stable local code, never a private path, raw exception, or key."""
    def __init__(self, code='identity_invalid'):
        self.code = code
        super().__init__(code)


def parse_origin(origin):
    match = _ORIGIN.fullmatch(origin) if type(origin) is str else None
    if match is None:
        raise IdentityError('invalid_origin')
    address, port = match.groups()
    try:
        ip = ipaddress.IPv4Address(address)
    except ipaddress.AddressValueError:
        raise IdentityError('invalid_origin') from None
    port = int(port)
    if (str(ip) != address or not 1 <= port <= 65535 or (int(ip) & 255) in (0, 255)
            or not any(ip in network for network in _NETWORKS)):
        raise IdentityError('invalid_origin')
    return address, port


def _state_path(value):
    try:
        raw = os.fspath(value)
        if (type(raw) is not str or not raw or '\x00' in raw
                or '..' in re.split(r'[\\/]', raw)):
            raise IdentityError('state_location_unavailable')
        return Path(os.path.abspath(raw))
    except (OSError, TypeError, ValueError) as error:
        if isinstance(error, IdentityError):
            raise
        raise IdentityError('state_location_unavailable') from None


def _location_stamp(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid,
            info.st_mtime_ns, info.st_ctime_ns, getattr(info, 'st_file_attributes', 0))


def _ancestry_stamp(info):
    # Ordinary child/checkpoint creation changes directory timestamps, not the
    # identity or access boundary of the path we are checking.
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            getattr(info, 'st_file_attributes', 0))


def require_non_repository_state(state_dir):
    """Metadata-only Git exclusion; never read .git or follow a gitdir target.

    Probe .git with lstat in the state directory and EVERY ancestor, including
    the filesystem root. Any marker type is forbidden. Only the prospective
    state itself may be absent. Inaccessible, linked, missing, or changing
    ancestry fails closed. This does not make hostile concurrent ancestor
    replacement safe; local ancestry must still be trusted.
    """
    path = _state_path(state_dir)
    components = (path, *path.parents)
    observed = []
    try:
        for index, component in enumerate(components):
            try:
                info = os.lstat(component)
            except FileNotFoundError:
                if index != 0:
                    raise IdentityError('state_location_unavailable')
                info = None
            if info is not None:
                if (not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)
                        or getattr(info, 'st_file_attributes', 0) & 0x400):
                    raise IdentityError('state_location_unavailable')
            observed.append(None if info is None else _ancestry_stamp(info))
            try:
                os.lstat(component / '.git')
            except FileNotFoundError:
                pass
            else:
                raise IdentityError('state_inside_git_worktree')
        # Repeat metadata probes and compare ancestry; an absent marker is not
        # trusted if its containing directory disappeared or changed meanwhile.
        for index, component in enumerate(components):
            try:
                info = os.lstat(component)
                current = _ancestry_stamp(info)
            except FileNotFoundError:
                if index != 0 or observed[index] is not None:
                    raise IdentityError('state_location_unavailable')
                current = None
            if current != observed[index]:
                raise IdentityError('state_location_unavailable')
            try:
                os.lstat(component / '.git')
            except FileNotFoundError:
                pass
            else:
                raise IdentityError('state_inside_git_worktree')
    except IdentityError:
        raise
    except (OSError, ValueError, TypeError):
        raise IdentityError('state_location_unavailable') from None


def _supported_storage():
    if os.name == 'nt':
        if not WINDOWS_PROTECTED_STORAGE_RELEASED:
            raise IdentityError('windows_protected_storage_unavailable')
        return
    if (os.name != 'posix' or not hasattr(os, 'geteuid')
            or not hasattr(os, 'O_NOFOLLOW') or not hasattr(os, 'O_DIRECTORY')):
        raise IdentityError('protected_storage_unavailable')


def _windows():
    from . import paired_windows
    return paired_windows


def _same_file(first, second):
    return (first.st_dev, first.st_ino) == (second.st_dev, second.st_ino)


def _private(info, directory=False):
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if (not kind(info.st_mode) or stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600)
            or info.st_uid != os.geteuid() or (not directory and info.st_nlink != 1)
            or getattr(info, 'st_file_attributes', 0) & 0x400):
        raise IdentityError('identity_storage_unavailable')


@contextmanager
def _directory(state_dir):
    _supported_storage()
    require_non_repository_state(state_dir)
    if os.name == 'nt':
        try:
            with _windows().private_directory(state_dir) as directory:
                yield directory
                require_non_repository_state(state_dir)
        except IdentityError:
            raise
        except (OSError, ValueError, TypeError):
            raise IdentityError('windows_protected_storage_unavailable') from None
        return
    descriptor = None
    try:
        path = _state_path(state_dir)
        before = os.lstat(path)
        _private(before, directory=True)
        descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, 'O_CLOEXEC', 0))
        opened = os.fstat(descriptor)
        _private(opened, directory=True)
        if not _same_file(before, opened):
            raise IdentityError('identity_storage_unavailable')
        yield (descriptor, path)
        _private(os.fstat(descriptor), directory=True)
        if not _same_file(opened, os.lstat(path)):
            raise IdentityError('identity_storage_unavailable')
        require_non_repository_state(path)
    except IdentityError:
        raise
    except (OSError, TypeError, ValueError):
        raise IdentityError('identity_storage_unavailable') from None
    finally:
        if descriptor is not None:
            os.close(descriptor)


@contextmanager
def _file(directory, name):
    if os.name == 'nt':
        with directory.open_file(name) as source:
            yield source
        return
    descriptor, path = directory
    require_non_repository_state(path)
    before = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
    _private(before)
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | getattr(os, 'O_CLOEXEC', 0), dir_fd=descriptor)
    try:
        opened = os.fstat(fd)
        _private(opened)
        if not _same_file(before, opened):
            raise IdentityError('identity_storage_unavailable')
        yield fd
        _private(os.fstat(fd))
        if not _same_file(opened, os.stat(name, dir_fd=descriptor, follow_symlinks=False)):
            raise IdentityError('identity_storage_unavailable')
    finally:
        os.close(fd)


def _read(descriptor, maximum):
    if os.name == 'nt':
        return descriptor.read(maximum)
    before = os.fstat(descriptor)
    _private(before)
    if not 0 < before.st_size <= maximum:
        raise IdentityError('identity_storage_unavailable')
    chunks, size = [], 0
    while size <= maximum:
        chunk = os.read(descriptor, min(4096, maximum + 1 - size))
        if not chunk:
            break
        chunks.append(chunk)
        size += len(chunk)
    after = os.fstat(descriptor)
    if (size != before.st_size or size > maximum or _location_stamp(before) != _location_stamp(after)):
        raise IdentityError('identity_storage_unavailable')
    return b''.join(chunks)


def _write_new(directory, name, data):
    path = directory.path if os.name == 'nt' else directory[1]
    require_non_repository_state(path)
    if os.name == 'nt':
        directory.write_new(name, data)
        return
    root = directory[0]
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
                 | getattr(os, 'O_CLOEXEC', 0), 0o600, dir_fd=root)
    try:
        _private(os.fstat(fd))
        remaining = memoryview(data)
        while remaining:
            written = os.write(fd, remaining)
            if written <= 0:
                raise IdentityError('identity_storage_unavailable')
            remaining = remaining[written:]
        os.fsync(fd)
    finally:
        os.close(fd)
    os.fsync(root)


def create_private_state_directory(state_dir, *, approved=False):
    if approved is not True:
        raise IdentityError('identity_approval_required')
    _supported_storage()
    require_non_repository_state(state_dir)
    try:
        if os.name == 'nt':
            _windows().create_private_directory(state_dir)
        else:
            path = _state_path(state_dir)
            fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                require_non_repository_state(path)
                os.mkdir(path.name, 0o700, dir_fd=fd)
                os.fsync(fd)
            finally:
                os.close(fd)
        with _directory(state_dir):
            pass
    except IdentityError:
        raise
    except (OSError, ValueError, TypeError):
        raise IdentityError('identity_storage_unavailable') from None


def _config_name(name):
    reserved = {'CON', 'PRN', 'AUX', 'NUL', *(f'COM{i}' for i in range(10)), *(f'LPT{i}' for i in range(10))}
    if (type(name) is not str or not re.fullmatch(r'[a-z][a-z0-9-]{0,62}\.[a-z0-9]{1,8}', name)
            or name in (METADATA_FILE, CERTIFICATE_FILE, PRIVATE_KEY_FILE, KEY_PROTECTION_FILE)
            or name.split('.')[0].upper() in reserved):
        raise IdentityError('invalid_private_file')


def read_private_file(state_dir, name, maximum):
    _config_name(name)
    if type(maximum) is not int or not 0 < maximum <= 1024 * 1024:
        raise IdentityError('invalid_private_file')
    with _directory(state_dir) as directory, _file(directory, name) as fd:
        return _read(fd, maximum)


def create_private_file(state_dir, name, data):
    _config_name(name)
    if type(data) is not bytes or not 0 < len(data) <= 1024 * 1024:
        raise IdentityError('invalid_private_file')
    with _directory(state_dir) as directory:
        _write_new(directory, name, data)


def _subject(host_id):
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Veyra paired host ' + host_id)])


def _extensions(address):
    return ((x509.BasicConstraints(ca=False, path_length=None), True),
            (x509.SubjectAlternativeName([x509.IPAddress(ipaddress.IPv4Address(address))]), False),
            (x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), False),
            (x509.KeyUsage(digital_signature=True, content_commitment=False, key_encipherment=False,
                          data_encipherment=False, key_agreement=False, key_cert_sign=False,
                          crl_sign=False, encipher_only=False, decipher_only=False), True))


def initialize_identity(state_dir, origin, *, approved=False):
    if approved is not True:
        raise IdentityError('identity_approval_required')
    _supported_storage()
    address, _ = parse_origin(origin)
    with _directory(state_dir) as directory:
        if (directory.names() if os.name == 'nt' else os.listdir(directory[0])):
            raise IdentityError('identity_already_exists')
        require_non_repository_state(state_dir)
        key = ec.generate_private_key(ec.SECP256R1())
        host_id = str(uuid.uuid4())
        start = datetime.now(timezone.utc).replace(microsecond=0) - timedelta(minutes=5)
        builder = (x509.CertificateBuilder().subject_name(_subject(host_id)).issuer_name(_subject(host_id))
                   .public_key(key.public_key()).serial_number(x509.random_serial_number())
                   .not_valid_before(start).not_valid_after(start + LIFETIME))
        for extension, critical in _extensions(address):
            builder = builder.add_extension(extension, critical=critical)
        cert = builder.sign(key, hashes.SHA256())
        metadata = {'v': 1, 'host_id': host_id, 'origin': origin,
                    'tls_leaf_sha256': cert.fingerprint(hashes.SHA256()).hex()}
        password = secrets.token_hex(32).encode('ascii') if os.name == 'nt' else None
        encryption = serialization.BestAvailableEncryption(password) if password else serialization.NoEncryption()
        _write_new(directory, PRIVATE_KEY_FILE, key.private_bytes(serialization.Encoding.PEM,
                    serialization.PrivateFormat.PKCS8, encryption))
        if password is not None:
            _write_new(directory, KEY_PROTECTION_FILE, _windows().protect(password))
        _write_new(directory, CERTIFICATE_FILE, cert.public_bytes(serialization.Encoding.PEM))
        # Metadata is written last. Partial state is retained and blocks retry;
        # there is no automatic repair, fresh identity, or silent re-enrollment.
        _write_new(directory, METADATA_FILE, json.dumps(metadata, sort_keys=True, separators=(',', ':')).encode())
    return load_identity(state_dir)


def _metadata(raw):
    def pairs(items):
        value = {}
        for key, item in items:
            if key in value:
                raise ValueError()
            value[key] = item
        return value
    def reject(_):
        raise ValueError()
    value = json.loads(raw.decode('utf-8'), object_pairs_hook=pairs, parse_float=reject, parse_constant=reject)
    if (type(value) is not dict or set(value) != {'v', 'host_id', 'origin', 'tls_leaf_sha256'}
            or type(value['v']) is not int or value['v'] != 1
            or type(value['host_id']) is not str or str(uuid.UUID(value['host_id'])) != value['host_id']
            or type(value['tls_leaf_sha256']) is not str
            or not re.fullmatch('[0-9a-f]{64}', value['tls_leaf_sha256'])):
        raise ValueError()
    parse_origin(value['origin'])
    return value


def _validate(metadata_raw, cert_raw, key_raw, password=None):
    try:
        metadata = _metadata(metadata_raw)
        address, _ = parse_origin(metadata['origin'])
        cert = x509.load_pem_x509_certificate(cert_raw)
        key = serialization.load_pem_private_key(key_raw, password=password)
        if (cert.public_bytes(serialization.Encoding.PEM) != cert_raw
                or not isinstance(key, ec.EllipticCurvePrivateKey) or not isinstance(key.curve, ec.SECP256R1)):
            raise ValueError()
        if password is None:
            if key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                 serialization.NoEncryption()) != key_raw:
                raise ValueError()
        elif not re.fullmatch(rb'-----BEGIN ENCRYPTED PRIVATE KEY-----\n[A-Za-z0-9+/=\n]+\n-----END ENCRYPTED PRIVATE KEY-----\n', key_raw):
            raise ValueError()
        public = cert.public_key()
        if (not isinstance(public, ec.EllipticCurvePublicKey) or not isinstance(public.curve, ec.SECP256R1)
                or public.public_numbers() != key.public_key().public_numbers()
                or cert.subject != _subject(metadata['host_id']) or cert.issuer != cert.subject
                or cert.version != x509.Version.v3
                or cert.signature_algorithm_oid != SignatureAlgorithmOID.ECDSA_WITH_SHA256):
            raise ValueError()
        public.verify(cert.signature, cert.tbs_certificate_bytes, ec.ECDSA(hashes.SHA256()))
        if not cert.not_valid_before_utc <= datetime.now(timezone.utc) < cert.not_valid_after_utc:
            raise IdentityError('identity_certificate_expired_or_not_yet_valid')
        if not timedelta(0) < cert.not_valid_after_utc - cert.not_valid_before_utc <= LIFETIME:
            raise ValueError()
        expected = _extensions(address)
        if len(cert.extensions) != len(expected):
            raise ValueError()
        for value, critical in expected:
            actual = cert.extensions.get_extension_for_oid(value.oid)
            if actual.value != value or actual.critical != critical:
                raise ValueError()
        if not hmac.compare_digest(cert.fingerprint(hashes.SHA256()).hex(), metadata['tls_leaf_sha256']):
            raise ValueError()
        return metadata
    except IdentityError:
        raise
    except (ValueError, TypeError, KeyError, UnicodeError, RecursionError, InvalidSignature,
            UnsupportedAlgorithm, x509.ExtensionNotFound, x509.DuplicateExtension):
        raise IdentityError('identity_invalid') from None


@contextmanager
def _validated_files(state_dir):
    with _directory(state_dir) as directory, ExitStack() as stack:
        descriptors = {name: stack.enter_context(_file(directory, name))
                       for name in (METADATA_FILE, CERTIFICATE_FILE, PRIVATE_KEY_FILE)}
        metadata_raw = _read(descriptors[METADATA_FILE], MAX_METADATA_BYTES)
        cert_raw = _read(descriptors[CERTIFICATE_FILE], MAX_PEM_BYTES)
        key_raw = _read(descriptors[PRIVATE_KEY_FILE], MAX_PEM_BYTES)
        password = None
        if os.name == 'nt':
            envelope = stack.enter_context(_file(directory, KEY_PROTECTION_FILE))
            password = _windows().unprotect(_read(envelope, 4096))
            if not re.fullmatch(rb'[0-9a-f]{64}', password):
                raise IdentityError('identity_invalid')
        metadata = _validate(metadata_raw, cert_raw, key_raw, password)
        del key_raw
        yield metadata, cert_raw, descriptors, password


def load_identity(state_dir):
    with _validated_files(state_dir) as (metadata, _, _, _):
        return metadata


def certificate_pem(state_dir):
    with _validated_files(state_dir) as (_, cert_raw, _, _):
        return cert_raw


def _descriptor_path(descriptor):
    if os.name == 'nt':
        return str(descriptor.path)
    for root in ('/proc/self/fd', '/dev/fd'):
        candidate = f'{root}/{descriptor}'
        try:
            # macOS /dev/fd entries are descriptor devices: stat(path) reports
            # the device, while opening it duplicates the protected file. Check
            # the opened object, never fall back to reopening the state path.
            probe = os.open(candidate, os.O_RDONLY | os.O_NONBLOCK | getattr(os, 'O_CLOEXEC', 0))
            try:
                matches = _same_file(os.fstat(probe), os.fstat(descriptor))
            finally:
                os.close(probe)
            if matches:
                os.lseek(descriptor, 0, os.SEEK_SET)
                return candidate
        except OSError:
            continue
    raise IdentityError('protected_tls_key_loading_unavailable')


def server_ssl_context(state_dir):
    """Create no listener. No tickets/PSK or early-data acceptance is enabled."""
    with _validated_files(state_dir) as (_, _, descriptors, password):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.options |= ssl.OP_NO_TICKET | ssl.OP_NO_COMPRESSION
        context.num_tickets = 0
        context.set_ciphers('ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-GCM-SHA256')
        context.set_alpn_protocols(['http/1.1'])
        context.load_cert_chain(certfile=_descriptor_path(descriptors[CERTIFICATE_FILE]),
                                keyfile=_descriptor_path(descriptors[PRIVATE_KEY_FILE]), password=password)
        return context
