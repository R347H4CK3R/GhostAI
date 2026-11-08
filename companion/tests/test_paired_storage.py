"""Paired storage failures stop before writing checkpoints or acceptance state."""
import os
from pathlib import Path
import unittest
from companion.paired_jobs import run_next
from companion.tests.test_paired_host import HostCase, encoded


@unittest.skipIf(os.name == 'nt', 'native Windows DACL cases are in test_paired_windows_storage')
class DirectoryBoundaryTests(HostCase):
    def test_directory_weakening_during_model_call_does_not_write_checkpoint(self):
        self.enroll()
        self.assertEqual(self.request('/v1/jobs/submit', self.submission())[0], 202)
        before = {}
        def respond(_):
            before.update({p.name: p.read_bytes() for p in self.state.iterdir()})
            self.state.chmod(0o755)
            return encoded(dict(done=True, response='{"action":"complete","summary":"Synthetic"}'))
        try:
            with self.assertRaises(ValueError):
                run_next(self.host, transport=respond)
            self.assertEqual({p.name: p.read_bytes() for p in self.state.iterdir()}, before)
        finally:
            self.state.chmod(0o700)
