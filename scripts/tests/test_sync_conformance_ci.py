"""CI artifact selection and exact-source provenance, with real local Git repos."""
import json
from pathlib import Path
import subprocess
import tempfile
import sys
import unittest

from scripts import sync_conformance_ci as ci


class ExportSelectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.attachments = self.root / 'attachments'; self.attachments.mkdir()
        self.output = self.root / 'native-export.json'
        # Selector plumbing only. The separate native gate must reject this incomplete object.
        self.raw = b'{"format":"veyra-private-sync-interop-v1","status":"native-export"}\n'

    def test_opaque_attachment_filename_is_selected_and_preserved_exactly(self):
        (self.attachments / 'manifest.json').write_text('[{"exportedFileName":"opaque.data"}]')
        (self.attachments / 'opaque.data').write_bytes(self.raw)
        result = ci.select_export(self.attachments, self.output)
        self.assertEqual(self.output.read_bytes(), self.raw)
        self.assertEqual(result['attachment'], 'opaque.data')
        self.assertEqual(result['bytes'], len(self.raw))
        self.assertEqual(len(result['sha256']), 64)

    def test_missing_or_multiple_candidates_never_create_an_output(self):
        with self.assertRaises(ValueError):
            ci.select_export(self.attachments, self.output)
        (self.attachments / 'one').write_bytes(self.raw)
        (self.attachments / 'two').write_bytes(self.raw)
        with self.assertRaises(ValueError):
            ci.select_export(self.attachments, self.output)
        self.assertFalse(self.output.exists())

    def test_pending_and_invalid_json_never_substitute_for_a_native_export(self):
        (self.attachments / 'pending').write_text('{"format":"veyra-private-sync-interop-v1","status":"pending-native-export"}')
        (self.attachments / 'invalid').write_text('{')
        with self.assertRaises(ValueError):
            ci.select_export(self.attachments, self.output)
        self.assertFalse(self.output.exists())

    def test_does_not_overwrite_prior_evidence(self):
        (self.attachments / 'one').write_bytes(self.raw)
        self.output.write_text('preserve existing evidence')
        with self.assertRaises(FileExistsError):
            ci.select_export(self.attachments, self.output)
        self.assertEqual(self.output.read_text(), 'preserve existing evidence')

    @unittest.skipIf(__import__('os').name == 'nt', 'symlink creation requires Windows developer privileges')
    def test_linked_attachments_fail_without_following_the_link(self):
        outside = self.root / 'outside'; outside.write_bytes(self.raw)
        (self.attachments / 'linked').symlink_to(outside)
        with self.assertRaises(ValueError):
            ci.select_export(self.attachments, self.output)
        self.assertFalse(self.output.exists())


class FoundationEvidenceTests(unittest.TestCase):
    def test_foundation_requires_fourteen_passes_without_skips_or_failures(self):
        check = getattr(ci, 'foundation_result', None)
        self.assertTrue(callable(check), 'An independent native foundation result is required')
        good = dict(result='Passed', passedTests=14, totalTestCount=14, failedTests=0, skippedTests=0)
        result = check(good)
        self.assertTrue(result['passed'])
        self.assertFalse(result['release_ready'])
        self.assertEqual(result['suite'], 'KnowledgeSyncJoinTests')
        invalid = [None, {}, dict(good, result='Failed'), dict(good, passedTests=13),
                   dict(good, totalTestCount=15), dict(good, failedTests=1), dict(good, skippedTests=1)]
        for field in ('passedTests', 'totalTestCount', 'failedTests', 'skippedTests'):
            invalid += [dict(good, **{field: True}), dict(good, **{field: False}),
                        dict(good, **{field: float(good[field])}), dict(good, **{field: str(good[field])})]
        for summary in invalid:
            with self.subTest(summary=summary):
                self.assertFalse(check(summary)['passed'])

    def test_foundation_cli_retains_a_failed_independent_result(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root / 'summary.json'; output = root / 'check.json'
            source.write_text(json.dumps(dict(result='Passed', passedTests=13, totalTestCount=14,
                                             failedTests=0, skippedTests=1)))
            result = subprocess.run([sys.executable, '-m', 'scripts.sync_conformance_ci',
                                     'check-foundation', '--summary', str(source), '--output', str(output)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertTrue(output.is_file(), 'Failed foundation evidence must be retained')
            report = json.loads(output.read_text())
            self.assertFalse(report['passed'])
            self.assertFalse(report['release_ready'])
            self.assertEqual(report['counts']['skippedTests'], 1)

    def test_foundation_cli_success_is_still_not_release_approval(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root / 'summary.json'; output = root / 'check.json'
            source.write_text(json.dumps(dict(result='Passed', passedTests=14, totalTestCount=14,
                                             failedTests=0, skippedTests=0)))
            result = subprocess.run([sys.executable, '-m', 'scripts.sync_conformance_ci',
                                     'check-foundation', '--summary', str(source), '--output', str(output)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0)
            report = json.loads(output.read_text())
            self.assertTrue(report['passed'])
            self.assertFalse(report['release_ready'])
            self.assertIn('blocked', report['legacy_convergence'])

    def test_workflow_keeps_foundation_and_legacy_results_independent(self):
        # Standard-library-only invariant, also executed in the Windows portable suite.
        root = Path(__file__).resolve().parents[2]
        workflow = (root / '.github/workflows/private-sync-conformance.yml').read_text()
        foundation = '-only-testing:AsterionVeyraTests/KnowledgeSyncJoinTests'
        self.assertIn(foundation, workflow)
        self.assertEqual(workflow.count(foundation), 1)
        self.assertIn('-only-testing:AsterionVeyraTests/PrivateMemorySyncInteropTests/testExportSyntheticNativeGoldenVectors', workflow)
        self.assertIn('-resultBundlePath build/sync-conformance/KnowledgeJoin.xcresult', workflow)
        self.assertIn('-resultBundlePath build/sync-conformance/SyncInterop.xcresult', workflow)
        self.assertIn('get test-results summary --path build/sync-conformance/KnowledgeJoin.xcresult', workflow)
        self.assertIn('check-foundation', workflow)
        self.assertIn("always() && steps.simulator.outcome == 'success'", workflow)
        self.assertIn("always() && steps.foundation-tests.outcome != 'skipped'", workflow)
        self.assertIn('seven known divergences', workflow)
        self.assertNotIn('continue-on-error', workflow)
        self.assertNotIn('|| true', workflow)
        self.assertEqual(workflow.count('CODE_SIGNING_ALLOWED=NO'), 2)
        steps = workflow.split('      - name: ')
        foundation_step = next(step for step in steps if '\n        id: foundation-tests\n' in step)
        result_step = next(step for step in steps if '\n        id: foundation-result\n' in step)
        legacy_step = next(step for step in steps if '\n        id: native-tests\n' in step)
        self.assertIn(foundation, foundation_step)
        self.assertNotIn('PrivateMemorySyncInteropTests', foundation_step)
        self.assertIn('KnowledgeJoin.xcresult', foundation_step)
        self.assertIn("always() && steps.foundation-tests.outcome != 'skipped'", result_step)
        self.assertIn('check-foundation', result_step)
        self.assertIn("always() && steps.simulator.outcome == 'success'", legacy_step)
        self.assertNotIn('KnowledgeSyncJoinTests', legacy_step)
        self.assertIn('SyncInterop.xcresult', legacy_step)
        self.assertEqual(len(__import__('re').findall(r'func test\w+\(',
                            (root / 'Tests/KnowledgeSyncJoinTests.swift').read_text())), 14)


class ProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Synthetic CI')
        self.git('config', 'user.email', 'ci@example.invalid')
        (self.root / 'tracked.txt').write_text('original\n')
        self.git('add', 'tracked.txt'); self.git('commit', '-qm', 'Synthetic baseline')
        self.sha = self.git('rev-parse', 'HEAD').strip()

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.root, text=True, check=True,
                              capture_output=True).stdout

    def test_records_exact_sha_tree_and_empty_tracked_diff(self):
        report = ci.provenance(self.root, self.sha)
        self.assertEqual(report['source_sha'], self.sha)
        self.assertEqual(report['expected_sha'], self.sha)
        self.assertEqual(report['source_tree'], self.git('rev-parse', 'HEAD^{tree}').strip())
        self.assertEqual(report['tracked_diff_summary'], '')
        self.assertEqual(report['tracked_diff_name_status'], '')
        self.assertTrue(report['source_verified'])
        self.assertFalse(report['release_ready'])

    def test_staged_and_unstaged_changes_are_reported_not_hidden_by_untracked_files(self):
        (self.root / 'tracked.txt').write_text('changed\n')
        (self.root / 'generated.log').write_text('untracked build output\n')
        report = ci.provenance(self.root, self.sha)
        self.assertFalse(report['source_verified'])
        self.assertIn('tracked.txt', report['tracked_diff_summary'])
        self.assertIn('M\ttracked.txt', report['tracked_diff_name_status'])
        self.git('add', 'tracked.txt')
        staged = ci.provenance(self.root, self.sha)
        self.assertFalse(staged['source_verified'])
        self.assertIn('tracked.txt', staged['tracked_diff_summary'])

    def test_opposing_staged_and_unstaged_changes_do_not_cancel_cleanliness(self):
        (self.root / 'tracked.txt').write_text('staged change\n')
        self.git('add', 'tracked.txt')
        (self.root / 'tracked.txt').write_text('original\n')
        report = ci.provenance(self.root, self.sha)
        self.assertFalse(report['source_verified'])
        self.assertIn('MM tracked.txt', report['tracked_status'])
        self.assertIn('tracked.txt', report['staged_diff_summary'])
        self.assertIn('tracked.txt', report['unstaged_diff_summary'])

    def test_untracked_artifacts_do_not_claim_tracked_source_changed(self):
        (self.root / 'generated.log').write_text('synthetic build output\n')
        self.assertTrue(ci.provenance(self.root, self.sha)['source_verified'])

    def test_cli_retains_failed_provenance_and_returns_nonzero(self):
        output = self.root / 'failure.json'
        result = subprocess.run([sys.executable, '-m', 'scripts.sync_conformance_ci', 'provenance',
                                 '--root', str(self.root), '--expected-sha', '0' * 40,
                                 '--output', str(output)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        report = json.loads(output.read_text())
        self.assertEqual(report['source_sha'], self.sha)
        self.assertFalse(report['source_verified'])
        self.assertEqual(report['tracked_diff_summary'], '')

    def test_wrong_or_nonexact_sha_cannot_be_verified(self):
        self.assertFalse(ci.provenance(self.root, '0' * 40)['source_verified'])
        with self.assertRaises(ValueError):
            ci.provenance(self.root, self.sha[:7])


if __name__ == '__main__':
    unittest.main()
