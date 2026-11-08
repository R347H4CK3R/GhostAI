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
