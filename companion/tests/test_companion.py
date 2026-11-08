import importlib.util
import json
import tempfile
import subprocess
import sys
import threading
import unittest
from pathlib import Path

SPEC = importlib.util.find_spec('companion.core')
if SPEC:
    from companion.core import Memory, Runner, PlanError, load_plan

class CompanionTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(SPEC, 'offline companion implementation missing')
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        # Resolve trusted OS temp ancestors (macOS /var commonly links to /private/var).
        # Production Runner must continue rejecting symlinked workspace paths.
        self.root = Path(self.temp.name).resolve()
        self.workspace = self.root / 'work'
        self.workspace.mkdir()
        self.memory = Memory(self.root / 'memory.sqlite')
        self.addCleanup(self.memory.close)

    def plan(self, steps, writes=None, **budgets):
        return {'version': 1, 'steps': steps, 'write_paths': writes or [], 'budgets': budgets}

    def run_plan(self, plan, **kwargs):
        return Runner(self.workspace, self.memory, **kwargs).run(plan)

    def test_memory_persistence_search_provenance_delete(self):
        ident = self.memory.add('project', 'Offline café requirements', 'user:explicit')
        other = Memory(self.root / 'memory.sqlite')
        try:
            rows = other.search('project', 'café')
            self.assertEqual(rows[0]['id'], ident)
            self.assertEqual(rows[0]['source'], 'user:explicit')
            self.assertEqual(other.search('another', ''), [])
            self.assertTrue(other.delete(ident))
            self.assertEqual(other.search('project', ''), [])
        finally:
            other.close()

    def test_memory_rejects_credential_patterns(self):
        for secret in ['ghp_abcdefgh', 'github_pat_abc', '-----BEGIN PRIVATE KEY-----',
                       'password = hidden', 'api_key: hidden', 'access_token=hidden', 'secret: hidden']:
            for position in range(3):
                args = ['project', 'ordinary note', 'user:explicit']
                args[position] = secret
                with self.subTest(secret=secret, position=position):
                    with self.assertRaises(ValueError):
                        self.memory.add(*args)
        self.assertEqual(self.memory.search('project', ''), [])

    def test_registered_read_tools(self):
        (self.workspace / 'a.json').write_text('{"ok":true}')
        steps = [{'tool': tool, 'path': 'a.json'} for tool in ['read_file', 'validate_json', 'sha256']]
        steps.append({'tool': 'list_files', 'path': '.'})
        result = self.run_plan(self.plan(steps))
        self.assertEqual(result['status'], 'completed')
        self.assertEqual(result['results'][0], '{"ok":true}')
        self.assertTrue(result['results'][1]['valid'])
        self.assertEqual(len(result['results'][2]), 64)
        self.assertEqual(result['results'][3], ['a.json'])
        self.assertEqual(self.memory.tasks()[0]['status'], 'completed')

    def test_writes_require_flag_and_exact_scope(self):
        step = {'tool': 'write_draft', 'path': 'draft.txt', 'content': 'hello'}
        for kwargs, scope in [({}, ['draft.txt']), ({'allow_writes': True}, ['other.txt'])]:
            result = self.run_plan(self.plan([step], scope), **kwargs)
            self.assertEqual(result['status'], 'failed')
            self.assertFalse((self.workspace / 'draft.txt').exists())
        result = self.run_plan(self.plan([step], ['draft.txt']), allow_writes=True)
        self.assertEqual(result['status'], 'completed')
        self.assertEqual((self.workspace / 'draft.txt').read_text(), 'hello')
        self.assertEqual(self.run_plan(self.plan([step], ['draft.txt']), allow_writes=True)['status'], 'failed')

    def test_path_traversal_rejected(self):
        for path in ['../secret', '/etc/passwd', 'C:/secret', 'a/../b', 'a\\b', '', '//server/x']:
            with self.subTest(path=path):
                self.assertEqual(self.run_plan(self.plan([{'tool': 'read_file', 'path': path}]))['status'], 'failed')

    def test_windows_device_names_rejected(self):
        step = {'tool': 'write_draft', 'path': 'NUL.txt', 'content': 'x'}
        self.assertEqual(self.run_plan(self.plan([step], ['NUL.txt']), allow_writes=True)['status'], 'failed')
        self.assertFalse((self.workspace / 'NUL.txt').exists())

    def test_entry_and_cumulative_byte_budgets(self):
        (self.workspace / 'a').write_text('abcd')
        (self.workspace / 'b').write_text('abcd')
        self.assertEqual(self.run_plan(self.plan([{'tool': 'list_files', 'path': '.'}], max_entries=1))['status'], 'failed')
        result = self.run_plan(self.plan([{'tool': 'read_file', 'path': 'a'}, {'tool': 'read_file', 'path': 'b'}], max_bytes=6))
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['results'], ['abcd'])

    def test_symlinks_rejected(self):
        outside = self.root / 'secret'
        outside.write_text('secret')
        try:
            (self.workspace / 'link').symlink_to(outside)
            (self.workspace / 'dir').symlink_to(self.root, target_is_directory=True)
        except OSError:
            self.skipTest('symlink creation unavailable to this account')
        for path in ['link', 'dir/secret']:
            self.assertEqual(self.run_plan(self.plan([{'tool': 'read_file', 'path': path}]))['status'], 'failed')
        step = {'tool': 'write_draft', 'path': 'dir/new', 'content': 'bad'}
        self.assertEqual(self.run_plan(self.plan([step], ['dir/new']), allow_writes=True)['status'], 'failed')

    def test_budgets_cancel_and_audit(self):
        (self.workspace / 'large').write_text('123456')
        result = self.run_plan(self.plan([{'tool': 'read_file', 'path': 'large'}], max_bytes=5))
        self.assertEqual(result['status'], 'failed')
        steps = [{'tool': 'list_files', 'path': '.'}] * 2
        self.assertEqual(self.run_plan(self.plan(steps, max_steps=1))['status'], 'failed')
        cancelled = threading.Event(); cancelled.set()
        self.assertEqual(self.run_plan(self.plan(steps), cancel=cancelled)['status'], 'cancelled')
        self.assertEqual(len(self.memory.tasks()), 3)

    def test_validation_is_fail_closed_before_writes(self):
        valid = {'tool': 'write_draft', 'path': 'draft', 'content': 'x'}
        bad_plans = [self.plan([valid, {'tool': 'shell', 'path': 'x'}], ['draft']),
                     self.plan([{'tool': 'read_file', 'path': 'x', 'extra': True}]),
                     self.plan([], max_steps=True), self.plan([], surprise=1),
                     dict(self.plan([]), extra=1), dict(self.plan([]), version=True)]
        for plan in bad_plans:
            self.assertEqual(self.run_plan(plan, allow_writes=True)['status'], 'failed')
        self.assertFalse((self.workspace / 'draft').exists())
        for raw in ['{"version":1,"version":1}', '{"x":NaN}']:
            with self.assertRaises(PlanError):
                load_plan(raw)

class CLITests(unittest.TestCase):
    def test_cli_memory_and_plan(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            database = root / 'memory.sqlite'
            def cli(*args):
                return subprocess.run([sys.executable, '-m', 'companion', '--db', str(database), *args], text=True, capture_output=True)
            added = cli('remember', '--project', 'demo', '--source', 'user', '--text', 'offline note')
            self.assertEqual(added.returncode, 0, added.stderr)
            ident = json.loads(added.stdout)['id']
            self.assertEqual(len(json.loads(cli('search', '--project', 'demo', '--query', 'note').stdout)), 1)
            self.assertTrue(json.loads(cli('forget', ident).stdout)['deleted'])
            work = root / 'work'; work.mkdir()
            plan = root / 'plan.json'
            plan.write_text(json.dumps({'version': 1, 'steps': [{'tool': 'list_files', 'path': '.'}], 'write_paths': [], 'budgets': {}}))
            ran = cli('run', '--workspace', str(work), '--plan', str(plan))
            self.assertEqual(ran.returncode, 0, ran.stderr)
            self.assertEqual(json.loads(ran.stdout)['status'], 'completed')
            self.assertEqual(len(json.loads(cli('history').stdout)), 1)

if __name__ == '__main__':
    unittest.main()
