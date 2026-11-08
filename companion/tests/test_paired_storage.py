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


class RollbackJournalTests(HostCase):
    def test_registry_retains_precreated_empty_journal_across_connections(self):
        journal = self.state / 'paired.sqlite-journal'
        self.assertTrue(journal.is_file(), 'SQLite must reuse an explicitly owned journal')
        before = journal.stat().st_ino
        for _ in range(2):
            with self.host.transaction() as db:
                self.assertEqual(db.execute('PRAGMA journal_mode').fetchone()[0], 'truncate')
                db.execute("UPDATE metadata SET value=value WHERE key='schema'")
            self.assertEqual(journal.stat().st_size, 0)
            self.assertEqual(journal.stat().st_ino, before)
        self.reopen()
        self.assertEqual(journal.stat().st_ino, before)

    def test_audit_retains_precreated_empty_journal_after_real_tool(self):
        from companion.tests.test_autonomy import plan, read, complete
        import json
        self.enroll(); self.assertEqual(self.request('/v1/jobs/submit', self.submission())[0], 202)
        replies = iter([plan(read()), complete('Synthetic observation.')])
        result = run_next(self.host, transport=lambda _: encoded(dict(done=True, response=json.dumps(next(replies)))))
        self.assertEqual(result['status'], 'completed')
        journal = self.state / 'paired-audit.sqlite-journal'
        self.assertTrue(journal.is_file(), 'audit writes must not recreate a default-owner journal')
        self.assertEqual(journal.stat().st_size, 0)

    def test_wal_database_header_is_refused_before_sqlite_creates_sidecars(self):
        import sqlite3
        from contextlib import closing
        self.host.close()
        with closing(sqlite3.connect(self.host.path)) as db:
            self.assertEqual(db.execute('PRAGMA journal_mode=WAL').fetchone()[0], 'wal')
        before = {p.name: p.read_bytes() for p in self.state.iterdir()}
        with self.assertRaises(ValueError): self.reopen()
        self.assertEqual({p.name: p.read_bytes() for p in self.state.iterdir()}, before)

    def test_crashed_transaction_recovers_with_a_safe_retained_journal(self):
        import json
        import subprocess
        import sys
        self.host.close()
        source = """import json, os, sys
from companion.paired_host import PairedHost
host = PairedHost(sys.argv[1], sys.argv[2], [json.loads(sys.argv[3])])
with host.transaction() as db:
    db.execute('PRAGMA cache_size=1')
    db.execute("UPDATE metadata SET value=? WHERE key='host_id'", ('X' * 20000,))
    os._exit(77)
"""
        result = subprocess.run([sys.executable, '-c', source, str(self.state), self.host.host_id,
                                 json.dumps(self.project)], cwd=Path(__file__).resolve().parents[2],
                                capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 77, result.stderr.decode(errors='replace'))
        journal = self.state / 'paired.sqlite-journal'
        self.assertGreater(journal.stat().st_size, 0)
        self.reopen()
        with self.host.transaction() as db:
            self.assertEqual(db.execute("SELECT value FROM metadata WHERE key='host_id'").fetchone()[0], self.host.host_id)
        self.assertEqual(journal.stat().st_size, 0)
