"""Keep unused immutable-note native results independent and fail closed."""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

from scripts import sync_conformance_ci as ci


class NoteFoundationEvidenceTests(unittest.TestCase):
    def test_notes_require_exactly_twenty_two_passes_and_no_skips(self):
        self.assertIn('ImmutableNoteStateV2Tests', ci.FOUNDATION_COUNTS)
        good = dict(result='Passed', passedTests=22, totalTestCount=22, failedTests=0, skippedTests=0)
        report = ci.foundation_result(good, suite='ImmutableNoteStateV2Tests')
        self.assertTrue(report['passed'])
        self.assertEqual(report['suite'], 'ImmutableNoteStateV2Tests')
        self.assertFalse(report['release_ready'])
        self.assertFalse(ci.foundation_result(good)['passed'])
        self.assertFalse(ci.foundation_result(good, suite='ChatStateV2Tests')['passed'])
        invalid = [None, {}, dict(good, result='Failed'), dict(good, passedTests=21),
                   dict(good, totalTestCount=23), dict(good, failedTests=1), dict(good, skippedTests=1)]
        for field in ('passedTests', 'totalTestCount', 'failedTests', 'skippedTests'):
            invalid.extend(dict(good, **{field: value}) for value in (True, False, float(good[field]), str(good[field])))
        for summary in invalid:
            with self.subTest(summary=summary):
                self.assertFalse(ci.foundation_result(summary, suite='ImmutableNoteStateV2Tests')['passed'])

    def test_notes_cli_retains_success_and_failure_without_writer_approval(self):
        for skipped in (0, 1):
            with self.subTest(skipped=skipped), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); source = root / 'summary.json'; output = root / 'check.json'
                source.write_text(json.dumps(dict(result='Passed', passedTests=22 - skipped,
                                                 totalTestCount=22, failedTests=0, skippedTests=skipped)))
                command = [sys.executable, '-m', 'scripts.sync_conformance_ci', 'check-foundation',
                           '--suite', 'ImmutableNoteStateV2Tests', '--summary', str(source), '--output', str(output)]
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(result.returncode, skipped)
                report = json.loads(output.read_text())
                self.assertEqual(report['passed'], skipped == 0)
                self.assertEqual(report['suite'], 'ImmutableNoteStateV2Tests')
                self.assertFalse(report['release_ready'])

    def test_notes_invocation_and_result_remain_separate_and_bounded(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / '.github/workflows/private-sync-conformance.yml').read_text()
        steps = workflow.split('      - name: ')
        notes = [s for s in steps if '\n        id: note-tests\n' in s]
        self.assertEqual(len(notes), 1)
        for expected in ('-only-testing:AsterionVeyraTests/ImmutableNoteStateV2Tests',
                         '-resultBundlePath build/sync-conformance/ImmutableNotesV2.xcresult',
                         'note-foundation-tests.log', 'timeout-minutes: 15',
                         '-default-test-execution-time-allowance 120',
                         '-maximum-test-execution-time-allowance 180',
                         "always() && steps.simulator.outcome == 'success'"):
            self.assertIn(expected, notes[0])
        checks = [s for s in steps if '\n        id: note-result\n' in s]
        self.assertEqual(len(checks), 1)
        for expected in ('--suite ImmutableNoteStateV2Tests', 'ImmutableNotesV2.xcresult',
                         'note-foundation-summary.json', 'note-foundation-check.json',
                         "always() && steps.note-tests.outcome != 'skipped'", 'timeout-minutes: 2'):
            self.assertIn(expected, checks[0])
        self.assertEqual(len(re.findall(r'func test\w+\(', (root / 'Tests/ImmutableNoteStateV2Tests.swift').read_text())), 22)
        self.assertIn('scripts.tests.test_note_foundation_ci', workflow)
        self.assertNotIn('continue-on-error', workflow)
        self.assertNotIn('|| true', workflow)

    def test_job_budget_reserves_time_for_cleanup_and_evidence_retention(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / '.github/workflows/private-sync-conformance.yml').read_text()
        native = workflow.split('\n  native-seed:\n', 1)[1]
        job_limit = int(re.search(r'^    timeout-minutes: (\d+)$', native, re.M).group(1))
        step_limits = [int(value) for value in re.findall(r'^        timeout-minutes: (\d+)$', native, re.M)]
        self.assertEqual(len(step_limits), 15)
        self.assertGreaterEqual(job_limit, sum(step_limits) + 15,
                                'Reserve setup/upload time beyond all bounded native steps and owned cleanup')


if __name__ == '__main__':
    unittest.main()
