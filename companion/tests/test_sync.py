import copy
import json
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from companion.core import Memory
try:
    from companion import sync
except ImportError:
    sync = None


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(sync, "encrypted snapshot implementation missing")
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / 'memory.enc'
        self.a, self.b = Memory(':memory:'), Memory(':memory:')
        self.ident = self.a.add('work', 'Useful offline note', 'user conversation')
        self.a.add('private', 'Other project', 'user')
        self.password = 'a long unique test passphrase'

    def tearDown(self):
        self.a.close()
        self.b.close()
        self.tmp.cleanup()

    def export(self):
        return sync.export_snapshot(self.a, self.path, self.password, project='work')

    def test_round_trip_scope_provenance_and_duplicates(self):
        self.a.audit('task', 'completed', 1, None)
        self.assertEqual(self.export(), 1)
        self.assertNotIn(b'Useful offline note', self.path.read_bytes())
        result = sync.import_snapshot(self.b, self.path, self.password)
        self.assertEqual(result, {'added': 1, 'duplicates': 0, 'conflicts': []})
        self.assertEqual(self.a.search('work', ''), self.b.search('work', ''))
        self.assertEqual(self.b.search('private', ''), [])
        self.assertEqual(self.b.tasks(), [])
        self.assertEqual(sync.import_snapshot(self.b, self.path, self.password)['duplicates'], 1)

    def test_explicit_scope_and_exclusive_output(self):
        for kw in ({}, {'project': 'work', 'all_projects': True}):
            with self.assertRaises(sync.SyncError):
                sync.export_snapshot(self.a, self.path, self.password, **kw)
        self.assertEqual(sync.export_snapshot(self.a, self.path, self.password, all_projects=True), 2)
        with self.assertRaises(FileExistsError):
            self.export()

    def test_random_encryption_wrong_password_and_tampering(self):
        self.export()
        first = self.path.read_bytes()
        self.path.unlink()
        self.export()
        self.assertNotEqual(first, self.path.read_bytes())
        with self.assertRaises(sync.SyncError):
            sync.import_snapshot(self.b, self.path, 'wrong')
        for index in (0, len(sync.HEADER), len(first) - 1):
            data = bytearray(first)
            data[index] ^= 1
            self.path.write_bytes(data)
            with self.assertRaises(sync.SyncError):
                sync.import_snapshot(self.b, self.path, self.password)
        self.assertEqual(self.b.search('work', ''), [])

    def test_conflict_preserved_deterministic_and_repeatable(self):
        self.export()
        row = self.a.search('work', '')[0]
        with self.b.db:
            self.b.db.execute('INSERT INTO memories VALUES (?,?,?,?,?)',
                              (row['id'], row['project'], 'Local change', row['source'], row['created']))
        result = sync.import_snapshot(self.b, self.path, self.password)
        self.assertEqual(result['added'], 1)
        self.assertEqual(len(result['conflicts']), 1)
        self.assertEqual(result['conflicts'][0]['original_id'], self.ident)
        self.assertEqual(len(self.b.search('work', '')), 2)
        repeat = sync.import_snapshot(self.b, self.path, self.password)
        self.assertEqual(repeat['added'], 0)
        self.assertEqual(repeat['duplicates'], 1)
        self.assertEqual(repeat['conflicts'], result['conflicts'])

    def test_invalid_schema_credentials_bounds(self):
        good = {'version': 1, 'records': self.a.search('work', '')}
        bad = []
        for key, value in [('version', True), ('version', 2), ('records', {}), ('extra', 1)]:
            item = copy.deepcopy(good)
            item[key] = value
            bad.append(item)
        for key, value in [('id', ''), ('created', float('nan')), ('created', True), ('source', 'password=secret'), ('body', 'x' * 65537), ('project', '')]:
            item = copy.deepcopy(good)
            item['records'][0][key] = value
            bad.append(item)
        bad.append({'version': 1, 'records': good['records'] * 2})
        for item in bad:
            with self.subTest(item=str(item)[:80]), self.assertRaises(sync.SyncError):
                sync.validate_snapshot(item)
        with patch.object(sync, 'MAX_RECORDS', 0), self.assertRaises(sync.SyncError):
            sync.validate_snapshot(good)
        self.path.write_bytes(b'x' * 1025)
        with patch.object(sync, 'MAX_FILE_BYTES', 1024), self.assertRaises(sync.SyncError):
            sync.import_snapshot(self.b, self.path, self.password)
        with patch.object(sync, 'MAX_FILE_BYTES', 100), self.assertRaises(sync.SyncError):
            self.export()

    def test_decoded_snapshot_byte_bound(self):
        good = {'version': 1, 'records': self.a.search('work', '')}
        with patch.object(sync, 'MAX_FILE_BYTES', 100), self.assertRaises(sync.SyncError):
            sync.validate_snapshot(good)

    def test_authenticated_malformed_payloads_rejected_without_changes(self):
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
        from cryptography.hazmat.primitives import hashes
        salt, nonce = os.urandom(16), os.urandom(12)
        key = PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=salt,
                         iterations=600000).derive(self.password.encode())
        prefix = sync.HEADER + salt + nonce
        payloads = [b'{"version":1,"version":1,"records":[]}',
                    b'{"version":true,"records":[]}', b'[]', b'not JSON',
                    b'{"version":1,"records":[],"tasks":[]}']
        for raw in payloads:
            self.path.write_bytes(prefix + AESGCM(key).encrypt(nonce, raw, prefix))
            with self.subTest(raw=raw), self.assertRaises(sync.SyncError):
                sync.import_snapshot(self.b, self.path, self.password)
        self.assertEqual(self.b.db.execute('SELECT count(*) FROM memories').fetchone()[0], 0)

    def test_import_rolls_back_all_inserts_on_db_failure(self):
        # Force an insertion before the failing row, independently of random UUIDs.
        with self.a.db:
            self.a.db.execute("UPDATE memories SET id='a-first' WHERE project='private'")
            self.a.db.execute("UPDATE memories SET id='z-failure' WHERE project='work'")
        sync.export_snapshot(self.a, self.path, self.password, all_projects=True)
        self.b.db.execute("CREATE TRIGGER fail_import BEFORE INSERT ON memories WHEN NEW.project='work' BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            sync.import_snapshot(self.b, self.path, self.password)
        self.assertEqual(self.b.db.execute('SELECT count(*) FROM memories').fetchone()[0], 0)

    def test_symlink_input_rejected(self):
        self.export()
        link = Path(self.tmp.name) / 'link'
        link.symlink_to(self.path)
        with self.assertRaises((sync.SyncError, OSError)):
            sync.import_snapshot(self.b, link, self.password)


if __name__ == '__main__':
    unittest.main()
