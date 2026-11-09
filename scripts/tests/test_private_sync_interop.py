"""The explicit native gate must not turn a skipped fixture into a release pass."""
from pathlib import Path
import subprocess
import base64
import json
import hashlib
import copy
import importlib.util
import sys
import unittest

from scripts import private_sync_interop as gate
from companion.private_sync_codec import strict_json, decrypt_remote_payload

FIXTURE = Path(__file__).resolve().parents[2] / 'Tests/Fixtures/private-memory-sync-interop-v1.json'


class NativeGateTests(unittest.TestCase):
    def test_pending_or_incomplete_native_export_is_rejected(self):
        for fixture in [None, {}, {'format': gate.FORMAT, 'status': 'pending-native-export'},
                        {'format': gate.FORMAT, 'status': 'native-export'}]:
            with self.assertRaises(ValueError):
                gate.verify_native_vectors(fixture)

    def test_cli_returns_failure_for_pending_fixture_without_content_disclosure(self):
        # This checked-in marker is intentionally not a fabricated golden fixture.
        if strict_json(FIXTURE.read_bytes()).get('status') != 'pending-native-export':
            self.skipTest('The native export has replaced the marker')
        result = subprocess.run([sys.executable, '-m', 'scripts.private_sync_interop', str(FIXTURE)],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('Native export is required', result.stderr)
        self.assertNotIn('Traceback', result.stderr)

    def test_convergence_gate_uses_bytes_not_the_exported_boolean(self):
        gate.check_convergence([{'forwardBase64': 'YQ==', 'reverseBase64': 'YQ==', 'converges': True}])
        for probe in [
            {'forwardBase64': 'YQ==', 'reverseBase64': 'Yg==', 'converges': True},
            {'forwardBase64': 'YQ==', 'reverseBase64': 'YQ==', 'converges': False},
            {'forwardBase64': '!', 'reverseBase64': 'YQ==', 'converges': True},
        ]:
            with self.assertRaises(ValueError):
                gate.check_convergence([probe])

    @unittest.skipUnless(importlib.util.find_spec('cryptography'), 'optional sync cryptography is not installed')
    def test_named_placeholders_cannot_satisfy_native_coverage(self):
        # Adversarial gate plumbing only, NOT expected Foundation output bytes.
        names = ['date-' + name for name in (
            'integer', 'negative-zero', 'negative-fraction', 'fraction', 'smallest-positive',
            'smallest-negative', 'small-exponent', 'decimal-threshold', 'present-next-up',
            'unix-lower-bound', 'unix-upper-bound')]
        names += ['string-' + name for name in ('escapes', 'nfc', 'nfd', 'supplementary', 'separators')]
        names += ['optional-' + name for name in ('omitted', 'null', 'empty')]
        original = 'abcdef01-2345-4abc-8def-0123456789ab'
        old = json.loads(FIXTURE.with_name('private-memory-sync-v1.json').read_text())
        old['plaintextBase64'] = base64.b64encode(decrypt_remote_payload(
            base64.b64decode(old['encryptedBase64']), old['passphrase'])).decode()
        empty_chats = base64.b64encode(b'{"chats":[],"chatOrder":[]}').decode()
        fixture = {
            'format': gate.FORMAT, 'status': 'native-export',
            'records': [dict(name=name, kind='knowledgeSource', inputBase64='e30=', canonicalBase64='e30=') for name in names],
            'conflicts': [dict(kind=kind, originalID=original, loserCanonicalBase64='e30=',
                               expectedID=identifier, mergedBase64='e30=', reversedBase64='e30=')
                          for kind, identifier in [('note', 'ef418fa3-8fe2-5e16-ade2-4b111db9484a'),
                                                   ('chat', '4ec06e1b-be23-5656-beb0-5ed99c415d8c')]],
            'restorations': [dict(kind=kind, generation=generation, originalID=original, expectedID=original,
                                  tombstones=['note:00000000-0000-0000-0000-%012d' % i for i in range(generation)])
                             for kind in ('note', 'chat') for generation in (1, 2, 3)],
            'documents': [dict(normalizedBase64=empty_chats, chatOrder=[])],
            'unicodeProbes': [dict(name=name, forwardBase64='e30=', reverseBase64='e30=', converges=True)
                              for name in ('canonically-equivalent-chat', 'filename-ascii-tie', 'filename-unicode-tie')],
            'malformedDates': [None] * 8, 'malformedDocuments': [None] * 4,
            'envelopes': [old] * 3, 'knowledgeProbes': [{}] * 3, 'chatOrderProbes': [{}], 'chatContentProbes': [{}],
        }
        with self.assertRaises(ValueError):
            gate.verify_native_vectors(fixture)
        fixture['records'][1]['name'] = fixture['records'][0]['name']
        with self.assertRaises(ValueError):
            gate.verify_native_vectors(fixture)

    def test_synthetic_record_case_cannot_be_replaced_by_another_case(self):
        def encoded(value):
            # Test-only parser input, not a native golden or canonicalizer.
            return base64.b64encode(json.dumps(value, ensure_ascii=False).encode()).decode()
        original = dict(id='aBcDeF01-2345-4aBc-8dEf-0123456789aB', project='General',
                        source='Synthetic fixture', text='Synthetic date', savedAt=0)
        for name, source, canonical in [
            ('date-negative-zero', original, original),
            ('string-nfc', dict(original, text='Cafe\u0301'), original),
            ('optional-empty', dict(origin='selectedFile', label='a.txt', revision='', repositoryName=''),
             dict(origin='selectedFile', label='a.txt')),
        ]:
            record = dict(name=name, kind='knowledgeSource' if name.startswith('optional') else 'note',
                          inputBase64=encoded(source), canonicalBase64=encoded(canonical))
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'coverage'):
                gate.verify_input_coverage({'records': [record]})

    def test_empty_unicode_outputs_cannot_claim_convergence(self):
        def encoded(value):
            return base64.b64encode(json.dumps(value).encode()).decode()
        fixture = dict(records=[], conflicts=[], restorations=[], documents=[], unicodeProbes=[
            dict(name='canonically-equivalent-chat', leftBase64=encoded({'chats': [{'text': 'Caf\u00e9'}]}),
                 rightBase64=encoded({'chats': [{'text': 'Cafe\u0301'}]}),
                 forwardBase64=encoded({'chats': []}), reverseBase64=encoded({'chats': []}), converges=True)])
        with self.assertRaisesRegex(ValueError, 'coverage'):
            gate.verify_input_coverage(fixture)

    def test_knowledge_probe_inputs_and_divergence_are_required(self):
        # Synthetic parser inputs only, not expected native output bytes.
        text = 'synthetic file'; digest = hashlib.sha256(text.encode()).hexdigest()
        def doc(cached_at=None, suppressed=False, cutoff=None):
            entry = dict(id='file:' + digest, kind='selectedFile', text=text,
                         source=dict(origin='selectedFile', label='sample.txt', revision=digest),
                         sourceDate=0, cachedAt=cached_at, byteCount=len(text))
            snapshot = dict(accountID='device-local', project='General', entries=[] if cached_at is None else [entry],
                            suppressedIDs=['file:' + digest] if suppressed else [])
            if cutoff is not None:
                snapshot['clearBefore'] = cutoff
            return dict(repositoryID=12345, knowledge=[snapshot])
        def encoded(value):
            return base64.b64encode(json.dumps(value).encode()).decode()
        original = encoded(doc(100, suppressed=True))
        removed = encoded(doc(suppressed=True))
        probes = [
            dict(name='knowledge-suppressed-idempotence', acceptedInput=True, inputBase64=original,
                 forwardBase64=original, reverseBase64=removed, converges=False),
            dict(name='knowledge-suppressed-identity', acceptedInput=True, inputBase64=original,
                 forwardBase64=original, reverseBase64=removed, converges=False),
            dict(name='knowledge-clear-grouping', acceptedInputs=True, leftInputBase64=encoded(doc(100)),
                 middleInputBase64=encoded(doc(200)), rightInputBase64=encoded(doc(cutoff=150)),
                 forwardBase64=encoded(doc(cutoff=150)), reverseBase64=encoded(doc(200, cutoff=150)), converges=False)]
        gate.verify_knowledge_coverage(probes)
        forged_identity = copy.deepcopy(probes)
        forged_identity[1]['forwardBase64'] = removed
        forged_identity[1]['reverseBase64'] = removed
        forged_identity[1]['converges'] = True
        with self.assertRaises(ValueError):
            gate.verify_knowledge_coverage(forged_identity)
        with self.assertRaises(ValueError):
            gate.check_convergence(probes)
        for index, key, value in [(0, 'acceptedInput', False), (0, 'inputBase64', encoded(doc(100))),
                                   (2, 'middleInputBase64', encoded(doc(100))), (2, 'rightInputBase64', encoded(doc(cutoff=250)))]:
            changed = copy.deepcopy(probes); changed[index][key] = value
            with self.assertRaises(ValueError):
                gate.verify_knowledge_coverage(changed)

    def test_chat_order_grouping_requires_exact_inputs_and_retained_records(self):
        # Parser-only samples, never expected native encoding or a replacement merge.
        verify = getattr(gate, 'verify_chat_order_coverage', None)
        self.assertTrue(callable(verify), 'Chat-order grouping coverage must be required')
        identifiers = ['00000000-0000-4000-8000-000000000000',
                       '00000000-0000-4000-8000-000000000001']
        def doc(order):
            return dict(version=1, repositoryID=12345, notes=[], knowledge=[], tombstones=[],
                        includesPrivateWorkspaces=False, chatOrder=[identifiers[i] for i in order],
                        chats=[dict(id=identifiers[i], project='General', role='user',
                                    text=f'Synthetic grouping turn {i}', date=100) for i in order])
        def encoded(value):
            return base64.b64encode(json.dumps(value).encode()).decode()
        probe = dict(name='equal-date-chat-order-grouping', acceptedInputs=True,
                     baseInputBase64=encoded(doc([])), leftInputBase64=encoded(doc([0])),
                     middleInputBase64=encoded(doc([1])), rightInputBase64=encoded(doc([1, 0])),
                     forwardBase64=encoded(doc([0, 1])), reverseBase64=encoded(doc([1, 0])), converges=False)
        verify([probe])
        with self.assertRaises(ValueError):
            gate.check_convergence([probe])
        forged = dict(probe, converges=True)
        with self.assertRaises(ValueError):
            gate.check_convergence([forged])
        for key, value in [('acceptedInputs', False), ('baseInputBase64', encoded(doc([0]))),
                           ('leftInputBase64', encoded(doc([1]))),
                           ('middleInputBase64', encoded(doc([0]))),
                           ('rightInputBase64', encoded(doc([0, 1]))),
                           ('forwardBase64', encoded(doc([]))),
                           ('reverseBase64', encoded(doc([1, 1])))]:
            changed = dict(probe, **{key: value})
            with self.subTest(key=key), self.assertRaises(ValueError):
                verify([changed])
        changed_output = doc([0, 1]); changed_output['chats'][0]['text'] = 'Rewritten'
        with self.assertRaises(ValueError):
            verify([dict(probe, forwardBase64=encoded(changed_output))])
        for field in ('baseInputBase64', 'forwardBase64'):
            for key, value in [('version', True), ('version', 1.0), ('includesPrivateWorkspaces', 0)]:
                document = json.loads(base64.b64decode(probe[field])); document[key] = value
                with self.subTest(field=field, key=key), self.assertRaises(ValueError):
                    verify([dict(probe, **{field: encoded(document)})])
        for probes in [[], [probe, probe], [dict(probe, name='placeholder')]]:
            with self.assertRaises(ValueError):
                verify(probes)

    def test_chat_content_grouping_requires_inputs_and_native_conflict_identities(self):
        verify = getattr(gate, 'verify_chat_content_coverage', None)
        self.assertTrue(callable(verify), 'Chat-content grouping coverage must be required')
        original = 'ABCDEF01-2345-4ABC-8DEF-0123456789AB'
        def chat(text, date):
            return dict(id=original, project='General', role='user', text=text, date=date)
        def doc(chats):
            return dict(version=1, repositoryID=12345, notes=[], knowledge=[], tombstones=[],
                        includesPrivateWorkspaces=False, chatOrder=[v['id'] for v in chats], chats=chats)
        def encoded(value):
            return base64.b64encode(json.dumps(value).encode()).decode()
        rows = [chat('X', 100), chat('X', 200), chat('Y', 150)]
        raw = [encoded(row) for row in rows]
        # Derived IDs exercise the gate with parser samples, not native golden bytes.
        def copy_row(index):
            return dict(rows[index], id=gate.conflict_id('chat', original, base64.b64decode(raw[index])).upper())
        left = encoded(doc([rows[0], copy_row(2)]))
        right = encoded(doc([rows[0], copy_row(2), copy_row(1)]))
        probe = dict(name='chat-content-date-grouping', acceptedInputs=True,
                     baseInputBase64=encoded(doc([])), leftInputBase64=encoded(doc([rows[0]])),
                     middleInputBase64=encoded(doc([rows[1]])), rightInputBase64=encoded(doc([rows[2]])),
                     inputRecordsBase64=raw, forwardBase64=left, reverseBase64=right, converges=False)
        verify([probe])
        with self.assertRaises(ValueError):
            gate.check_convergence([dict(probe, converges=True)])
        for key, value in [('acceptedInputs', False), ('baseInputBase64', encoded(doc(rows[:1]))),
                           ('middleInputBase64', encoded(doc(rows[:1]))), ('inputRecordsBase64', raw[:2]),
                           ('forwardBase64', encoded(doc([rows[0]])))]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                verify([dict(probe, **{key: value})])
        for change in [dict(rows[2], id='00000000-0000-4000-8000-000000000000'),
                       dict(copy_row(2), date=151), dict(copy_row(2), text='Z')]:
            with self.assertRaises(ValueError):
                verify([dict(probe, forwardBase64=encoded(doc([rows[0], change])))])
        with self.assertRaises(ValueError):
            verify([dict(probe, forwardBase64=encoded(dict(doc([rows[0], copy_row(2)]), version=True)))])
        for probes in [[], [probe, probe], [dict(probe, name='placeholder')]]:
            with self.assertRaises(ValueError):
                verify(probes)

    def test_committed_native_vectors(self):
        fixture = strict_json(FIXTURE.read_bytes())
        if fixture.get('status') == 'pending-native-export':
            self.skipTest('Xcode 26 golden export pending; no writer conformance claimed')
        gate.verify_native_vectors(fixture)


if __name__ == '__main__':
    unittest.main()
