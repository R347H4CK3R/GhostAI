"""Adversarial comparator plumbing, never a Python-authored native golden."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from scripts import chat_state_v2_interop as gate


class ChatProjectionEvidenceTests(unittest.TestCase):
    def sample(self):
        # This in-memory Python sample tests gate plumbing ONLY. It is not native
        # evidence, is never checked in as a golden, and cannot prove Swift parity.
        return {'format': gate.FORMAT, 'status': 'native-export',
                'producer': 'ChatStateV2Tests', 'scenarios': [
                    {'name': name, 'inputs': [gate.state_record(s) for s in sources],
                     'results': gate.replay(name, sources)}
                    for name, sources in gate.synthetic_inputs().items()]}

    def test_complete_python_sample_exercises_comparator_plumbing_only(self):
        gate.verify_native_vectors(self.sample())

    def test_missing_status_scenarios_inputs_and_groupings_fail_closed(self):
        base = self.sample()
        mutants = [None, {}, dict(base, status='pending-native-export'),
                   dict(base, scenarios=[]), dict(base, producer='python')]
        for field in ('inputs', 'results'):
            mutant = copy.deepcopy(base)
            mutant['scenarios'][0][field].pop()
            mutants.append(mutant)
        duplicate = copy.deepcopy(base)
        duplicate['scenarios'][1] = duplicate['scenarios'][0]
        mutants.append(duplicate)
        for value in mutants:
            with self.subTest(value=value and value.get('status')), self.assertRaises(ValueError):
                gate.verify_native_vectors(value)

    def test_named_empty_placeholders_and_changed_source_coverage_are_rejected(self):
        value = self.sample()
        value['scenarios'][0]['results'] = [
            dict(r, state={}, projection=[]) for r in value['scenarios'][0]['results']]
        with self.assertRaises(ValueError):
            gate.verify_native_vectors(value)
        value = self.sample()
        # Making two source replicas identical removes the grouping counterexample.
        value['scenarios'][2]['inputs'][1] = value['scenarios'][2]['inputs'][0]
        with self.assertRaises(ValueError):
            gate.verify_native_vectors(value)

    def test_each_projection_identity_payload_date_and_order_fact_is_compared(self):
        changes = [
            (('projection', 0, 'reference', 'familyID'), '00000000-0000-4000-8000-000000000001'),
            (('projection', 0, 'reference', 'projectedID'), '00000000-0000-4000-8000-000000000001'),
            (('projection', 0, 'reference', 'contentKey'), '00' * 32),
            (('projection', 0, 'payload', 'textUTF8'), '63616665cc81'),
            (('projection', 0, 'payload', 'projectUTF8'), '00'),
            (('projection', 0, 'payload', 'roleUTF8'), '75736572'),
            (('projection', 0, 'dateBits'), '8000000000000000'),
            (('state', 'orderClock'), '6'),
            (('state', 'families', 0, 'orderKey', 'counter'), '2'),
            (('state', 'families', 0, 'orderKey', 'originID'), '00000000-0000-4000-8000-000000000001'),
            (('state', 'families', 0, 'orderKey', 'batchID'), '00000000-0000-4000-8000-000000000002'),
            (('state', 'families', 0, 'orderKey', 'sequence'), '0'),
        ]
        for path, replacement in changes:
            value = self.sample()
            target = value['scenarios'][0]['results'][0]
            for part in path[:-1]:
                target = target[part]
            self.assertNotEqual(target[path[-1]], replacement)
            target[path[-1]] = replacement
            with self.subTest(path=path), self.assertRaises(ValueError):
                gate.verify_native_vectors(value)

    def test_ordered_projection_and_all_groupings_are_checked(self):
        for result_index in range(12):
            value = self.sample()
            value['scenarios'][1]['results'][result_index]['projection'].reverse()
            with self.subTest(result=result_index), self.assertRaises(ValueError):
                gate.verify_native_vectors(value)

    def test_selective_deletion_and_family_replay_markers_cannot_disappear(self):
        for scenario_index, field in ((3, 'variantDeletes'), (3, 'chatTombstones'),
                                      (4, 'familyDeletes'), (4, 'variantDeletes'),
                                      (4, 'chatTombstones')):
            value = self.sample()
            markers = value['scenarios'][scenario_index]['results'][2]['state'][field]
            self.assertTrue(markers)
            markers.pop()
            with self.subTest(scenario=scenario_index, field=field), self.assertRaises(ValueError):
                gate.verify_native_vectors(value)

    def test_malformed_extra_noncanonical_and_wrong_type_fields_are_rejected(self):
        for field, replacement in [('dateBits', '0'), ('dateBits', 'NaN'),
                                   ('dateBits', 0), ('dateBits', True),
                                   ('unexpected', 'ignored')]:
            value = self.sample()
            value['scenarios'][0]['results'][0]['projection'][0][field] = replacement
            with self.subTest(field=field, replacement=replacement), self.assertRaises(ValueError):
                gate.verify_native_vectors(value)
        for replacement in ('01', 1, True, '18446744073709551616'):
            value = self.sample()
            value['scenarios'][0]['inputs'][0]['orderClock'] = replacement
            with self.assertRaises(ValueError):
                gate.verify_native_vectors(value)

    def test_json_parser_rejects_duplicate_keys_nonfinite_values_and_oversize(self):
        for raw in (b'{"format":1,"format":2}', b'{"value":NaN}',
                    b'{"value":Infinity}', b'\xff', b'[' * 1500,
                    b' ' * (gate.MAX_BYTES + 1)):
            with self.subTest(raw=raw[:20]), self.assertRaises(ValueError):
                gate.load_evidence(raw)

    def test_cli_missing_or_malformed_evidence_fails_without_disclosing_content(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'synthetic-not-native.json'
            for raw in (None, b'{"private":"do-not-print-this"}', b'{"x":1,"x":2}'):
                if raw is not None:
                    path.write_bytes(raw)
                result = subprocess.run([sys.executable, '-m', 'scripts.chat_state_v2_interop', str(path)],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertIn('Chat v2 native evidence', result.stderr)
                self.assertNotIn('do-not-print-this', result.stderr)
                self.assertNotIn(str(path), result.stderr)
                self.assertNotIn('Traceback', result.stderr)

    def test_cli_success_route_is_only_a_python_plumbing_test(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'python-plumbing-only.json'
            path.write_text(json.dumps(self.sample()), encoding='utf-8')
            result = subprocess.run([sys.executable, '-m', 'scripts.chat_state_v2_interop', str(path)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('not a wire codec or writer approval', result.stdout)


if __name__ == '__main__':
    unittest.main()
