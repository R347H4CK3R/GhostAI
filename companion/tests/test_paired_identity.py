"""Disposable synthetic identities; TLS uses memory BIOs, never a LAN socket."""
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import ssl
import stat
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

SPEC = importlib.util.find_spec('companion.paired_identity')
if SPEC:
    from companion import paired_identity as identity
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

ORIGIN = 'https://10.1.2.3:8443'


class IdentityTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(SPEC, 'private host identity is missing')
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        if os.name == 'nt':
            gate = mock.patch.object(identity, 'WINDOWS_PROTECTED_STORAGE_RELEASED', True)
            gate.start(); self.addCleanup(gate.stop)
        self.state = self.root / 'private'
        if os.name != 'nt':
            self.state.mkdir(mode=0o700)

    def initialize(self):
        return identity.initialize_identity(self.state, ORIGIN, approved=True)

    def test_origin_is_only_canonical_rfc1918_ipv4_https(self):
        self.assertEqual(identity.parse_origin(ORIGIN), ('10.1.2.3', 8443))
        for raw in ('https://172.16.1.1:1', 'https://172.31.254.254:65535', 'https://192.168.1.2:443'):
            identity.parse_origin(raw)
        for raw in (None, True, ORIGIN + '/', ORIGIN + '?', ORIGIN + '#', ORIGIN + '\n',
                    ORIGIN.upper(), 'http://10.1.2.3:8443', 'https://10.1.2.3',
                    'https://10.1.2.3:0', 'https://10.1.2.3:65536', 'https://10.1.2.3:08443',
                    'https://010.1.2.3:8443', 'https://10.1.2.0:8443', 'https://10.1.2.255:8443',
                    'https://127.0.0.1:8443', 'https://169.254.169.254:8443', 'https://100.64.1.1:8443',
                    'https://8.8.8.8:8443', 'https://localhost:8443', 'https://[fd00::1]:8443',
                    'https://user:pass@10.1.2.3:8443', 'https://172.32.1.1:8443'):
            with self.subTest(raw=raw), self.assertRaises(identity.IdentityError):
                identity.parse_origin(raw)

    def test_repository_guard_allows_only_state_itself_to_be_missing(self):
        identity.require_non_repository_state(self.root / 'prospective')
        with self.assertRaises(identity.IdentityError) as caught:
            identity.require_non_repository_state(self.root / 'absent-parent' / 'state')
        self.assertEqual(caught.exception.code, 'state_location_unavailable')

    def test_repository_markers_in_every_ancestor_block_creation_without_mutation(self):
        for kind in ('file', 'directory', 'symlink'):
            repo = self.root / ('unrelated-' + kind)
            repo.mkdir()
            marker = repo / '.git'
            if kind == 'file':
                marker.write_text('gitdir: /never/read/this/target')
            elif kind == 'directory':
                marker.mkdir()
            else:
                try:
                    marker.symlink_to(self.root / 'missing-git-target')
                except OSError:
                    continue
            middle = repo / 'nested'
            middle.mkdir()
            target = middle / 'new-state'
            before = set(repo.rglob('*'))
            for call in (lambda: identity.require_non_repository_state(target),
                         lambda: identity.create_private_state_directory(target, approved=True)):
                with self.subTest(kind=kind), self.assertRaises(identity.IdentityError) as caught:
                    call()
                self.assertEqual(caught.exception.code, 'state_inside_git_worktree')
                self.assertFalse(target.exists())
                self.assertEqual(set(repo.rglob('*')), before)

    def test_denied_repository_probe_fails_closed_and_does_not_create_state(self):
        original = os.lstat
        target = self.root / 'never-created'
        def denied(path, *args, **kwargs):
            if os.fspath(path) == str(self.root / '.git'):
                raise PermissionError('synthetic denied metadata probe')
            return original(path, *args, **kwargs)
        with mock.patch.object(identity.os, 'lstat', side_effect=denied):
            with self.assertRaises(identity.IdentityError) as caught:
                identity.create_private_state_directory(target, approved=True)
        self.assertEqual(caught.exception.code, 'state_location_unavailable')
        self.assertFalse(target.exists())

    def test_ordinary_child_creation_does_not_change_ancestor_identity(self):
        original = os.lstat
        created = False
        def create_child_after_probe(path, *args, **kwargs):
            nonlocal created
            info = original(path, *args, **kwargs)
            if os.fspath(path) == str(self.root) and not created:
                created = True
                (self.root / 'ordinary-job-checkpoint').write_bytes(b'synthetic checkpoint')
            return info
        with mock.patch.object(identity.os, 'lstat', side_effect=create_child_after_probe):
            identity.require_non_repository_state(self.state)
        self.assertEqual((self.root / 'ordinary-job-checkpoint').read_bytes(), b'synthetic checkpoint')

    def test_unstable_ancestor_and_symlink_ancestry_fail_closed(self):
        original = os.lstat
        count = 0
        def changing(path, *args, **kwargs):
            nonlocal count
            if os.fspath(path) == str(self.root):
                count += 1
                if count == 2:
                    info = original(path, *args, **kwargs)
                    return SimpleNamespace(st_dev=info.st_dev, st_ino=info.st_ino + 1,
                        st_mode=info.st_mode, st_uid=info.st_uid, st_gid=info.st_gid, st_mtime_ns=info.st_mtime_ns,
                        st_ctime_ns=info.st_ctime_ns, st_file_attributes=getattr(info, 'st_file_attributes', 0))
            return original(path, *args, **kwargs)
        with mock.patch.object(identity.os, 'lstat', side_effect=changing):
            with self.assertRaises(identity.IdentityError) as caught:
                identity.require_non_repository_state(self.state)
        self.assertEqual(caught.exception.code, 'state_location_unavailable')
        alias = self.root / 'alias'
        try:
            alias.symlink_to(self.root, target_is_directory=True)
        except OSError:
            return
        with self.assertRaises(identity.IdentityError):
            identity.require_non_repository_state(alias / 'private')
        with self.assertRaises(identity.IdentityError):
            identity.require_non_repository_state(str(alias) + '/../private')

    @unittest.skipIf(os.name == 'nt', 'POSIX storage evidence only')
    def test_creation_requires_literal_approval(self):
        for approved in (False, None, 1, 'yes'):
            with self.assertRaises(identity.IdentityError):
                identity.initialize_identity(self.state, ORIGIN, approved=approved)
        self.assertEqual(list(self.state.iterdir()), [])

    @unittest.skipIf(os.name == 'nt', 'POSIX storage evidence only')
    def test_durable_identity_and_certificate_policy(self):
        result = self.initialize()
        self.assertEqual(set(result), {'v', 'host_id', 'origin', 'tls_leaf_sha256'})
        self.assertEqual(identity.load_identity(self.state), result)
        cert = x509.load_pem_x509_certificate(identity.certificate_pem(self.state))
        cert.verify_directly_issued_by(cert)
        self.assertEqual(cert.fingerprint(hashes.SHA256()).hex(), result['tls_leaf_sha256'])
        self.assertEqual(cert.not_valid_after_utc - cert.not_valid_before_utc, timedelta(days=30))
        self.assertEqual(list(cert.extensions.get_extension_for_class(x509.ExtendedKeyUsage).value),
                         [ExtendedKeyUsageOID.SERVER_AUTH])
        self.assertEqual([str(item.value) for item in cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value],
                         ['10.1.2.3'])
        for path in self.state.iterdir():
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(path.stat().st_nlink, 1)
        before = {p.name: p.read_bytes() for p in self.state.iterdir()}
        with self.assertRaises(identity.IdentityError):
            self.initialize()
        self.assertEqual({p.name: p.read_bytes() for p in self.state.iterdir()}, before)

    @unittest.skipIf(os.name == 'nt', 'POSIX storage evidence only')
    def test_moved_state_under_git_blocks_all_direct_apis_without_mutation(self):
        self.initialize()
        identity.create_private_file(self.state, 'host-config.json', b'{"v":1}')
        repo = self.root / 'repo'
        repo.mkdir()
        (repo / '.git').write_text('gitdir: /never/follow')
        moved = repo / 'state'
        self.state.rename(moved)
        before = {p.name: p.read_bytes() for p in moved.iterdir()}
        for operation in (lambda: identity.load_identity(moved), lambda: identity.server_ssl_context(moved),
                          lambda: identity.certificate_pem(moved),
                          lambda: identity.read_private_file(moved, 'host-config.json', 4096),
                          lambda: identity.create_private_file(moved, 'new-config.json', b'{}'),
                          lambda: identity.initialize_identity(moved, ORIGIN, approved=True)):
            with self.assertRaises(identity.IdentityError) as caught:
                operation()
            self.assertEqual(caught.exception.code, 'state_inside_git_worktree')
            self.assertEqual({p.name: p.read_bytes() for p in moved.iterdir()}, before)

    @unittest.skipIf(os.name == 'nt', 'POSIX storage evidence only')
    def test_marker_in_state_blocks_initialization_before_key_creation(self):
        (self.state / '.git').mkdir()
        with self.assertRaises(identity.IdentityError) as caught:
            self.initialize()
        self.assertEqual(caught.exception.code, 'state_inside_git_worktree')
        self.assertEqual([p.name for p in self.state.iterdir()], ['.git'])

    @unittest.skipIf(os.name == 'nt', 'POSIX storage evidence only')
    def test_private_config_helpers_are_bounded_exclusive_and_never_export_keys(self):
        identity.create_private_file(self.state, 'host-config.json', b'{"v":1}')
        self.assertEqual(identity.read_private_file(self.state, 'host-config.json', 8), b'{"v":1}')
        with self.assertRaises(identity.IdentityError):
            identity.read_private_file(self.state, 'host-config.json', 6)
        with self.assertRaises(identity.IdentityError):
            identity.create_private_file(self.state, 'host-config.json', b'changed')
        for name in ('../escape.json', 'identity-key.pem', 'identity-key-protection.bin', 'identity.json'):
            with self.assertRaises(identity.IdentityError):
                identity.read_private_file(self.state, name, 4096)
        (self.state / 'host-config.json').chmod(0o644)
        with self.assertRaises(identity.IdentityError):
            identity.read_private_file(self.state, 'host-config.json', 4096)

    @unittest.skipIf(os.name == 'nt', 'POSIX storage evidence only')
    def test_links_wrong_permissions_missing_state_and_corruption_fail_closed(self):
        self.initialize()
        key = self.state / 'identity-key.pem'
        alias = self.root / 'key-alias'
        os.link(key, alias)
        with self.assertRaises(identity.IdentityError): identity.load_identity(self.state)
        alias.unlink()
        key.chmod(0o640)
        with self.assertRaises(identity.IdentityError): identity.load_identity(self.state)
        key.chmod(0o600)
        original = key.read_bytes()
        key.write_bytes(original + original)
        with self.assertRaises(identity.IdentityError): identity.load_identity(self.state)
        key.write_bytes(original)
        metadata = self.state / 'identity.json'
        value = json.loads(metadata.read_bytes())
        value['tls_leaf_sha256'] = '0' * 64
        metadata.write_text(json.dumps(value))
        with self.assertRaises(identity.IdentityError): identity.server_ssl_context(self.state)
        with self.assertRaises(identity.IdentityError): identity.load_identity(self.root / 'missing')

    @unittest.skipIf(os.name == 'nt', 'POSIX storage evidence only')
    def test_tls_memory_handshake_has_valid_pin_and_no_tickets(self):
        result = self.initialize()
        server_context = identity.server_ssl_context(self.state)
        self.assertGreaterEqual(server_context.minimum_version, ssl.TLSVersion.TLSv1_2)
        self.assertTrue(server_context.options & ssl.OP_NO_TICKET)
        self.assertEqual(server_context.num_tickets, 0)
        for version in (ssl.TLSVersion.TLSv1_2, ssl.TLSVersion.TLSv1_3):
            client_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            client_context.minimum_version = client_context.maximum_version = version
            client_context.load_verify_locations(cadata=identity.certificate_pem(self.state).decode())
            ci, co, si, so = (ssl.MemoryBIO() for _ in range(4))
            client = client_context.wrap_bio(ci, co, server_hostname='10.1.2.3')
            server = server_context.wrap_bio(si, so, server_side=True)
            done = set()
            for _ in range(20):
                for name, endpoint in (('client', client), ('server', server)):
                    if name not in done:
                        try: endpoint.do_handshake(); done.add(name)
                        except ssl.SSLWantReadError: pass
                si.write(co.read()); ci.write(so.read())
                if len(done) == 2: break
            self.assertEqual(len(done), 2)
            self.assertEqual(hashlib.sha256(client.getpeercert(binary_form=True)).hexdigest(), result['tls_leaf_sha256'])

    def rewrite_synthetic_certificate(self, *, san=None, eku=None, expired=False, future=False,
                                      ca=False, wrong_signer=False, extra=False):
        key = serialization.load_pem_private_key((self.state / 'identity-key.pem').read_bytes(), None)
        metadata = json.loads((self.state / 'identity.json').read_bytes())
        now = datetime.now(timezone.utc)
        start, end = now - timedelta(minutes=5), now + timedelta(days=29)
        if expired: start, end = now - timedelta(days=31), now - timedelta(days=1)
        if future: start, end = now + timedelta(days=1), now + timedelta(days=30)
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Veyra paired host ' + metadata['host_id'])])
        builder = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key())
                   .serial_number(x509.random_serial_number()).not_valid_before(start).not_valid_after(end)
                   .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
                   .add_extension(x509.SubjectAlternativeName(san if san is not None else
                       [x509.IPAddress(ipaddress.ip_address('10.1.2.3'))]), critical=False)
                   .add_extension(x509.ExtendedKeyUsage(eku if eku is not None else
                       [ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
                   .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False,
                       key_encipherment=False, data_encipherment=False, key_agreement=False,
                       key_cert_sign=False, crl_sign=False, encipher_only=False, decipher_only=False), critical=True))
        if extra: builder = builder.add_extension(x509.UnrecognizedExtension(x509.ObjectIdentifier('1.2.3.4.5'), b'unexpected'), critical=True)
        cert = builder.sign(ec.generate_private_key(ec.SECP256R1()) if wrong_signer else key, hashes.SHA256())
        (self.state / 'identity-cert.pem').write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        metadata['tls_leaf_sha256'] = cert.fingerprint(hashes.SHA256()).hex()
        (self.state / 'identity.json').write_text(json.dumps(metadata))

    @unittest.skipIf(os.name == 'nt', 'POSIX storage evidence only')
    def test_invalid_certificate_policy_fails_even_with_updated_pin(self):
        self.initialize()
        for change in (dict(expired=True), dict(future=True), dict(ca=True), dict(wrong_signer=True),
                       dict(extra=True), dict(eku=[ExtendedKeyUsageOID.CLIENT_AUTH]),
                       dict(eku=[ExtendedKeyUsageOID.SERVER_AUTH, ExtendedKeyUsageOID.CLIENT_AUTH]),
                       dict(san=[x509.DNSName('10.1.2.3')]),
                       dict(san=[x509.IPAddress(ipaddress.ip_address('10.1.2.4'))]),
                       dict(san=[x509.IPAddress(ipaddress.ip_address('10.1.2.3')),
                                 x509.IPAddress(ipaddress.ip_address('10.1.2.4'))])):
            self.rewrite_synthetic_certificate(**change)
            before = {p.name: p.read_bytes() for p in self.state.iterdir()}
            with self.subTest(change=change), self.assertRaises(identity.IdentityError):
                identity.load_identity(self.state)
            self.assertEqual({p.name: p.read_bytes() for p in self.state.iterdir()}, before)

    @unittest.skipIf(os.name == 'nt', 'POSIX storage evidence only')
    def test_metadata_duplicate_unknown_fields_and_wrong_host_fail_without_repair(self):
        self.initialize()
        path = self.state / 'identity.json'
        original = path.read_bytes()
        value = json.loads(original)
        for raw in (b'bad', b'{}', b' ' * 4097, original[:-1] + b',"v":1}',
                    json.dumps(dict(value, v=True)).encode(), json.dumps(dict(value, extra=1)).encode(),
                    json.dumps(dict(value, host_id='11111111-1111-4111-8111-111111111111')).encode(),
                    json.dumps(dict(value, origin='https://10.1.2.4:8443')).encode()):
            path.write_bytes(raw)
            with self.assertRaises(identity.IdentityError): identity.load_identity(self.state)
            self.assertEqual(path.read_bytes(), raw)

    @unittest.skipIf(os.name == 'nt', 'POSIX storage evidence only')
    def test_fifo_and_symlink_identity_files_are_rejected_without_blocking(self):
        self.initialize()
        path = self.state / 'identity-key.pem'
        outside = self.root / 'synthetic-key'
        path.rename(outside)
        path.symlink_to(outside)
        with self.assertRaises(identity.IdentityError): identity.load_identity(self.state)
        path.unlink()
        os.mkfifo(path, mode=0o600)
        with self.assertRaises(identity.IdentityError): identity.load_identity(self.state)

    @unittest.skipIf(os.name == 'nt', 'POSIX storage evidence only')
    def test_disk_failure_retains_partial_state_and_never_resets(self):
        with mock.patch.object(identity.os, 'fsync', side_effect=OSError('synthetic disk failure')):
            with self.assertRaises(identity.IdentityError): self.initialize()
        self.assertTrue(list(self.state.iterdir()))
        before = {p.name: p.read_bytes() for p in self.state.iterdir()}
        with self.assertRaises(identity.IdentityError): self.initialize()
        self.assertEqual({p.name: p.read_bytes() for p in self.state.iterdir()}, before)

    @unittest.skipIf(os.name == 'nt', 'POSIX storage evidence only')
    def test_tls_rejects_wrong_address_and_untrusted_certificate_before_app_data(self):
        self.initialize()
        for hostname, trust in (('10.1.2.4', True), ('10.1.2.3', False)):
            client_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            if trust: client_context.load_verify_locations(cadata=identity.certificate_pem(self.state).decode())
            ci, co, si, so = (ssl.MemoryBIO() for _ in range(4))
            client = client_context.wrap_bio(ci, co, server_hostname=hostname)
            server = identity.server_ssl_context(self.state).wrap_bio(si, so, server_side=True)
            with self.assertRaises(ssl.SSLCertVerificationError):
                for _ in range(20):
                    for endpoint in (client, server):
                        try: endpoint.do_handshake()
                        except ssl.SSLWantReadError: pass
                    si.write(co.read()); ci.write(so.read())

    @unittest.skipIf(os.name == 'nt', 'POSIX storage evidence only')
    def test_private_directory_creation_is_approved_exclusive_and_does_not_resecure(self):
        target = self.root / 'new-private'
        with self.assertRaises(identity.IdentityError): identity.create_private_state_directory(target)
        self.assertFalse(target.exists())
        identity.create_private_state_directory(target, approved=True)
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o700)
        target.chmod(0o755)
        with self.assertRaises(identity.IdentityError): identity.create_private_state_directory(target, approved=True)
        with self.assertRaises(identity.IdentityError): identity.initialize_identity(target, ORIGIN, approved=True)
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o755)
        self.assertEqual(list(target.iterdir()), [])

    @unittest.skipIf(os.name == 'nt', 'POSIX storage evidence only')
    def test_existing_nonidentity_state_and_wrong_owner_are_never_accepted(self):
        for name in ('paired.sqlite', 'identity-key.pem', 'identity.json', 'unknown'):
            path = self.state / name
            path.write_bytes(b'synthetic existing state')
            with self.assertRaises(identity.IdentityError): self.initialize()
            self.assertEqual(path.read_bytes(), b'synthetic existing state')
            self.assertEqual(len(list(self.state.iterdir())), 1)
            path.unlink()
        self.initialize()
        wrong = os.geteuid() + 1
        with mock.patch.object(identity.os, 'geteuid', return_value=wrong):
            with self.assertRaises(identity.IdentityError): identity.load_identity(self.state)

    def test_windows_product_gate_is_closed_before_creation(self):
        target = self.root / 'must-not-exist'
        with mock.patch.object(identity.os, 'name', 'nt'), mock.patch.object(identity, 'WINDOWS_PROTECTED_STORAGE_RELEASED', False):
            with self.assertRaises(identity.IdentityError) as caught:
                identity.create_private_state_directory(target, approved=True)
        self.assertEqual(caught.exception.code, 'windows_protected_storage_unavailable')
        self.assertFalse(target.exists())


if __name__ == '__main__': unittest.main()
