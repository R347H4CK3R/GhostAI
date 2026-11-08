"""Pure v1 building blocks, not evidence that cross-device writers are ready."""
import base64
import importlib.util
import json
import math
from pathlib import Path
import unittest
from unittest.mock import patch

from companion import private_sync_codec as codec

FIXTURES = Path(__file__).resolve().parents[2] / 'Tests' / 'Fixtures'


class DateTests(unittest.TestCase):
    def test_import_preserves_binary64_without_unix_round_trip(self):
        date = codec.ReferenceDate.from_json(721692800.0000001)
        self.assertEqual(date.bits_hex, '41c5821440000001')
        self.assertEqual(date.reference_seconds, 721692800.0000001)
        self.assertNotEqual(date.reference_seconds, date.unix_seconds - 978307200)
        self.assertEqual(codec.ReferenceDate.from_bits(date.bits_hex), date)

    def test_negative_zero_subnormals_and_pre_2001_seconds_remain_exact(self):
        for value in [-0.0, 0.0, -0.5, -978307200.0, 252423993599.0,
                      math.nextafter(0.0, 1.0), math.nextafter(0.0, -1.0)]:
            with self.subTest(value=value):
                date = codec.ReferenceDate.from_json(value)
                self.assertEqual(codec.ReferenceDate.from_bits(date.bits_hex).bits_hex, date.bits_hex)
        self.assertEqual(codec.ReferenceDate.from_json(-0.0).bits_hex, '8000000000000000')
        self.assertEqual(codec.ReferenceDate.from_json(-0.5).unix_seconds, 978307199.5)

    def test_invalid_dates_are_not_coerced_into_valid_numbers(self):
        for value in [True, False, None, '0', [], float('inf'), float('nan'),
                      -978307201, 252423993600, 10 ** 500]:
            with self.subTest(type=type(value)):
                with self.assertRaises(ValueError):
                    codec.ReferenceDate.from_json(value)
        for value in ['', '0', 'z' * 16, '7ff0000000000000', 'FFF0000000000000']:
            with self.assertRaises(ValueError):
                codec.ReferenceDate.from_bits(value)


class IdentityTests(unittest.TestCase):
    original = 'AbCdEf01-2345-4aBc-8dEf-0123456789aB'

    def test_uuid_case_is_domain_specific_and_format_is_strict(self):
        self.assertEqual(codec.record_uuid(self.original), 'ABCDEF01-2345-4ABC-8DEF-0123456789AB')
        self.assertEqual(codec.tombstone('note', self.original), 'note:abcdef01-2345-4abc-8def-0123456789ab')
        for value in [self.original.replace('-', ''), '{' + self.original + '}', ' ' + self.original, None]:
            with self.assertRaises(ValueError):
                codec.record_uuid(value)
        with self.assertRaises(ValueError):
            codec.tombstone('knowledge', self.original)

    def test_conflicts_hash_exact_bytes_and_lowercase_domain(self):
        # Independent SHA-256 algorithm vector, NOT a purported Foundation record.
        self.assertEqual(codec.conflict_id('note', self.original, b'abc'),
                         '360dca41-4f0e-52e2-ac45-74f016ee5258')
        self.assertEqual(codec.conflict_id('note', self.original.lower(), b'abc'),
                         codec.conflict_id('note', self.original, b'abc'))
        self.assertNotEqual(codec.conflict_id('note', self.original, 'é'.encode()),
                            codec.conflict_id('note', self.original, 'e\u0301'.encode()))
        with self.assertRaises(ValueError):
            codec.conflict_id('note', self.original, 'abc')

    def test_restoration_preserves_markers_and_advances_until_live(self):
        original = '12345678-1234-4234-8234-123456789012'
        first = 'a9a06aa9-f85a-8bc8-a1c3-d5041d4c6d19'
        second = 'a38206d4-4d51-8fc4-b995-a858c259a973'
        markers = {'note:' + original, 'note:' + first}
        self.assertEqual(codec.restored_id('note', original, markers), second)
        self.assertEqual(len(markers), 2)
        self.assertEqual(codec.restored_id('chat', original, {'chat:' + original}),
                         '48b5ccb6-18a3-8d9e-9530-565f84c4fd70')
        self.assertEqual(codec.restored_id('note', original, []), original)

    def test_invalid_or_noncanonical_markers_fail_closed(self):
        for markers in [['note:' + self.original], ['unknown:' + self.original.lower()],
                        ['note:' + self.original.lower()] * 2, ['bad'] * 20001]:
            with self.assertRaises(ValueError):
                codec.restored_id('note', self.original, markers)


class JSONBoundaryTests(unittest.TestCase):
    def test_strict_json_rejects_ambiguous_or_resource_exhausting_inputs(self):
        for raw in [b'{"a":1,"a":2}', b'{"a":NaN}', b'{"a":1e999}', b'{"a":"\\ud800"}',
                    b'[' * 65 + b'0' + b']' * 65, b'\xff', b'{']:
            with self.subTest(raw=raw[:30]):
                with self.assertRaises(ValueError):
                    codec.strict_json(raw)
        self.assertEqual(codec.strict_json(b'{"text":"[\\\"\\ud83d\\ude00]"}'), {'text': '["😀]'})

    def test_json_negative_integer_zero_retains_sign(self):
        self.assertEqual(codec.ReferenceDate.from_json(codec.strict_json(b'{"date":-0}')['date']).bits_hex,
                         '8000000000000000')


@unittest.skipUnless(importlib.util.find_spec('cryptography'), 'optional sync cryptography is not installed')
class EnvelopeTests(unittest.TestCase):
    def test_existing_independent_envelope_remains_readable(self):
        fixture = json.loads((FIXTURES / 'private-memory-sync-v1.json').read_text())
        raw = codec.decrypt_remote_payload(base64.b64decode(fixture['encryptedBase64']), fixture['passphrase'])
        self.assertEqual(json.loads(raw), fixture['document'])

    def test_authentication_covers_header_nonce_ciphertext_and_tag(self):
        fixture = json.loads((FIXTURES / 'private-memory-sync-v1.json').read_text())
        encrypted = base64.b64decode(fixture['encryptedBase64'])
        for index in [0, 13, 14, 30, 42, len(encrypted) - 1]:
            changed = bytearray(encrypted); changed[index] ^= 1
            with self.assertRaises(ValueError):
                codec.decrypt_remote_payload(bytes(changed), fixture['passphrase'])
        with self.assertRaises(ValueError):
            codec.decrypt_remote_payload(encrypted, 'wrong')

    def test_passphrase_unicode_whitespace_and_size_are_byte_preserving(self):
        self.assertEqual(codec.passphrase_utf8('  e\u0301😀  '), b'  e\xcc\x81\xf0\x9f\x98\x80  ')
        self.assertNotEqual(codec.passphrase_utf8('é'), codec.passphrase_utf8('e\u0301'))
        for value in ['', 'é' * 2049, '\ud800', None]:
            with self.assertRaises(ValueError):
                codec.passphrase_utf8(value)

    def test_remote_envelope_size_is_rejected_before_crypto_import(self):
        for value in [b'', codec.HEADER + b'x' * (codec.MAXIMUM_DOCUMENT_BYTES + 45)]:
            with self.assertRaises(ValueError):
                with patch('hashlib.pbkdf2_hmac', side_effect=AssertionError('KDF ran before size check')):
                    codec.decrypt_remote_payload(value, 'synthetic')


if __name__ == '__main__':
    unittest.main()
