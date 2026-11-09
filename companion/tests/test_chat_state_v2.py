"""Synthetic new-v2 math and chat laws; never purported Foundation/v1 goldens."""
from dataclasses import FrozenInstanceError, replace
import importlib
import itertools
import math
import random
import struct
import unittest
import uuid

try:
    v2 = importlib.import_module('companion.chat_state_v2')
except ModuleNotFoundError:
    v2 = None

ROOT = 'abcdef01-2345-4abc-8def-0123456789ab'
ORIGIN = '00000000-0000-4000-8000-000000000001'
BATCH = '00000000-0000-4000-8000-000000000002'


def bits(value):
    return struct.pack('>d', value)


class PrimitiveTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(v2, 'Unused v2 reference has not been implemented')

    def test_literal_tlv_sha256_and_network_uuid_vectors(self):
        payload = v2.ChatPayload('General', 'user', 'X')
        self.assertEqual(v2.content_bytes_v2(payload).hex(),
            '5665797261206368617420636f6e74656e7420763200000000000000000747656e6572616c'
            '000000000000000475736572000000000000000158')
        key = v2.content_key_v2(payload)
        self.assertEqual(key.hex(), '58b32ca7a34840dc3a7ef370534b1b810e1a6f4efd831a053c88218534a6c25f')
        self.assertEqual(v2.variant_id_v2(ROOT, key, key), ROOT)
        projected = v2.variant_id_v2(ROOT, b'\0' * 32, key)
        self.assertEqual(projected, 'cca7cac2-8201-8b3b-8033-078c6bea66a1')
        self.assertEqual(uuid.UUID(projected).version, 8)
        self.assertEqual(uuid.UUID(projected).variant, uuid.RFC_4122)
        vectors = [
            (('General', 'assistant', 'café'), 'c0bd1ba711785726140ddee8c7b4af34c8d0b4379ac08c2952ae2c600996bed4', 'f05d9b78-64a6-83ab-a1e8-5c0e0ef25bc1'),
            (('General', 'assistant', 'cafe\u0301'), '0a9f819d4fad98d8134e23f16f7ff61ebd0f79e9f9f401bc59491da268125e72', '92401135-eeab-8a56-8a2e-8f2ca559b2b0'),
            (('😀', 'user', '\0😀\n'), '8cba91f3e0fec54203843d059b1612c433b07ddaa385b3417ccd95ebdbb87beb', 'dce58054-07f4-8e60-9983-72dfe56518e1'),
        ]
        for fields, expected_key, expected_id in vectors:
            with self.subTest(fields=fields):
                key = v2.content_key_v2(v2.ChatPayload(*fields))
                self.assertEqual(key.hex(), expected_key)
                self.assertEqual(v2.variant_id_v2(ROOT, b'\0' * 32, key), expected_id)

    def test_raw_payload_fields_are_not_normalized_or_coerced(self):
        fields = [('a', 'user', 'bc'), ('ab', 'user', 'c'), ('a\0', 'user', 'b'),
                  ('a', 'assistant', 'bc'), ('é', 'user', 'X'), ('e\u0301', 'user', 'X'),
                  ('General', 'user', 'é'), ('General', 'user', 'e\u0301'),
                  (' General ', 'user', ' X\r\n'), ('General', 'user', 'X\n')]
        self.assertEqual(len({v2.content_key_v2(v2.ChatPayload(*f)) for f in fields}), len(fields))
        for field, bad in itertools.product(range(3), [None, True, 1, b'x', '\ud800']):
            values = ['General', 'user', 'X']; values[field] = bad
            with self.subTest(field=field, bad=repr(bad)), self.assertRaises(v2.ChatStateError):
                v2.content_key_v2(v2.ChatPayload(*values))
        for role in ['', 'User', 'system', ' user ']:
            with self.assertRaises(v2.ChatStateError):
                v2.content_key_v2(v2.ChatPayload('General', role, 'X'))
        self.assertEqual(len(v2.content_key_v2(v2.ChatPayload('', 'user', ''))), 32)

    def test_strict_keys_uuid_and_decimal_uint64_boundaries(self):
        for bad in [b'', b'x' * 31, b'x' * 33, '00' * 32, bytearray(32), None]:
            with self.assertRaises(v2.ChatStateError):
                v2.variant_id_v2(ROOT, b'x' * 32, bad)
        for bad in [None, True, ROOT.upper(), ROOT.replace('-', ''), '{' + ROOT + '}', ' ' + ROOT]:
            with self.assertRaises(v2.ChatStateError):
                v2.variant_id_v2(bad, b'x' * 32, b'x' * 32)
        for bad in [None, 0, True, '', '00', '+1', '-1', '1.0', '1e0', ' 1', '١', str(2**64)]:
            with self.assertRaises(v2.ChatStateError):
                v2.parse_counter_v2(bad)
        self.assertEqual(v2.parse_counter_v2('0'), 0)
        self.assertEqual(v2.parse_counter_v2(str(2**64 - 1)), 2**64 - 1)

    def test_binary64_minimum_preserves_supplied_bits(self):
        for value in [-978307200.0, 252423993599.0, -0.0, 0.0, -0.5,
                      math.ulp(0.0), -math.ulp(0.0), math.nextafter(1.0, 2.0)]:
            self.assertEqual(v2.date_min_bits(bits(value), bits(value)), bits(value))
        self.assertEqual(v2.date_min_bits(bits(-0.0), bits(0.0)), bits(0.0))
        self.assertEqual(v2.date_min_bits(bits(0.0), bits(-0.0)), bits(0.0))
        self.assertEqual(v2.date_min_bits(bits(-math.ulp(0.0)), bits(-0.0)), bits(-math.ulp(0.0)))
        self.assertEqual(v2.date_min_bits(bits(721692800.0000001), bits(721692800.0)), bits(721692800.0))
        for bad in [None, True, 0, b'0' * 7, b'0' * 9, bytearray(8), '0'*16,
                    bits(math.inf), bits(math.nan), bits(math.nextafter(-978307200., -math.inf)),
                    bits(math.nextafter(252423993599., math.inf))]:
            with self.assertRaises(v2.ChatStateError):
                v2.date_min_bits(bad, bits(0.0))

    def test_digest_boundary_rejects_non_sha256_shapes(self):
        for digest in [lambda _: b'x' * 31, lambda _: bytearray(32), lambda _: None]:
            engine = v2.ChatEngine(digest=digest)
            with self.assertRaises(v2.ChatStateError):
                engine.content_key(v2.ChatPayload('General', 'user', 'X'))

class ChatStateTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(hasattr(v2.ChatEngine, 'join'), 'The pure chat join is not implemented')
        self.engine = v2.ChatEngine()

    def payload(self, text='X', project='General', role='user'):
        return v2.ChatPayload(project, role, text)

    def variant(self, text='X', date=100., project='General', engine=None):
        engine = engine or self.engine
        payload = self.payload(text, project)
        return v2.ChatVariant(engine.content_key(payload), payload, bits(date))

    def order(self, sequence=0, counter=0, origin=ORIGIN, batch=BATCH):
        return v2.OrderKey(counter, origin, batch, sequence)

    def family(self, variants=None, *, root=ROOT, anchor='X', order=None, engine=None):
        engine = engine or self.engine
        return v2.ChatFamily(root, engine.content_key(self.payload(anchor)), order or self.order(),
                             (self.variant(engine=engine),) if variants is None else tuple(variants))

    def state(self, variants=None, **kw):
        return self.engine.validate(v2.ChatStateV2(families=(self.family(variants, **kw),)))

    def rows(self, state):
        return self.engine.project(state)

    def assert_code(self, code, fn):
        with self.assertRaises(v2.ChatStateError) as failure:
            fn()
        self.assertEqual(failure.exception.code, code)

    def assert_laws(self, states):
        expected = self.engine.join(self.engine.join(states[0], states[1]), states[2])
        for a, b, c in itertools.permutations(states):
            self.assertEqual(self.engine.join(self.engine.join(a, b), c), expected)
            self.assertEqual(self.engine.join(a, self.engine.join(b, c)), expected)
        self.assertEqual(self.engine.join(expected, expected), expected)
        self.assertEqual(self.engine.join(expected, self.engine.validate(v2.ChatStateV2())), expected)
        self.assertEqual(self.engine.validate(expected.state), expected)
        return expected

    def test_x100_x200_y150_every_permutation_and_grouping_keeps_two_ids(self):
        a = self.state([self.variant('X', 100)])
        b = self.state([self.variant('X', 200)])
        c = self.state([self.variant('X', 200), self.variant('Y', 150)])
        result = self.assert_laws([a, b, c])
        rows = self.rows(result)
        self.assertEqual([(r.payload.text, r.earliest_date_bits) for r in rows], [('X', bits(100)), ('Y', bits(150))])
        self.assertEqual(rows[0].reference.projected_id, ROOT)
        self.assertEqual(rows[1].reference.projected_id, self.rows(c)[1].reference.projected_id)
        restarted = self.engine.validate(self.engine.join(b, c).state)
        self.assertEqual(self.engine.join(restarted, a), result)
        # A reviewed Y anchor stays Y at the original root, even when X learns an earlier date.
        y = self.state([self.variant('Y', 150), self.variant('X', 200)], anchor='Y')
        y2 = self.engine.observe(y, ROOT, self.payload('X'), bits(100)).state
        self.assertEqual(self.rows(y2)[0].payload.text, 'Y')
        self.assertEqual(self.rows(y2)[1].reference, self.rows(y)[1].reference)

    def test_source_order_counterexample_never_recreates_order_edges(self):
        id0, id1 = str(uuid.UUID(int=0)), str(uuid.UUID(int=1))
        f0, f1 = self.family(root=id0, order=self.order(0)), self.family(root=id1, order=self.order(1))
        a = self.engine.validate(v2.ChatStateV2(families=(f0,)))
        b = self.engine.validate(v2.ChatStateV2(families=(f1,)))
        c = self.engine.validate(v2.ChatStateV2(families=(f1, f0)))
        result = self.assert_laws([a, b, c])
        self.assertEqual([r.reference.projected_id for r in self.rows(result)], [id0, id1])
        observed = self.engine.observe(c, id1, self.payload(), bits(1)).state
        self.assertEqual([r.reference.projected_id for r in self.rows(observed)], [id0, id1])

    def test_whole_order_minimum_and_clock_maximum(self):
        low = self.order(99, 1, BATCH, ORIGIN)
        high = self.order(0, 2, ORIGIN, BATCH)
        a, b = self.state(order=low), self.state(order=high)
        result = self.engine.join(a, b)
        self.assertEqual(result.state.families[0].order_key, low)
        self.assertEqual(result.state.order_clock, 2)
        b = self.engine.validate(replace(b.state, order_clock=7))
        result = self.engine.join(a, b)
        self.assertEqual(result.state.order_clock, 7)
        batch = self.engine.new_order_batch(result.state.order_clock, ORIGIN, BATCH, 2)
        self.assertEqual(batch, (self.order(0, 8), self.order(1, 8)))
        self.assert_code('capacity_order_clock', lambda: self.engine.new_order_batch(2**64-1, ORIGIN, BATCH, 1))
        for bad in [True, False, -1, 0, 1.0, None, 10001]:
            with self.assertRaises(v2.ChatStateError):
                self.engine.new_order_batch(0, ORIGIN, BATCH, bad)
        for bad in [True, -1, 2**64, 1.0]:
            with self.assertRaises(v2.ChatStateError):
                self.engine.new_order_batch(bad, ORIGIN, BATCH, 1)

    def test_raw_bytes_and_unrelated_legacy_roots_never_deduplicate(self):
        legacy = [ROOT, 'b1fbeefd-3dd1-5f9a-b0a9-103d1e093175', 'deafbeef-0000-5000-8000-000000000000']
        families = tuple(self.family(root=id_, order=self.order(i)) for i, id_ in enumerate(legacy))
        state = self.engine.validate(v2.ChatStateV2(families=tuple(reversed(families))))
        self.assertEqual([r.reference.projected_id for r in self.rows(state)], legacy)
        for payload in [self.payload('é'), self.payload('e\u0301'), self.payload('X', 'e\u0301'), self.payload('X', 'é')]:
            state = self.engine.observe(state, ROOT, payload, bits(100)).state
        self.assertEqual(len(self.rows(state)), 7)
        for row in self.rows(state):
            self.assertEqual(row.earliest_date_bits, bits(100))
        # Same exact text, other role or project still creates a sibling.
        state = self.engine.observe(state, ROOT, self.payload('X', role='assistant'), bits(100)).state
        self.assertEqual(len(self.rows(state)), 8)

    def test_date_only_observations_do_not_grow_state(self):
        initial = self.state([self.variant('X', -0.0)])
        self.assertEqual(self.rows(initial)[0].earliest_date_bits, bits(-0.0))
        changed = self.engine.observe(initial, ROOT, self.payload(), bits(0.0))
        self.assertEqual(changed.added_ids, frozenset())
        self.assertEqual(self.rows(changed.state)[0].earliest_date_bits, bits(0.0))
        for _ in range(10):
            changed = self.engine.observe(changed.state, ROOT, self.payload(), bits(200))
            self.assertEqual(changed.state.usage, initial.usage)
            self.assertEqual(len(changed.state.state.families[0].variants), 1)

    def test_selective_anchor_delete_preserves_sibling_without_promotion(self):
        original = self.state([self.variant(), self.variant('Y', 150)])
        anchor, sibling = [r.reference for r in self.rows(original)]
        result = self.engine.delete_variants(original, frozenset({anchor}))
        self.assertEqual([r.reference for r in self.rows(result.state)], [sibling])
        self.assertEqual(result.added_variant_deletes, frozenset({anchor}))
        self.assertEqual(result.added_tombstones, frozenset({ROOT}))
        self.assertEqual(result.added_family_deletes, frozenset())
        self.assertEqual(self.engine.join(result.state, original), result.state)
        for date in [1., 999.]:
            self.assertEqual(self.engine.observe(result.state, ROOT, self.payload(), bits(date)).state, result.state)
        self.assertEqual(self.engine.delete_variants(result.state, frozenset({anchor})).state, result.state)
        all_deleted = self.engine.delete_variants(result.state, frozenset({sibling})).state
        self.assertEqual(self.rows(all_deleted), ())
        self.assertEqual(len(all_deleted.state.families), 1)
        self.assertEqual(self.engine.join(all_deleted, original), all_deleted)

    def test_family_delete_fanout_captures_late_variants_and_legacy_marker(self):
        a = self.state()
        deleted = self.engine.delete_families(a, frozenset({ROOT})).state
        c = self.state([self.variant(), self.variant('Y', 150)])
        result = self.assert_laws([a, deleted, c])
        self.assertEqual(self.rows(result), ())
        self.assertEqual(len(result.state.variant_deletes), 2)
        self.assertEqual(len(result.state.chat_tombstones), 2)
        self.assertEqual(result.state.family_deletes, (ROOT,))
        late = self.engine.observe(result, ROOT, self.payload('Z'), bits(1))
        self.assertEqual(self.rows(late.state), ())
        self.assertEqual(len(late.added_variant_deletes), 1)
        self.assertEqual(len(late.added_tombstones), 1)
        self.assertEqual(late.added_ids, frozenset())
        legacy = self.engine.validate(v2.ChatStateV2(family_deletes=(ROOT,), chat_tombstones=(ROOT,)))
        self.assertEqual(self.engine.join(legacy, c), result)

    def test_empty_and_project_subset_are_not_implicit_deletion(self):
        before = self.state([self.variant(), self.variant('Y', project='Elsewhere')])
        self.assertEqual(self.engine.join(before, self.engine.validate(v2.ChatStateV2())), before)
        self.assertEqual(self.engine.delete_variants(before, frozenset()).state, before)
        chosen = frozenset(row.reference for row in self.rows(before) if row.payload.project == 'General')
        after = self.engine.delete_variants(before, chosen).state
        self.assertEqual([row.payload.project for row in self.rows(after)], ['Elsewhere'])
        fake = replace(self.rows(before)[0].reference, projected_id=ORIGIN)
        self.assert_code('unknown_reference', lambda: self.engine.delete_variants(before, frozenset({fake})))
        self.assert_code('unknown_family', lambda: self.engine.delete_families(before, frozenset({ORIGIN})))
        self.assert_code('unknown_family', lambda: self.engine.observe(before, ORIGIN, self.payload(), bits(0)))

    def test_input_and_output_are_immutable_and_conflicts_preserve_both(self):
        a, b = self.state(), self.state([self.variant('Y')], anchor='Y')
        before = (a, b)
        self.assert_code('anchor_conflict', lambda: self.engine.join(a, b))
        self.assert_code('anchor_conflict', lambda: self.engine.join(b, a))
        self.assertEqual((a, b), before)
        with self.assertRaises(FrozenInstanceError):
            a.state.order_clock = 8
        with self.assertRaises(TypeError):
            a.state.families[0] = b.state.families[0]

    def test_strict_metadata_missing_anchors_duplicates_and_markers(self):
        f = self.family(); row = self.rows(self.state())[0].reference
        valid = v2.ChatStateV2(families=(f,))
        malformed = [replace(valid, format='v1'), replace(valid, identity_scheme='future'),
                     replace(valid, order_clock=True), replace(valid, order_clock=1.0),
                     replace(valid, families=[f]), replace(valid, families=(f, f)),
                     replace(valid, families=(replace(f, variants=(f.variants[0], f.variants[0])),)),
                     replace(valid, families=(replace(f, variants=()),)),
                     replace(valid, families=(replace(f, order_key=replace(f.order_key, sequence=True)),)),
                     replace(valid, families=(replace(f, order_key=replace(f.order_key, counter=2**64)),)),
                     replace(valid, family_deletes=(ROOT,)),
                     replace(valid, chat_tombstones=(ROOT,)),
                     replace(valid, variant_deletes=(row,)),
                     replace(valid, variant_deletes=(row, row), chat_tombstones=(ROOT,)),
                     replace(valid, family_deletes=(ROOT, ROOT), chat_tombstones=(ROOT,)),
                     replace(valid, variant_deletes=(replace(row, family_id=ORIGIN),), chat_tombstones=(ROOT,)),
                     replace(valid, variant_deletes=(replace(row, projected_id=ORIGIN),), chat_tombstones=(ORIGIN,)),
                     replace(valid, chat_tombstones=('note:' + ROOT,)),
                     replace(valid, families=(replace(f, variants=(replace(f.variants[0], earliest_date_bits=True),)),))]
        for value in malformed:
            with self.subTest(value=value), self.assertRaises(v2.ChatStateError):
                self.engine.validate(value)
        # An explicitly selected anchor may be absent without deleting its siblings.
        selected = replace(valid, families=(replace(f, variants=()),), variant_deletes=(row,), chat_tombstones=(ROOT,))
        self.assertEqual(self.rows(self.engine.validate(selected)), ())

    def test_digest_collisions_fail_before_deletion_can_hide_them(self):
        constant = v2.ChatEngine(digest=lambda _: b'a' * 32)
        x, y = self.variant('X', engine=constant), self.variant('Y', engine=constant)
        a = constant.validate(v2.ChatStateV2(families=(self.family([x], engine=constant),)))
        b = constant.validate(v2.ChatStateV2(families=(self.family([y], engine=constant),)))
        before = (a, b)
        self.assert_code('content_collision', lambda: constant.join(a, b))
        self.assertEqual((a, b), before)
        f = self.family([x], engine=constant)
        g = self.family([y], root=ORIGIN, engine=constant)
        bad = v2.ChatStateV2(families=(f, g), family_deletes=(ROOT, ORIGIN), chat_tombstones=(ROOT, ORIGIN))
        self.assert_code('content_collision', lambda: constant.validate(bad))

    def test_derived_collisions_with_roots_other_variants_and_reserved_ids(self):
        import hashlib
        chosen = '12345678-1234-8234-8234-123456789abc'
        def digest(raw):
            return uuid.UUID(chosen).bytes + b'\0' * 16 if raw.startswith(v2.IDENTITY_DOMAIN) else hashlib.sha256(raw).digest()
        engine = v2.ChatEngine(digest=digest)
        f = self.family([self.variant(), self.variant('Y')])
        g = self.family(root=chosen)
        self.assert_code('identifier_collision', lambda: engine.validate(v2.ChatStateV2(families=(f, g))))
        self.assert_code('identifier_collision', lambda: engine.validate(v2.ChatStateV2(families=(f,), family_deletes=(chosen,), chat_tombstones=(chosen,))))
        h = self.family([self.variant(), self.variant('Z')], root=ORIGIN)
        self.assert_code('identifier_collision', lambda: engine.validate(v2.ChatStateV2(families=(f, h))))
        self.assert_code('identifier_collision', lambda: engine.validate(v2.ChatStateV2(families=(self.family([self.variant(), self.variant('Y'), self.variant('Z')]),))))
        live = engine.validate(v2.ChatStateV2(families=(f,)))
        deleted = engine.delete_variants(live, frozenset({engine.project(live)[1].reference})).state
        self.assert_code('identifier_collision', lambda: engine.observe(deleted, ROOT, self.payload('Z'), bits(1)))

    def test_capacity_is_checked_after_fanout_without_partial_return(self):
        engine = v2.ChatEngine(limits=v2.Limits(maximum_tombstones=1))
        a = engine.validate(self.state().state)
        deleted = engine.delete_families(a, frozenset({ROOT})).state
        incoming = engine.validate(self.state([self.variant(), self.variant('Y')]).state)
        snapshot = (deleted, incoming)
        self.assert_code('capacity_tombstones', lambda: engine.join(deleted, incoming))
        self.assertEqual((deleted, incoming), snapshot)
        self.assertEqual(len(engine.project(incoming)), 2)

    def test_exact_count_reservations_and_byte_boundaries(self):
        original = self.state()
        usage = original.usage
        cases = [('maximum_live_variants', 0, 'capacity_live_variants'),
                 ('maximum_records', 0, 'capacity_records'),
                 ('maximum_families', 0, 'capacity_families'),
                 ('maximum_document_bytes', usage.document_bytes - 1, 'capacity_document_bytes'),
                 ('maximum_journal_bytes', usage.journal_bytes - 1, 'capacity_journal_bytes')]
        for field, limit, code in cases:
            engine = v2.ChatEngine(limits=replace(v2.Limits(), **{field: limit}))
            self.assert_code(code, lambda: engine.validate(original.state))
        exact = v2.ChatEngine(limits=v2.Limits(maximum_live_variants=1, maximum_records=1, maximum_families=1,
                            maximum_document_bytes=usage.document_bytes, maximum_journal_bytes=usage.journal_bytes))
        self.assertEqual(exact.validate(original.state).usage, usage)
        self.assert_code('capacity_records', lambda: v2.ChatEngine(limits=v2.Limits(other_records=30000)).validate(original.state))
        self.assert_code('capacity_document_bytes', lambda: v2.ChatEngine(limits=v2.Limits(other_document_bytes=8*1024*1024)).validate(original.state))
        self.assert_code('capacity_journal_bytes', lambda: v2.ChatEngine(limits=v2.Limits(other_journal_bytes=17*1024*1024)).validate(original.state))
        deleted = self.engine.delete_families(original, frozenset({ROOT})).state
        self.assert_code('capacity_tombstones', lambda: v2.ChatEngine(limits=v2.Limits(other_tombstones=20000)).validate(deleted.state))
        for value in [True, -1, 0.0, '2', None]:
            with self.assertRaises(v2.ChatStateError):
                v2.ChatEngine(limits=v2.Limits(other_records=value)).validate(v2.ChatStateV2())

    def test_forged_or_other_budget_validated_wrappers_are_revalidated(self):
        state = self.state()
        invalid = replace(state, state=replace(state.state, order_clock=True))
        for action in [lambda: self.engine.join(invalid, state), lambda: self.engine.project(invalid),
                       lambda: self.engine.observe(invalid, ROOT, self.payload(), bits(1))]:
            with self.assertRaises(v2.ChatStateError):
                action()
        tiny = v2.ChatEngine(limits=v2.Limits(maximum_live_variants=0))
        self.assert_code('capacity_live_variants', lambda: tiny.join(state, state))

    def test_seeded_compatible_states_obey_algebra_and_deletion_monotonicity(self):
        rng = random.Random(77182)
        roots = [str(uuid.UUID(int=i + 10)) for i in range(4)]
        for iteration in range(35):
            states = []
            for _ in range(3):
                families = []
                for i, root in enumerate(roots):
                    variants = [self.variant('X', rng.choice([-0.0, 0.0, 100., 200.]))]
                    variants += [self.variant(text, rng.randrange(300)) for text in ['Y', 'é', 'e\u0301'] if rng.choice([True, False])]
                    families.append(self.family(variants, root=root, order=self.order(i, rng.randrange(4))))
                state = self.engine.validate(v2.ChatStateV2(families=tuple(reversed(families))))
                refs = frozenset(row.reference for row in self.rows(state) if rng.randrange(8) == 0)
                state = self.engine.delete_variants(state, refs).state
                if rng.randrange(4) == 0:
                    state = self.engine.delete_families(state, frozenset({rng.choice(roots)})).state
                states.append(state)
            with self.subTest(iteration=iteration):
                result = self.assert_laws(states)
                for before in states:
                    self.assertTrue(set(before.state.variant_deletes) <= set(result.state.variant_deletes))
                    self.assertTrue(set(before.state.chat_tombstones) <= set(result.state.chat_tombstones))
                for row in self.rows(result):
                    dates = [r.earliest_date_bits for s in states for r in self.rows(s) if r.reference == row.reference]
                    self.assertIn(row.earliest_date_bits, dates)
                    self.assertEqual(row.earliest_date_bits, min(dates, key=lambda b: (struct.unpack('>d', b)[0], b)))
                unchanged = result
                for _ in range(3):
                    unchanged = self.engine.join(unchanged, result)
                self.assertEqual(unchanged, result)


    def test_projection_rejects_cross_hash_context_instead_of_renaming(self):
        import hashlib
        original = self.state([self.variant(), self.variant('Y')])
        def different(raw):
            return b'x' * 32 if raw.startswith(v2.IDENTITY_DOMAIN) else hashlib.sha256(raw).digest()
        other = v2.ChatEngine(digest=different)
        self.assert_code('validation_context_mismatch', lambda: other.project(original))
        self.assertEqual(self.rows(original)[0].reference.projected_id, ROOT)

    def test_projection_tie_breaks_use_uuid_bytes_and_anchor_then_key(self):
        low_root, high_root = str(uuid.UUID(int=1)), str(uuid.UUID(int=2))
        # Same order key: family UUID bytes break the tie; dates do not.
        low = self.family([self.variant('X', 300), self.variant('Y', 1), self.variant('Z', 0)], root=low_root)
        high = self.family([self.variant('X', 0)], root=high_root)
        state = self.engine.validate(v2.ChatStateV2(families=(high, low)))
        rows = self.rows(state)
        self.assertEqual([r.reference.family_id for r in rows], [low_root, low_root, low_root, high_root])
        self.assertEqual(rows[0].reference.projected_id, low_root)
        self.assertEqual([r.reference.content_key for r in rows[1:3]], sorted(v.content_key for v in low.variants[1:]))
        # Equal counters compare origin, then batch, then sequence as whole tuples.
        first = self.family(root=high_root, order=self.order(99, 1, ORIGIN, BATCH))
        later = self.family(root=low_root, order=self.order(0, 1, BATCH, ORIGIN))
        state = self.engine.validate(v2.ChatStateV2(families=(later, first)))
        self.assertEqual([r.reference.family_id for r in self.rows(state)], [high_root, low_root])

    def test_default_live_tombstone_and_record_caps_are_inclusive(self):
        variants = [self.variant()] + [self.variant('item' + str(i)) for i in range(9999)]
        raw = v2.ChatStateV2(families=(self.family(variants),))
        at_limit = self.engine.validate(raw)
        self.assertEqual(at_limit.usage.live_variants, 10000)
        records = v2.ChatEngine(limits=v2.Limits(other_records=20000))
        self.assertEqual(records.validate(raw).usage.live_variants, 10000)
        self.assert_code('capacity_records', lambda: v2.ChatEngine(limits=v2.Limits(other_records=20001)).validate(raw))
        more = replace(raw, families=(self.family(variants + [self.variant('too many')]),))
        self.assert_code('capacity_live_variants', lambda: self.engine.validate(more))
        roots = tuple(str(uuid.UUID(int=i)) for i in range(20000))
        deleted = v2.ChatStateV2(family_deletes=roots, chat_tombstones=roots)
        self.assertEqual(self.engine.validate(deleted).usage.tombstones, 20000)
        overflow = roots + (str(uuid.UUID(int=20000)),)
        self.assert_code('capacity_tombstones', lambda: self.engine.validate(replace(deleted, family_deletes=overflow, chat_tombstones=overflow)))

    def test_default_retained_root_budget_counts_descriptorless_barriers(self):
        # Other caps are separately checked above. Raise byte/marker budgets only
        # to isolate the independent 30,000 retained-root gate.
        engine = v2.ChatEngine(limits=v2.Limits(maximum_tombstones=30001, maximum_document_bytes=64*1024*1024,
                                               maximum_journal_bytes=128*1024*1024))
        roots = tuple(str(uuid.UUID(int=i)) for i in range(30000))
        raw = v2.ChatStateV2(family_deletes=roots, chat_tombstones=roots)
        self.assertEqual(engine.validate(raw).usage.retained_roots, 30000)
        overflow = roots + (str(uuid.UUID(int=30000)),)
        self.assert_code('capacity_families', lambda: engine.validate(replace(raw, family_deletes=overflow, chat_tombstones=overflow)))


if __name__ == '__main__':
    unittest.main()
