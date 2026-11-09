#!/usr/bin/env python3
"""Fail-closed check of synthetic native exports, not portable writer approval.

Run as `python -m scripts.private_sync_interop path/to/export.json`.
Never pass a user vault, credential file, or real private data to this tool.
"""
from __future__ import annotations

import base64
import binascii
import hashlib
from pathlib import Path
import sys

from companion.private_sync_codec import (
    MAXIMUM_DOCUMENT_BYTES, ReferenceDate, conflict_id, decrypt_remote_payload,
    record_uuid, restored_id, strict_json,
)

FORMAT = 'veyra-private-sync-interop-v1'


def _bytes(value):
    if not isinstance(value, str):
        raise ValueError('Invalid native vector encoding')
    try:
        return base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise ValueError('Invalid native vector encoding') from exc


def check_convergence(probes):
    """A recorded native divergence is a blocker, never an approved golden."""
    for probe in probes:
        forward, reverse = _bytes(probe['forwardBase64']), _bytes(probe['reverseBase64'])
        if probe['converges'] is not True or forward != reverse:
            raise ValueError('Native merge does not converge; v1 writers remain blocked')


# These are synthetic INPUT requirements, never expected Foundation output bytes.
_DATE_INPUTS = dict(zip(
    ('integer', 'negative-zero', 'negative-fraction', 'fraction', 'smallest-positive',
     'smallest-negative', 'small-exponent', 'decimal-threshold', 'present-next-up',
     'unix-lower-bound', 'unix-upper-bound'),
    ('0', '-0', '-0.5', '0.125', '5e-324', '-5e-324', '1e-7', '0.000001',
     '721692800.0000001', '-978307200', '252423993599')))
_STRING_INPUTS = {'escapes': 'slash/ quote" backslash\\ tab\t newline\n carriage\r nul\0 backspace\b',
                  'nfc': 'Caf\u00e9', 'nfd': 'Cafe\u0301', 'supplementary': '🧭 𝄞 中文',
                  'separators': 'one\u2028two\u2029three'}
_PASSPHRASES = {'Synthetic recovery words only', '  Synthetic Caf\u00e9 🧭 recovery  ',
                '  Synthetic Cafe\u0301 🧭 recovery  '}
_ORIGINAL = 'abcdef01-2345-4abc-8def-0123456789ab'
_CHAT_ORDER = ['FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF', '11111111-1111-4111-8111-111111111111',
               'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA']


def _require(condition):
    if not condition:
        raise ValueError('Native coverage is incomplete or mislabeled')


def verify_input_coverage(fixture):
    """Validate actual synthetic cases, not just a row count or claimed name."""
    for vector in fixture['records']:
        name = vector['name']
        source = strict_json(_bytes(vector['inputBase64']))
        canonical = strict_json(_bytes(vector['canonicalBase64']))
        if name.startswith('optional-'):
            _require(vector['kind'] == 'knowledgeSource' and isinstance(canonical, dict))
            suffix = name.removeprefix('optional-')
            expected = {'origin': 'selectedFile', 'label': 'a.txt'}
            if suffix != 'omitted':
                expected.update(revision=None if suffix == 'null' else '',
                                repositoryName=None if suffix == 'null' else '')
            _require(source == expected)
            _require(canonical == {key: value for key, value in expected.items() if value is not None})
        else:
            _require(vector['kind'] == 'note')
            seconds = _DATE_INPUTS[name[5:]] if name.startswith('date-') else '721692800.0000001'
            text = 'Synthetic date' if name.startswith('date-') else _STRING_INPUTS[name[7:]]
            _require(source['text'] == text and source['project'] == 'General'
                     and source['source'] == 'Synthetic fixture' and source['id'].lower() == _ORIGINAL)
            _require(ReferenceDate.from_json(source['savedAt']).bits_hex
                     == ReferenceDate.from_json(strict_json(seconds.encode())).bits_hex)
    for vector in fixture['conflicts']:
        _require(vector['originalID'] == _ORIGINAL)
        loser = strict_json(_bytes(vector['loserCanonicalBase64']))
        _require(loser['id'] == _ORIGINAL.upper() and loser['text'] == 'Zulu')
        merged = strict_json(_bytes(vector['mergedBase64']))
        records = merged['notes' if vector['kind'] == 'note' else 'chats']
        _require(len(records) == 2 and {row['text'] for row in records} == {'Alpha', 'Zulu'}
                 and {row['id'].lower() for row in records} == {_ORIGINAL, vector['expectedID']})
    prior = {(v['kind'], v['generation']): v['expectedID'] for v in fixture['restorations']}
    for vector in fixture['restorations']:
        kind, generation = vector['kind'], vector['generation']
        _require(vector['originalID'] == _ORIGINAL and vector['tombstones'] ==
                 [kind + ':' + _ORIGINAL] + [kind + ':' + prior[kind, g] for g in range(1, generation)])
    for vector in fixture['documents']:
        _require(vector['name'] == 'equal-date-chat-order' and vector['chatOrder'] == _CHAT_ORDER)
        for field in ('inputBase64', 'normalizedBase64'):
            document = strict_json(_bytes(vector[field]))
            _require(document['repositoryID'] == 12345 and document['chatOrder'] == _CHAT_ORDER
                     and [row['id'] for row in document['chats']] == _CHAT_ORDER
                     and [row['text'] for row in document['chats']]
                        == ['Synthetic turn 0', 'Synthetic turn 1', 'Synthetic turn 2'])
    for vector in fixture['unicodeProbes']:
        left, right = (strict_json(_bytes(vector[key])) for key in ('leftBase64', 'rightBase64'))
        forward, reverse = (strict_json(_bytes(vector[key])) for key in ('forwardBase64', 'reverseBase64'))
        if vector['name'] == 'canonically-equivalent-chat':
            _require(len(left['chats']) == len(right['chats']) == len(forward['chats']) == len(reverse['chats']) == 1)
            _require(left['chats'][0]['text'] == 'Caf\u00e9' and right['chats'][0]['text'] == 'Cafe\u0301')
            _require(all(value['chats'][0]['text'] in ('Caf\u00e9', 'Cafe\u0301') for value in (forward, reverse)))
        else:
            labels = ('a.txt', 'z.txt') if vector['name'] == 'filename-ascii-tie' else ('a\u0301\u0327.txt', 'a\u0327\u0301.txt')
            _require((left['source']['label'], right['source']['label']) == labels)
            _require(all(value['source']['label'] in labels and value['text'] == 'Synthetic shared file'
                         for value in (forward, reverse)))
    invalid_dates = {'true', 'null', '"0"', 'NaN', 'Infinity', '1e999', '-978307201', '252423993600'}
    _require({v['name'] for v in fixture['malformedDates']} == invalid_dates)
    for vector in fixture['malformedDates']:
        _require(type(vector['decodes']) is bool and vector['validDate'] is False
                 and _bytes(vector['inputBase64']).endswith(('"savedAt":' + vector['name'] + '}').encode()))
    document_probes = {'duplicate-version-same', 'duplicate-version-different', 'unknown-nested-65', 'unknown-nested-513'}
    _require({v['name'] for v in fixture['malformedDocuments']} == document_probes)
    for vector in fixture['malformedDocuments']:
        raw = _bytes(vector['inputBase64'])
        name = vector['name']
        expected = (b'"version":1,"version":' + (b'1' if name.endswith('same') else b'2')
                    if name.startswith('duplicate-') else b'"unknown":' + b'[' * int(name.rsplit('-', 1)[1]) + b'0' + b']' * int(name.rsplit('-', 1)[1]))
        _require(type(vector['accepted']) is bool and expected in raw)
    _require({v['passphrase'] for v in fixture['envelopes']} == _PASSPHRASES)
    _require(len({_bytes(v['encryptedBase64']) for v in fixture['envelopes']}) == 3)
    for vector in fixture['envelopes']:
        plaintext = strict_json(_bytes(vector['plaintextBase64']))
        _require(plaintext == {'version': 1, 'repositoryID': 12345, 'notes': [], 'chats': [],
                              'knowledge': [], 'tombstones': [], 'includesPrivateWorkspaces': False, 'chatOrder': []})


def verify_knowledge_coverage(probes):
    _require(len(probes) == 3 and {v['name'] for v in probes} == {
        'knowledge-suppressed-idempotence', 'knowledge-suppressed-identity', 'knowledge-clear-grouping'})
    text = 'synthetic file'; digest = hashlib.sha256(text.encode()).hexdigest()
    def scope(raw):
        document = strict_json(_bytes(raw))
        _require(document['repositoryID'] == 12345 and len(document['knowledge']) == 1)
        snapshot = document['knowledge'][0]
        _require(snapshot['accountID'] == 'device-local' and snapshot['project'] == 'General'
                 and snapshot.get('repository') is None)
        return snapshot
    def require_input(raw, cached_at, suppressed=False, cutoff=None):
        snapshot = scope(raw)
        _require(snapshot['suppressedIDs'] == (['file:' + digest] if suppressed else [])
                 and snapshot.get('clearBefore') == cutoff)
        expected = [] if cached_at is None else [{
            'id': 'file:' + digest, 'kind': 'selectedFile', 'text': text,
            'source': {'origin': 'selectedFile', 'label': 'sample.txt', 'revision': digest},
            'sourceDate': 0, 'cachedAt': cached_at, 'byteCount': len(text.encode())}]
        _require(snapshot['entries'] == expected)
    for vector in probes:
        if vector['name'] == 'knowledge-clear-grouping':
            _require(vector['acceptedInputs'] is True)
            require_input(vector['leftInputBase64'], 100)
            require_input(vector['middleInputBase64'], 200)
            require_input(vector['rightInputBase64'], None, cutoff=150)
        else:
            _require(vector['acceptedInput'] is True)
            require_input(vector['inputBase64'], 100, suppressed=True)
            if vector['name'] == 'knowledge-suppressed-identity':
                _require(_bytes(vector['forwardBase64']) == _bytes(vector['inputBase64']))
        for key in ('forwardBase64', 'reverseBase64'):
            snapshot = scope(vector[key])
            _require(isinstance(snapshot['entries'], list) and len(snapshot['entries']) <= 1)
            _require(all(entry['id'] == 'file:' + digest and entry['text'] == text for entry in snapshot['entries']))


def _chat_probe_document(raw):
    document = strict_json(_bytes(raw))
    _require(isinstance(document, dict) and type(document.get('version')) is int
             and type(document.get('repositoryID')) is int
             and type(document.get('includesPrivateWorkspaces')) is bool)
    return document


def verify_chat_order_coverage(probes):
    """Require the exact synthetic grouping inputs without predicting native bytes."""
    _require(len(probes) == 1 and probes[0]['name'] == 'equal-date-chat-order-grouping')
    vector = probes[0]
    _require(vector['acceptedInputs'] is True)
    identifiers = ['00000000-0000-4000-8000-000000000000',
                   '00000000-0000-4000-8000-000000000001']
    def document(order):
        return dict(version=1, repositoryID=12345, notes=[], knowledge=[], tombstones=[],
                    includesPrivateWorkspaces=False, chatOrder=[identifiers[i] for i in order],
                    chats=[dict(id=identifiers[i], project='General', role='user',
                                text=f'Synthetic grouping turn {i}', date=100) for i in order])
    for field, order in [('baseInputBase64', []), ('leftInputBase64', [0]),
                         ('middleInputBase64', [1]), ('rightInputBase64', [1, 0])]:
        _require(_chat_probe_document(vector[field]) == document(order))
    # Either order is permitted here, but neither record may be lost or rewritten.
    # The separate byte-convergence check must reject unequal native results.
    for field in ('forwardBase64', 'reverseBase64'):
        output = _chat_probe_document(vector[field])
        _require(output in (document([0, 1]), document([1, 0])))


def verify_chat_content_coverage(probes):
    """Record grouping of timestamp-only and conflicting edits, without blessing it."""
    _require(len(probes) == 1 and probes[0]['name'] == 'chat-content-date-grouping')
    vector = probes[0]
    _require(vector['acceptedInputs'] is True)
    original = _ORIGINAL.upper()
    rows = [dict(id=original, project='General', role='user', text=text, date=date)
            for text, date in [('X', 100), ('X', 200), ('Y', 150)]]
    def document(chats):
        return dict(version=1, repositoryID=12345, notes=[], knowledge=[], tombstones=[],
                    includesPrivateWorkspaces=False, chatOrder=[row['id'] for row in chats], chats=chats)
    _require(_chat_probe_document(vector['baseInputBase64']) == document([]))
    for field, row in zip(('leftInputBase64', 'middleInputBase64', 'rightInputBase64'), rows):
        _require(_chat_probe_document(vector[field]) == document([row]))
    native_rows = vector['inputRecordsBase64']
    _require(isinstance(native_rows, list) and len(native_rows) == 3)
    allowed = list(rows)
    for raw, row in zip(native_rows, rows):
        canonical = _bytes(raw)
        _require(strict_json(canonical) == row)
        allowed.append(dict(row, id=conflict_id('chat', original, canonical).upper()))
    for field in ('forwardBase64', 'reverseBase64'):
        output = _chat_probe_document(vector[field])
        chats = output['chats']
        _require(isinstance(chats, list) and 2 <= len(chats) <= 3
                 and all(row in allowed for row in chats)
                 and len({row['id'] for row in chats}) == len(chats)
                 and original in {row['id'] for row in chats}
                 and {row['text'] for row in chats} == {'X', 'Y'}
                 and output == document(chats))


def verify_native_vectors(fixture):
    if (not isinstance(fixture, dict) or fixture.get('format') != FORMAT
            or fixture.get('status') != 'native-export'):
        raise ValueError('Native export is required; portable writers remain blocked')
    required = {'records': 19, 'conflicts': 2, 'restorations': 6, 'documents': 1,
                'unicodeProbes': 3, 'malformedDates': 8, 'malformedDocuments': 4, 'envelopes': 3, 'knowledgeProbes': 3, 'chatOrderProbes': 1, 'chatContentProbes': 1}
    if any(not isinstance(fixture.get(key), list) or len(fixture[key]) != count
           for key, count in required.items()):
        raise ValueError('Native export is incomplete')
    try:
        names = {record['name'] for record in fixture['records']}
        expected_names = {'date-' + name for name in (
            'integer', 'negative-zero', 'negative-fraction', 'fraction', 'smallest-positive',
            'smallest-negative', 'small-exponent', 'decimal-threshold', 'present-next-up',
            'unix-lower-bound', 'unix-upper-bound')}
        expected_names |= {'string-' + name for name in ('escapes', 'nfc', 'nfd', 'supplementary', 'separators')}
        expected_names |= {'optional-' + name for name in ('omitted', 'null', 'empty')}
        if (names != expected_names
                or {v['kind'] for v in fixture['conflicts']} != {'note', 'chat'}
                or {(v['kind'], v['generation']) for v in fixture['restorations']}
                    != {(kind, generation) for kind in ('note', 'chat') for generation in (1, 2, 3)}
                or {v['name'] for v in fixture['unicodeProbes']}
                    != {'canonically-equivalent-chat', 'filename-ascii-tie', 'filename-unicode-tie'}):
            raise ValueError('Native coverage is incomplete')
        verify_input_coverage(fixture)
        for vector in fixture['records']:
            source = strict_json(_bytes(vector['inputBase64']))
            canonical = strict_json(_bytes(vector['canonicalBase64']))
            if vector['kind'] == 'note':
                if (canonical['id'] != record_uuid(source['id'])
                        or ReferenceDate.from_json(source['savedAt']).bits_hex != vector['dateBits']
                        or ReferenceDate.from_json(canonical['savedAt']).bits_hex != vector['dateBits']
                        or any(source[key].encode('utf-8') != canonical[key].encode('utf-8')
                               for key in ['project', 'text', 'source'])):
                    raise ValueError('Native record changes date bits or string bytes')
            elif vector['kind'] != 'knowledgeSource':
                raise ValueError('Unknown native record kind')
        for vector in fixture['conflicts']:
            if (conflict_id(vector['kind'], vector['originalID'], _bytes(vector['loserCanonicalBase64']))
                    != vector['expectedID'] or _bytes(vector['mergedBase64']) != _bytes(vector['reversedBase64'])):
                raise ValueError('Native conflict identity mismatch')
        for vector in fixture['restorations']:
            if (len(vector['tombstones']) != vector['generation']
                    or restored_id(vector['kind'], vector['originalID'], vector['tombstones']) != vector['expectedID']):
                raise ValueError('Native restoration identity mismatch')
        for vector in fixture['documents']:
            document = strict_json(_bytes(vector['normalizedBase64']))
            if document['chatOrder'] != vector['chatOrder'] or [row['id'] for row in document['chats']] != vector['chatOrder']:
                raise ValueError('Native chat order mismatch')
        for vector in fixture['envelopes']:
            if decrypt_remote_payload(_bytes(vector['encryptedBase64']), vector['passphrase']) != _bytes(vector['plaintextBase64']):
                raise ValueError('Native envelope mismatch')
        verify_knowledge_coverage(fixture['knowledgeProbes'])
        verify_chat_order_coverage(fixture['chatOrderProbes'])
        verify_chat_content_coverage(fixture['chatContentProbes'])
        check_convergence(fixture['chatContentProbes'])
        check_convergence(fixture['chatOrderProbes'])
        check_convergence(fixture['unicodeProbes'])
        check_convergence(fixture['knowledgeProbes'])
    except (KeyError, TypeError, AttributeError, IndexError) as exc:
        raise ValueError('Malformed native export') from exc


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        print('Usage: python -m scripts.private_sync_interop SYNTHETIC_NATIVE_EXPORT.json', file=sys.stderr)
        return 2
    try:
        with Path(args[0]).open('rb') as stream:
            fixture = strict_json(stream.read(MAXIMUM_DOCUMENT_BYTES + 1))
        verify_native_vectors(fixture)
    except (OSError, ValueError, ImportError):
        # Do not leak a supplied file's contents or path through decoder exceptions.
        print('Native export is required and must pass all primitive/convergence checks. Writers remain blocked.', file=sys.stderr)
        return 1
    print('Native primitive vectors verified. Portable serializers, full document validation and writers are still unimplemented.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
