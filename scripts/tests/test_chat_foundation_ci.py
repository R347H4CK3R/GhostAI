"""Independent native chat suite and cross-language evidence gate invariants."""
import inspect
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from scripts import sync_conformance_ci as ci

CHAT_FORMAT = 'veyra-chat-state-v2-projection-evidence-v1'


class ChatFoundationEvidenceTests(unittest.TestCase):
    def test_chat_requires_exactly_eighteen_native_passes(self):
        self.assertIn('suite', inspect.signature(ci.foundation_result).parameters)
        good = dict(result='Passed', passedTests=18, totalTestCount=18, failedTests=0, skippedTests=0)
        report = ci.foundation_result(good, suite='ChatStateV2Tests')
        self.assertTrue(report['passed'])
        self.assertEqual(report['suite'], 'ChatStateV2Tests')
        self.assertFalse(report['release_ready'])
        self.assertFalse(ci.foundation_result(good)['passed'])
        for bad in [dict(good, passedTests=17), dict(good, totalTestCount=19),
                    dict(good, skippedTests=1), dict(good, failedTests=1), dict(good, result='Failed'),
                    dict(good, failedTests=False), dict(good, passedTests=18.0)]:
            with self.subTest(summary=bad):
                self.assertFalse(ci.foundation_result(bad, suite='ChatStateV2Tests')['passed'])
        with self.assertRaises(ValueError):
            ci.foundation_result(good, suite='UnknownTests')

    def test_chat_cli_reports_its_own_suite_and_never_release_approval(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root / 'summary.json'; output = root / 'check.json'
            source.write_text(json.dumps(dict(result='Passed', passedTests=18, totalTestCount=18,
                                             failedTests=0, skippedTests=0)))
            command = [sys.executable, '-m', 'scripts.sync_conformance_ci', 'check-foundation',
                       '--suite', 'ChatStateV2Tests', '--summary', str(source), '--output', str(output)]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0)
            report = json.loads(output.read_text())
            self.assertTrue(report['passed'])
            self.assertEqual(report['suite'], 'ChatStateV2Tests')
            self.assertFalse(report['release_ready'])

    def test_native_chat_attachment_selection_does_not_accept_legacy_format(self):
        self.assertIn('expected_format', inspect.signature(ci.select_export).parameters)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); attachments = root / 'attachments'; attachments.mkdir()
            output = root / 'chat.json'
            (attachments / 'legacy.json').write_text(json.dumps(dict(format=ci.FORMAT, status='native-export')))
            with self.assertRaises(ValueError):
                ci.select_export(attachments, output, expected_format=CHAT_FORMAT)
            raw = json.dumps(dict(format=CHAT_FORMAT, status='native-export')).encode()
            (attachments / 'opaque.json').write_bytes(raw)
            ci.select_export(attachments, output, expected_format=CHAT_FORMAT)
            self.assertEqual(output.read_bytes(), raw)
            with self.assertRaises(ValueError):
                ci.select_export(attachments, root / 'other.json', expected_format='unreviewed-format')

    def test_workflow_keeps_chat_native_and_cross_language_results_separate(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / '.github/workflows/private-sync-conformance.yml').read_text()
        steps = workflow.split('      - name: ')
        chat = [step for step in steps if '\n        id: chat-tests\n' in step]
        self.assertEqual(len(chat), 1)
        self.assertIn('-only-testing:AsterionVeyraTests/ChatStateV2Tests', chat[0])
        self.assertIn('-resultBundlePath build/sync-conformance/ChatStateV2.xcresult', chat[0])
        self.assertIn("always() && steps.simulator.outcome == 'success'", chat[0])
        check = next(step for step in steps if '\n        id: chat-result\n' in step)
        self.assertIn('--suite ChatStateV2Tests', check)
        self.assertIn('chat-foundation-summary.json', check)
        self.assertIn('chat-foundation-check.json', check)
        self.assertIn("always() && steps.chat-tests.outcome != 'skipped'", check)
        self.assertIn('python -m scripts.chat_state_v2_interop', workflow)
        self.assertIn('--format ' + CHAT_FORMAT, workflow)
        self.assertIn('chat-native-export.json', workflow)
        self.assertIn('scripts.tests.test_chat_foundation_ci', workflow)
        self.assertNotIn('continue-on-error', workflow)
        self.assertNotIn('|| true', workflow)
        self.assertEqual(len(__import__('re').findall(r'func test\w+\(',
                            (root / 'Tests/ChatStateV2Tests.swift').read_text())), 18)


if __name__ == '__main__':
    unittest.main()
