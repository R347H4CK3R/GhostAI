"""Synthetic note-v2 contract tests, not native-produced interoperability evidence."""
from dataclasses import FrozenInstanceError, fields, replace
import copy
import importlib
import itertools
import math
import random
import struct
import unittest
import uuid

try:
    v2 = importlib.import_module('companion.immutable_note_state_v2')
except ModuleNotFoundError:
    v2 = None


def bits(value):
    return struct.unpack('>Q', struct.pack('>d', value))[0]


def identifier(n):
    return str(uuid.UUID(int=n))


class ImmutableNoteTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(v2, 'Unused immutable-note v2 reference is not implemented')
        self.engine = v2.ImmutableNoteEngine()

    def payload(self, text='Synthetic', project='General', source='Synthetic source', raw=None):
        return v2.NotePayload(project, text, source, bits(100.0) if raw is None else raw)

    def record(self, n=1, payload=None):
        return v2.NoteRecord(identifier(n), self.payload() if payload is None else payload)

    def binding(self, n=1, payload=None, engine=None):
        engine = self.engine if engine is None else engine
        return v2.NoteBinding(identifier(n), engine.content_key(self.payload() if payload is None else payload))

    def state(self, records=(), bindings=(), tombstones=(), **kw):
        return v2.ImmutableNoteStateV2(records=records, bindings=bindings, tombstones=tombstones, **kw)

    def assert_code(self, code, fn, detail=None):
        with self.assertRaises(v2.NoteStateError) as caught:
            fn()
        self.assertEqual(caught.exception.code, code)
        if detail is not None:
            self.assertEqual(caught.exception.detail, detail)

    # An incorrect domain, tag, endian, byte length, or date bit conversion fails.
    def test_literal_tagged_tlv_and_sha256_vector(self):
        payload = self.payload('Cafe\u0301\0x', source='Synthetic', raw=0x8000000000000000)
        self.assertEqual(self.engine.content_bytes(payload).hex(),
            '566579726120696d6d757461626c65206e6f7465207061796c6f616420763200'
            '01000000000000000747656e6572616c02000000000000000843616665cc810078'
            '03000000000000000953796e7468657469630400000000000000088000000000000000')
        self.assertEqual(self.engine.content_key(payload).hex(),
            '639fd58b2260f5bf100bf2c6503065b736f7cd85529101eaf807bcd34ddaf39c')
        self.assertNotEqual(self.engine.content_key(self.payload('ab', source='c')),
                            self.engine.content_key(self.payload('a', source='bc')))

    def test_additional_literal_unicode_and_date_hash_vectors(self):
        vectors = [
            ('General', 'Synthetic', 'Synthetic source', 0x4059000000000000, 'f9892db68364b586d3cb431d4aaf2bf824ebdee4a81e2f6f9fcbc75ba99ea302'),
            ('Café', 'e\u0301', '源😀', 0, 'c8fe0455a092c789b89d6c3bf831282bc31799f43a3721a2536395ccb97ce1b1'),
            ('Cafe\u0301', 'é', '源😀', 0x8000000000000000, '6fa9389608e26c14b761e3ad5de04b05557bd8a2e93469d356351b65c20735f7'),
            ('😀', '\0\r\n', '', 1, '4553dbbdb8ce38a7e6329f4cbd3497d21321e8ca137afbc639b36986f843f08c'),
            ('General', 'X', 's', 0x41c5821440000001, '87c6ea73739eccb9e034911aa914d613731a1cabc9105e0c71fdcdb084ee18c5'),
        ]
        for project, text, source, raw, expected in vectors:
            with self.subTest(raw=raw, text=text):
                self.assertEqual(self.engine.content_key(v2.NotePayload(project, text, source, raw)).hex(), expected)

    def test_every_payload_field_is_exact_and_same_id_changes_conflict(self):
        base = self.payload(' X\r\n', project=' General ', source=' user source ')
        for name in ('project', 'text', 'source'):
            for value in ('Café', 'Cafe\u0301', '', 'x\0y', '😀'):
                if name == 'project' and value == '':
                    continue
                changed = replace(base, **{name: value})
                a, b = self.state((self.record(payload=base),)), self.state((self.record(payload=changed),))
                before = copy.deepcopy((a, b))
                for pair in ((a, b), (b, a)):
                    self.assert_code('immutable_conflict', lambda: self.engine.join(pair), identifier(1))
                self.assertEqual((a, b), before)
                self.assertEqual(self.engine.normalize(b).state.records[0].payload, changed)
        for name in ('project', 'text', 'source'):
            a = replace(base, **{name: 'Café'})
            b = replace(base, **{name: 'Cafe\u0301'})
            self.assertNotEqual(self.engine.content_key(a), self.engine.content_key(b))

    def test_date_bits_are_preserved_and_never_minimized(self):
        values = [0.0, -0.0, math.ulp(0.0), -math.ulp(0.0), 100.0,
                  math.nextafter(100.0, math.inf), 721692800.0000001,
                  -978307200.0, 252423993599.0]
        keys = set()
        for value in values:
            payload = self.payload(raw=bits(value))
            output = self.engine.normalize(self.state((self.record(payload=payload),)))
            self.assertEqual(output.state.records[0].payload.saved_at_bits, bits(value))
            keys.add(self.engine.content_key(payload))
        self.assertEqual(len(keys), len(values))
        for a, b in [(0.0, -0.0), (100.0, math.nextafter(100.0, math.inf))]:
            self.assert_code('immutable_conflict', lambda: self.engine.join((
                self.state((self.record(payload=self.payload(raw=bits(a))),)),
                self.state((self.record(payload=self.payload(raw=bits(b))),)))))

    def test_invalid_dates_and_strict_uint64_fail_even_when_hidden(self):
        bads = [True, False, None, 1.0, b'\0' * 8, -1, 2**64, '0',
                bits(math.inf), bits(-math.inf), bits(math.nan),
                bits(math.nextafter(-978307200.0, -math.inf)),
                bits(math.nextafter(252423993599.0, math.inf))]
        for raw in bads:
            with self.subTest(raw=raw):
                payload = replace(self.payload(), saved_at_bits=raw)
                state = self.state((self.record(payload=payload),), tombstones=(identifier(1),))
                self.assert_code('invalid_date', lambda: self.engine.normalize(state))

    def test_payload_types_and_invalid_utf8_are_rejected(self):
        class StringSubclass(str):
            pass
        for name in ('project', 'text', 'source'):
            for value in [None, True, 1, b'x', StringSubclass('x')]:
                with self.subTest(name=name, value=value):
                    self.assert_code('invalid_payload', lambda: self.engine.content_key(replace(self.payload(), **{name: value})))
            for value in ['\ud800', '\udfff', '\ud83d\ude00']:
                self.assert_code('invalid_utf8', lambda: self.engine.content_key(replace(self.payload(), **{name: value})))
        for value in [None, {}, ('General', 'x', '', 0)]:
            self.assert_code('invalid_payload', lambda: self.engine.content_key(value))

    def test_ascii_character_ceilings_and_crlf_graphemes(self):
        for name, cap in [('project', 300), ('text', 20000), ('source', 2000)]:
            payload = replace(self.payload(), **{name: 'x' * cap})
            self.assertEqual(len(self.engine.content_key(payload)), 32)
            self.assert_code('invalid_payload', lambda: self.engine.content_key(replace(payload, **{name: 'x' * (cap + 1)})))
            # Swift treats CRLF as one grapheme, including ASCII-only input.
            self.assertEqual(len(self.engine.content_key(replace(payload, **{name: '\r\n' * cap}))), 32)
        self.assert_code('invalid_payload', lambda: self.engine.content_key(self.payload(project='')))

    def test_unicode_compatibility_gate_never_calls_scalar_length_grapheme_count(self):
        # Short composed/decomposed/ZWJ/regional/Indic sequences are preserved.
        for text in ['e\u0301', '👩\u200d💻', '🇳🇿', 'क्\u200dष']:
            payload = self.payload(text)
            self.assertEqual(self.engine.normalize(self.state((self.record(payload=payload),))).state.records[0].payload, payload)
        # A scalar upper bound proves these at most 300 Swift graphemes.
        self.assertEqual(len(self.engine.content_key(self.payload(project='😀' * 300))), 32)
        # This valid Swift-sized field needs actual segmentation. Fail explicitly,
        # not invalid_payload, truncation, normalization, or Python-len parity.
        self.assert_code('unsupported_grapheme_boundary', lambda: self.engine.content_key(self.payload(project='e\u0301' * 300)), 'project')
        self.assert_code('unsupported_grapheme_boundary', lambda: self.engine.content_key(self.payload(source='👩\u200d💻' * 2000)), 'source')

    def test_uuid_types_and_canonical_text_are_strict(self):
        for bad in [None, True, 1, uuid.UUID(int=1), 'x', identifier(1).replace('-', ''),
                    '{' + identifier(1) + '}', ' ' + identifier(1),
                    'abcdef01-2345-4abc-8def-0123456789ab'.upper()]:
            for state in [self.state((v2.NoteRecord(bad, self.payload()),)),
                          self.state(bindings=(v2.NoteBinding(bad, b'x' * 32),), tombstones=(identifier(1),)),
                          self.state(tombstones=(bad,))]:
                self.assert_code('invalid_uuid', lambda: self.engine.normalize(state))

    def test_all_independent_legacy_ids_survive_without_dedup_or_rekey(self):
        ids = ['abcdef01-2345-4abc-8def-0123456789ab', 'b1fbeefd-3dd1-5f9a-b0a9-103d1e093175',
               'deafbeef-0000-5000-8000-000000000000', 'ffffffff-ffff-ffff-ffff-ffffffffffff', identifier(0)]
        records = tuple(v2.NoteRecord(id_, self.payload()) for id_ in reversed(ids))
        result = self.engine.normalize(self.state(records)).state
        self.assertEqual(tuple(r.id for r in result.records), tuple(sorted(ids, key=lambda x: uuid.UUID(x).bytes)))
        self.assertEqual(tuple(b.id for b in result.bindings), tuple(r.id for r in result.records))
        self.assertEqual({b.content_key for b in result.bindings}, {self.engine.content_key(self.payload())})
        result = self.engine.join((result, self.state(tombstones=(ids[0],)))).state
        self.assertEqual({r.id for r in result.records}, set(ids) - {ids[0]})
        self.assertEqual({b.id for b in result.bindings}, set(ids))

    def test_compatible_join_aci_permutations_and_empty_identity(self):
        a = self.state((self.record(3), self.record(1)))
        b = self.state((self.record(1), self.record(2, self.payload('Other'))))
        c = self.state(tombstones=(identifier(3), identifier(4)))
        expected = self.state((self.record(1), self.record(2, self.payload('Other'))),
                              (self.binding(1), self.binding(2, self.payload('Other')), self.binding(3)),
                              (identifier(3), identifier(4)))
        for x, y, z in itertools.permutations((a, b, c)):
            self.assertEqual(self.engine.join((x, y, z)).state, expected)
            self.assertEqual(self.engine.join((self.engine.join((x, y)).state, z)).state, expected)
            self.assertEqual(self.engine.join((x, self.engine.join((y, z)).state)).state, expected)
        normalized = self.engine.normalize(expected)
        self.assertEqual(self.engine.join((expected, expected)), normalized)
        self.assertEqual(self.engine.join((expected, self.state())), normalized)
        self.assertEqual(self.engine.join(()).state, self.state())

    def test_seeded_compatible_partitions_have_same_normalized_union(self):
        rng = random.Random(8729)
        for _ in range(12):
            states = []
            for _ in range(3):
                records = tuple(self.record(n, self.payload('value' + str(n))) for n in range(25) if rng.randrange(3))
                tombstones = tuple(identifier(n) for n in range(30) if rng.randrange(4) == 0)
                states.append(self.state(records, tombstones=tombstones))
            expected = self.engine.join(tuple(states))
            for x, y, z in itertools.permutations(states):
                self.assertEqual(self.engine.join((x, y, z)), expected)
                self.assertEqual(self.engine.join((self.engine.join((x, y)).state, z)), expected)

    def test_deletion_retains_binding_and_conflicts_in_every_grouping(self):
        a = self.state((self.record(),))
        b = self.state(tombstones=(identifier(1),))
        c = self.state((self.record(payload=self.payload('Changed')),))
        deleted = self.engine.join((a, b)).state
        self.assertEqual(deleted, self.state(bindings=(self.binding(),), tombstones=(identifier(1),)))
        self.assertEqual(self.engine.join((deleted, a, b)).state, deleted)
        for x, y, z in itertools.permutations((a, b, c)):
            self.assert_code('immutable_conflict', lambda: self.engine.join((x, y, z)), identifier(1))
            self.assert_code('immutable_conflict', lambda: self.engine.join((self.engine.join((x, y)).state, z)), identifier(1))
            self.assert_code('immutable_conflict', lambda: self.engine.join((x, self.engine.join((y, z)).state)), identifier(1))

    def test_known_deleted_bindings_conflict_without_any_remaining_body(self):
        a = self.state(bindings=(self.binding(),), tombstones=(identifier(1),))
        b = self.state(bindings=(self.binding(payload=self.payload('Changed')),), tombstones=(identifier(1),))
        for pair in ((a, b), (b, a)):
            self.assert_code('immutable_conflict', lambda: self.engine.join(pair), identifier(1))

    def test_opaque_tombstone_does_not_invent_or_erase_known_binding(self):
        opaque = self.state(tombstones=(identifier(1),))
        self.assertEqual(self.engine.normalize(opaque).state, opaque)
        for candidate in (self.payload(), self.payload('Unknown old history')):
            for pair in ((opaque, self.state((self.record(payload=candidate),))), (self.state((self.record(payload=candidate),)), opaque)):
                observed = self.engine.join(pair).state
                self.assertEqual(observed, self.state(bindings=(self.binding(payload=candidate),), tombstones=(identifier(1),)))
                self.assertEqual(self.engine.join((opaque, observed)).state, observed)
                self.assert_code('immutable_conflict', lambda: self.engine.join((observed, self.state((self.record(payload=self.payload('different')),)))))

    def test_hidden_originals_cannot_conceal_conflict_or_binding_mismatch(self):
        hidden = self.state((self.record(),), tombstones=(identifier(1),))
        changed = self.state((self.record(payload=self.payload('Changed')),))
        self.assert_code('immutable_conflict', lambda: self.engine.join((hidden, changed)))
        mismatch = replace(hidden, bindings=(self.binding(payload=self.payload('Changed')),))
        self.assert_code('immutable_conflict', lambda: self.engine.normalize(mismatch))

    def test_duplicate_facts_and_orphan_bindings_are_typed_failures(self):
        for records in [(self.record(), self.record()), (self.record(), self.record(payload=self.payload('Changed')))]:
            self.assert_code('duplicate_record', lambda: self.engine.normalize(self.state(records, tombstones=(identifier(1),))), identifier(1))
        self.assert_code('duplicate_binding', lambda: self.engine.normalize(self.state(bindings=(self.binding(), self.binding()), tombstones=(identifier(1),))))
        self.assert_code('duplicate_tombstone', lambda: self.engine.normalize(self.state(tombstones=(identifier(1), identifier(1)))))
        self.assert_code('orphan_binding', lambda: self.engine.normalize(self.state(bindings=(self.binding(),))), identifier(1))

    def test_metadata_state_and_collections_are_strict(self):
        for name in ('format', 'identity_scheme'):
            for bad in [None, True, 1, '', 'future', b'veyra-immutable-notes-v2']:
                self.assert_code('invalid_metadata', lambda: self.engine.normalize(replace(self.state(), **{name: bad})))
        for bad in [None, {}, (), True]:
            self.assert_code('invalid_state', lambda: self.engine.normalize(bad))
        for name in ('records', 'bindings', 'tombstones'):
            for bad in [None, [], {}, set(), iter(())]:
                self.assert_code('invalid_collection', lambda: self.engine.normalize(replace(self.state(), **{name: bad})))
        self.assert_code('invalid_record', lambda: self.engine.normalize(self.state(records=(None,))))
        self.assert_code('invalid_binding', lambda: self.engine.normalize(self.state(bindings=(None,))))
        for bad in [None, [], {}, self.state()]:
            self.assert_code('invalid_collection', lambda: self.engine.join(bad))

    def test_strict_binding_keys_and_hash_result(self):
        for bad in [None, True, 32, '', '00' * 32, b'x' * 31, b'x' * 33, bytearray(32)]:
            self.assert_code('invalid_key', lambda: self.engine.normalize(self.state(bindings=(v2.NoteBinding(identifier(1), bad),), tombstones=(identifier(1),))))
            engine = v2.ImmutableNoteEngine(digest=lambda _: bad)
            self.assert_code('invalid_hash_length', lambda: engine.normalize(self.state((self.record(),))))

    def test_digest_collision_is_rejected_before_any_suppression(self):
        engine = v2.ImmutableNoteEngine(digest=lambda _: b'*' * 32)
        a = self.state((self.record(),))
        b = self.state((self.record(2, self.payload('Other')),), tombstones=(identifier(2),))
        for pair in ((a, b), (b, a)):
            self.assert_code('content_collision', lambda: engine.join(pair), b'*' * 32)
        self.assert_code('content_collision', lambda: engine.normalize(self.state(a.records + b.records, tombstones=(identifier(1), identifier(2)))))
        self.assert_code('immutable_conflict', lambda: engine.join((a, self.state((self.record(payload=self.payload('Other')),)))))
        # Two different IDs with exactly identical content are not a collision.
        self.assertEqual(len(engine.normalize(self.state((self.record(), self.record(2)))).state.records), 2)

    def test_collision_detection_does_not_claim_erased_body_recovery(self):
        engine = v2.ImmutableNoteEngine(digest=lambda _: b'*' * 32)
        deleted = engine.normalize(self.state((self.record(),), tombstones=(identifier(1),))).state
        # A hash alone cannot prove unequal payloads after the old body is gone.
        result = engine.join((deleted, self.state((self.record(2, self.payload('Other')),)))).state
        self.assertEqual(result.records, (self.record(2, self.payload('Other')),))
        self.assertEqual(result.tombstones, (identifier(1),))

    def test_original_and_merged_note_caps_do_not_truncate(self):
        engine = v2.ImmutableNoteEngine(limits=v2.Limits(maximum_notes=1))
        a, b = self.state((self.record(),)), self.state((self.record(2),))
        before = copy.deepcopy((a, b))
        self.assert_code('capacity_notes', lambda: engine.join((a, b)))
        self.assertEqual((a, b), before)
        hidden = self.state(a.records + b.records, tombstones=(identifier(1), identifier(2)))
        self.assert_code('capacity_notes', lambda: engine.normalize(hidden))
        self.assertEqual(engine.join((a, b, self.state(tombstones=hidden.tombstones))).state.records, ())

    def test_shared_record_and_tombstone_reservations(self):
        engine = v2.ImmutableNoteEngine(limits=v2.Limits(other_records=29999, other_tombstones=19999))
        live = self.state((self.record(),))
        self.assertEqual(engine.normalize(live).usage.total_records, 30000)
        self.assert_code('capacity_records', lambda: engine.join((live, self.state((self.record(2),)))))
        known = self.state(bindings=(self.binding(),), tombstones=(identifier(1),))
        opaque = self.state(tombstones=(identifier(1),))
        self.assertEqual(engine.join((known, opaque)).usage.total_tombstones, 20000)
        self.assert_code('capacity_tombstones', lambda: engine.join((known, self.state(tombstones=(identifier(2),)))))

    def test_exact_conservative_reservation_includes_utf8_bindings_and_markers(self):
        payload = self.payload('\0\n"\\😀')
        result = self.engine.normalize(self.state((self.record(payload=payload),), tombstones=(identifier(2),)))
        expected = 512 + 256 + 160 + 128 + 6 * sum(len(x.encode('utf8')) for x in (payload.project, payload.text, payload.source))
        self.assertEqual(result.usage, v2.Usage(1, 1, 1, 1, expected, 2 * expected, expected, 2 * expected))
        for name, maximum, amount, code in [
            ('other_document_bytes', 8 * 1024 * 1024, expected, 'capacity_document_bytes'),
            ('other_journal_bytes', 17 * 1024 * 1024, 2 * expected, 'capacity_journal_bytes'),
        ]:
            limits = replace(v2.Limits(), **{name: maximum - amount})
            measured = v2.ImmutableNoteEngine(limits=limits).normalize(result.state).usage
            self.assertEqual(getattr(measured, 'total_' + name.removeprefix('other_').replace('_bytes', '_reservation_bytes')), maximum)
            self.assert_code(code, lambda: v2.ImmutableNoteEngine(limits=replace(limits, **{name: maximum - amount + 1})).normalize(result.state))

    def test_hidden_body_cannot_bypass_original_byte_budget(self):
        engine = v2.ImmutableNoteEngine(limits=v2.Limits(maximum_document_bytes=512))
        state = self.state((self.record(),), tombstones=(identifier(1),))
        self.assert_code('capacity_document_bytes', lambda: engine.normalize(state))
        self.assertEqual(state.records, (self.record(),))

    def test_default_ten_thousand_notes_and_twenty_thousand_markers(self):
        full = self.state(tuple(self.record(n) for n in range(10000)))
        self.assertEqual(self.engine.normalize(full).usage.notes, 10000)
        self.assert_code('capacity_notes', lambda: self.engine.join((full, self.state((self.record(10000),)))))
        markers = self.state(tombstones=tuple(identifier(n) for n in range(20000)))
        self.assertEqual(self.engine.normalize(markers).usage.total_tombstones, 20000)
        self.assert_code('capacity_tombstones', lambda: self.engine.join((markers, self.state(tombstones=(identifier(20000),)))))
        self.assertEqual(len(full.records), 10000)
        self.assertEqual(len(markers.tombstones), 20000)

    def test_retained_bindings_remain_budgeted_after_body_deletion(self):
        # 30k bindings is only a count upper bound, not a promise they fit 8 MiB.
        # 6k minimal live records plus 20k known tombstones fit both byte budgets.
        payload = self.payload('', project='x', source='', raw=0)
        key = self.engine.content_key(payload)
        state = self.state(tuple(self.record(n, payload) for n in range(6000)),
                           tuple(v2.NoteBinding(identifier(n), key) for n in range(6000, 26000)),
                           tuple(identifier(n) for n in range(6000, 26000)))
        result = self.engine.normalize(state)
        self.assertEqual(result.usage.retained_bindings, 26000)
        self.assertEqual(result.usage.notes, 6000)
        self.assertEqual(result.usage.total_tombstones, 20000)

    def test_limits_are_strict_bounded_and_arithmetic_is_signed_64_bit(self):
        for field in fields(v2.Limits):
            for bad in [True, False, -1, 1.0, None, 2**63]:
                limits = replace(v2.Limits(), **{field.name: bad})
                self.assert_code('invalid_limits', lambda: v2.ImmutableNoteEngine(limits=limits).normalize(self.state()))
        for name, maximum in [('maximum_notes', 10000), ('maximum_records', 30000), ('maximum_tombstones', 20000),
                              ('maximum_document_bytes', 8 * 1024 * 1024), ('maximum_journal_bytes', 17 * 1024 * 1024)]:
            self.assert_code('invalid_limits', lambda: v2.ImmutableNoteEngine(limits=replace(v2.Limits(), **{name: maximum + 1})).normalize(self.state()))
        for name in ('other_document_bytes', 'other_journal_bytes'):
            self.assert_code('capacity_arithmetic', lambda: v2.ImmutableNoteEngine(limits=replace(v2.Limits(), **{name: 2**63 - 1})).normalize(self.state()))
        for name in ('other_records', 'other_tombstones'):
            state = self.state((self.record(),), tombstones=(identifier(2),))
            self.assert_code('capacity_arithmetic', lambda: v2.ImmutableNoteEngine(limits=replace(v2.Limits(), **{name: 2**63 - 1})).normalize(state))
        for bad in [None, {}, True]:
            self.assert_code('invalid_limits', lambda: v2.ImmutableNoteEngine(limits=bad).normalize(self.state()))

    def test_values_are_frozen_and_success_never_mutates_inputs(self):
        source = self.state((self.record(2), self.record()), tombstones=(identifier(2),))
        before = copy.deepcopy(source)
        result = self.engine.normalize(source)
        self.assertEqual(source, before)
        self.assertIsNot(source, result.state)
        for obj, name, value in [(source, 'records', ()), (source.records[0], 'id', identifier(9)),
                                 (source.records[0].payload, 'source', 'other'), (self.binding(), 'content_key', b'0'*32),
                                 (v2.Limits(), 'maximum_notes', 1), (result, 'state', source), (result.usage, 'notes', 2)]:
            with self.assertRaises(FrozenInstanceError):
                setattr(obj, name, value)


if __name__ == '__main__':
    unittest.main()
