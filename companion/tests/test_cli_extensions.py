import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from companion.__main__ import main
from companion.core import Memory

class CLIExtensions(unittest.TestCase):
    def call(self, args):
        output = io.StringIO()
        with patch('sys.argv', ['companion', *args]), contextlib.redirect_stdout(output):
            code = main()
        return code, json.loads(output.getvalue())

    def test_generate_plan_does_not_execute(self):
        with tempfile.TemporaryDirectory() as tmp:
            envelope = {'status': 'generated', 'executed': False, 'plan': {'version': 1, 'steps': [], 'write_paths': [], 'budgets': {}}}
            with patch('companion.planner.generate_plan', return_value=envelope) as generate:
                code, data = self.call(['--db', str(Path(tmp)/'memory.db'), 'plan', '--project', 'demo', '--model', 'local-model', '--goal', 'inspect files', '--trust-local-model'])
            self.assertEqual(code, 0)
            self.assertFalse(data['executed'])
            self.assertEqual(generate.call_args.args[:3], ('inspect files','demo','local-model'))

    def test_encrypted_transfer_cli_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            m=Memory(root/'first.db'); m.add('demo', 'remember this', 'manual'); m.close()
            with patch('getpass.getpass', side_effect=['strong test passphrase', 'strong test passphrase']):
                code, data=self.call(['--db', str(root/'first.db'), 'export-memory', '--project', 'demo', '--output', str(root/'notes.veyra')])
            self.assertEqual(code, 0); self.assertEqual(data['exported'], 1)
            with patch('getpass.getpass', return_value='strong test passphrase'):
                code, data=self.call(['--db', str(root/'second.db'), 'import-memory', '--input', str(root/'notes.veyra')])
            self.assertEqual(code, 0); self.assertEqual(data['added'], 1)
