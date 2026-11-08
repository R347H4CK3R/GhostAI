"""Independent wire-format checks, not a claim of desktop automatic sync."""
import base64
import json
import pathlib
import unittest

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:
    AESGCM = None

from scripts import private_memory_sync_reference as sync


@unittest.skipUnless(AESGCM, "Install companion/requirements-sync.txt for crypto verification")
class PrivateMemorySyncReferenceTests(unittest.TestCase):
    def test_fixture_decrypts_and_matches_declared_document(self):
        fixture = json.loads((pathlib.Path(__file__).parents[2] / "Tests/Fixtures/private-memory-sync-v1.json").read_text())
        data = base64.b64decode(fixture["encryptedBase64"], validate=True)
        self.assertEqual(sync.decrypt(data, fixture["passphrase"]), fixture["document"])

    def test_ciphertext_wrong_passphrase_and_tampering_reject(self):
        fixture = json.loads((pathlib.Path(__file__).parents[2] / "Tests/Fixtures/private-memory-sync-v1.json").read_text())
        data = base64.b64decode(fixture["encryptedBase64"], validate=True)
        with self.assertRaises(ValueError):
            sync.decrypt(data, "wrong passphrase")
        for position in (0, 13, 14, 30, 42, len(data) - 1):
            broken = bytearray(data)
            broken[position] ^= 1
            with self.subTest(position=position), self.assertRaises(ValueError):
                sync.decrypt(bytes(broken), fixture["passphrase"])

    def test_truncated_and_oversized_envelopes_reject_before_kdf(self):
        for value in (b"", b"x" * 57, b"x" * (sync.MAXIMUM_DOCUMENT_BYTES + 59)):
            with self.assertRaises(ValueError):
                sync.decrypt(value, "synthetic fixture passphrase")

    def test_repository_binding_and_tombstone_shape(self):
        good = dict(version=1, repositoryID=12345, notes=[], chats=[], knowledge=[], tombstones=[], includesPrivateWorkspaces=False, chatOrder=[])
        self.assertEqual(sync.validate_document(good, repository_id=12345), good)
        with self.assertRaises(ValueError):
            sync.validate_document(good, repository_id=999)
        bad = dict(good, tombstones=["note:not-a-uuid"])
        with self.assertRaises(ValueError):
            sync.validate_document(bad)


if __name__ == "__main__":
    unittest.main()
