"""Compare synthetic XCTest chat projections to the independent Python engine.

This is a deliberately fixed test-evidence format, not a vault/wire codec. Native
provenance comes from the gated XCTest run and its xcresult attachment, not the
JSON producer label. Python-generated unit-test samples do not prove parity.
"""
from __future__ import annotations

import itertools
import json
from pathlib import Path
import struct
import sys

from companion.chat_state_v2 import (
    ChatEngine, ChatFamily, ChatPayload, ChatReference, ChatStateV2, ChatVariant,
    OrderKey, parse_counter_v2,
)

FORMAT = 'veyra-chat-state-v2-projection-evidence-v1'
MAX_BYTES = 1024 * 1024
ROOT = 'abcdef01-2345-4abc-8def-0123456789ab'
ORIGIN = '00000000-0000-4000-8000-000000000001'
BATCH = '00000000-0000-4000-8000-000000000002'


def payload_record(payload):
    return {name + 'UTF8': getattr(payload, name).encode('utf-8').hex()
            for name in ('project', 'role', 'text')}


def reference_record(reference):
    return dict(familyID=reference.family_id, contentKey=reference.content_key.hex(),
                projectedID=reference.projected_id)


def state_record(state):
    return dict(format=state.format, identityScheme=state.identity_scheme,
                orderClock=str(state.order_clock), families=[
                    dict(familyID=f.family_id, anchorContentKey=f.anchor_content_key.hex(),
                         orderKey=dict(counter=str(f.order_key.counter), originID=f.order_key.origin_id,
                                       batchID=f.order_key.batch_id, sequence=str(f.order_key.sequence)),
                         variants=[dict(contentKey=v.content_key.hex(), payload=payload_record(v.payload),
                                        dateBits=v.earliest_date_bits.hex()) for v in f.variants])
                    for f in state.families],
                familyDeletes=list(state.family_deletes),
                variantDeletes=[reference_record(r) for r in state.variant_deletes],
                chatTombstones=list(state.chat_tombstones))


def synthetic_inputs():
    """Fixed coverage specification, independently constructed with Python facts.

    No serialized native expected output is committed or generated here.
    The comparator requires these exact inputs, then replays the supplied inputs.
    """
    engine = ChatEngine()

    def variant(text, date, project='General', role='user'):
        payload = ChatPayload(project, role, text)
        return ChatVariant(engine.content_key(payload), payload, struct.pack('>d', date))

    def family(variants, identifier=ROOT, anchor=None, order=None):
        return ChatFamily(identifier, anchor or engine.content_key(ChatPayload('General', 'user', 'X')),
                          order or OrderKey(0, ORIGIN, BATCH, 0), tuple(variants))

    def state(variants):
        return ChatStateV2(families=(family(variants),))

    nfc = variant('café', -0.0, role='assistant')
    plus = variant('café', 0.0, role='assistant')
    nfd = variant('cafe\u0301', float.fromhex('0x0.0000000000001p-1022'), role='assistant')
    escaped = variant('\0😀\n', float.fromhex('0x1.0000000000001p0'), project='😀')
    small = OrderKey(1, BATCH, ORIGIN, 9)
    large = OrderKey(2, ORIGIN, BATCH, 0)
    f0 = family([variant('X', 100)], identifier='00000000-0000-4000-8000-000000000000')
    f1 = family([variant('X', 100)], identifier=ORIGIN, order=OrderKey(0, ORIGIN, BATCH, 1))
    stale = state([variant('X', 200), variant('Y', 150), variant('Z', 99)])
    return {
        'unicode': (
            ChatStateV2(order_clock=3, families=(family([nfc], anchor=nfc.content_key, order=small),)),
            ChatStateV2(order_clock=7, families=(family([plus, nfd], anchor=nfc.content_key, order=large),)),
            ChatStateV2(families=(family([plus, escaped], anchor=nfc.content_key, order=small),))),
        'source-order': (ChatStateV2(families=(f0,)), ChatStateV2(families=(f1,)),
                         ChatStateV2(families=(f1, f0))),
        'date-grouping': (state([variant('X', 100)]), state([variant('X', 200)]),
                          state([variant('X', 200), variant('Y', 150)])),
        'variant-delete-replay': (state([variant('X', 100), variant('Y', 150)]), stale),
        'family-delete-replay': (state([variant('X', 100)]), stale),
    }


def replay(name, sources):
    """Use only companion ChatEngine operations to calculate comparison results."""
    engine = ChatEngine()
    checked = [engine.validate(s) for s in sources]

    def result(label, value):
        return dict(name=label, state=state_record(value.state), projection=[
            dict(reference=reference_record(row.reference), payload=payload_record(row.payload),
                 dateBits=row.earliest_date_bits.hex()) for row in engine.project(value)])

    if name in ('unicode', 'source-order', 'date-grouping'):
        outputs = []
        for indices in itertools.permutations(range(3)):
            a, b, c = (checked[i] for i in indices)
            label = ''.join(map(str, indices))
            outputs.append(result(label + '-left', engine.join(engine.join(a, b), c)))
            outputs.append(result(label + '-right', engine.join(a, engine.join(b, c))))
        return outputs
    initial, stale = checked
    if name == 'variant-delete-replay':
        deleted = engine.delete_variants(initial, frozenset([engine.project(initial)[0].reference])).state
        observed_text = 'X'
    elif name == 'family-delete-replay':
        deleted = engine.delete_families(initial, frozenset([ROOT])).state
        observed_text = 'late'
    else:
        raise ValueError('Unknown scenario')
    replayed = engine.join(deleted, stale)
    observed = engine.observe(replayed, ROOT, ChatPayload('General', 'user', observed_text),
                              struct.pack('>d', 1.0)).state
    return [result(label, value) for label, value in
            [('initial', initial), ('deleted', deleted), ('replayed', replayed), ('observed', observed)]]


def _match(actual, expected):
    """Exact types, keys, coverage, bytes, and array order; no ignored extras."""
    if type(actual) is not type(expected):
        raise ValueError('Malformed or divergent evidence')
    if isinstance(expected, dict):
        if actual.keys() != expected.keys():
            raise ValueError('Missing or extra evidence fields')
        for key in expected:
            _match(actual[key], expected[key])
    elif isinstance(expected, list):
        if len(actual) != len(expected):
            raise ValueError('Missing or extra evidence coverage')
        for a, e in zip(actual, expected):
            _match(a, e)
    elif actual != expected:
        raise ValueError('Divergent evidence or changed input coverage')


def _read_covered_state(value):
    # Only called after exact shape/value coverage validation. This is a test
    # scenario reader, not an arbitrary document decoder or production codec.
    def payload(value):
        return ChatPayload(*(bytes.fromhex(value[k + 'UTF8']).decode('utf-8')
                             for k in ('project', 'role', 'text')))

    def reference(value):
        return ChatReference(value['familyID'], bytes.fromhex(value['contentKey']), value['projectedID'])

    families = []
    for f in value['families']:
        order = f['orderKey']
        families.append(ChatFamily(f['familyID'], bytes.fromhex(f['anchorContentKey']),
            OrderKey(parse_counter_v2(order['counter']), order['originID'], order['batchID'],
                     parse_counter_v2(order['sequence'])),
            tuple(ChatVariant(bytes.fromhex(v['contentKey']), payload(v['payload']), bytes.fromhex(v['dateBits']))
                  for v in f['variants'])))
    return ChatStateV2(value['format'], value['identityScheme'], parse_counter_v2(value['orderClock']),
                       tuple(families), tuple(value['familyDeletes']),
                       tuple(reference(r) for r in value['variantDeletes']), tuple(value['chatTombstones']))


def verify_native_vectors(evidence):
    required = synthetic_inputs()
    if (type(evidence) is not dict
            or evidence.keys() != {'format', 'status', 'producer', 'scenarios'}
            or evidence['format'] != FORMAT or evidence['status'] != 'native-export'
            or evidence['producer'] != 'ChatStateV2Tests'
            or type(evidence['scenarios']) is not list or len(evidence['scenarios']) != len(required)):
        raise ValueError('Complete chat v2 native evidence is required')
    for scenario, (name, sources) in zip(evidence['scenarios'], required.items()):
        if type(scenario) is not dict or scenario.keys() != {'name', 'inputs', 'results'}:
            raise ValueError('Malformed scenario')
        _match(scenario['name'], name)
        _match(scenario['inputs'], [state_record(s) for s in sources])
        received = tuple(_read_covered_state(s) for s in scenario['inputs'])
        _match(scenario['results'], replay(name, received))


def load_evidence(raw):
    if type(raw) is not bytes or len(raw) > MAX_BYTES:
        raise ValueError('Evidence size limit')

    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('Duplicate JSON key')
            result[key] = value
        return result

    def invalid_constant(_):
        raise ValueError('Nonfinite JSON value')

    try:
        return json.loads(raw.decode('utf-8'), object_pairs_hook=pairs, parse_constant=invalid_constant)
    except (UnicodeError, RecursionError) as exc:
        raise ValueError('Malformed evidence JSON') from exc


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        print('Usage: python -m scripts.chat_state_v2_interop SYNTHETIC_NATIVE_EXPORT.json', file=sys.stderr)
        return 2
    try:
        with Path(args[0]).open('rb') as stream:
            evidence = load_evidence(stream.read(MAX_BYTES + 1))
        verify_native_vectors(evidence)
    except (OSError, ValueError, RecursionError):
        print('Chat v2 native evidence is required and must match every synthetic input and result.', file=sys.stderr)
        return 1
    print('Chat v2 synthetic projections match Python; not a wire codec or writer approval.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
