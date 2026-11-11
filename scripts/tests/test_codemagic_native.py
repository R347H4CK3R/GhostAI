import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

PATH = Path(__file__).resolve().parents[2] / 'ci/codemagic_native.py'

class NativeHarnessTests(unittest.TestCase):
    def module(self):
        self.assertTrue(PATH.exists(), 'native harness must exist')
        spec = importlib.util.spec_from_file_location('native', PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_failure_is_preserved_and_cleanup_runs(self):
        m = self.module()
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            steps = [{'name':'fail','script':'exit 7','seconds':2},
                     {'name':'skipped','script':'touch wrong','seconds':2},
                     {'name':'cleanup','script':'touch cleaned','seconds':2,'always':True}]
            self.assertFalse(m.execute(steps, root, root / 'evidence'))
            self.assertFalse((root / 'wrong').exists())
            self.assertTrue((root / 'cleaned').exists())
            report=json.loads((root/'evidence/stages.json').read_text())
            self.assertEqual([s['status'] for s in report], ['failed','skipped','passed'])

    def test_timeout_fails_and_retains_log(self):
        m = self.module()
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            self.assertFalse(m.execute([{'name':'timeout','script':'echo evidence; sleep 10','seconds':0.1}], root, root/'evidence'))
            self.assertIn('evidence', (root/'evidence/01-bash.log').read_text())

    def test_dependency_diagnostic_runs_after_other_failure(self):
        m=self.module()
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            stages=[{'name':'compile','script':'true','seconds':2}, {'name':'fail','script':'false','seconds':2},
                    {'name':'privacy','script':'touch diagnostic','seconds':2,'after_success':'compile'}]
            self.assertFalse(m.execute(stages,root,root/'evidence'))
            self.assertTrue((root/'diagnostic').exists())

    def test_pins_and_deadlines(self):
        m=self.module()
        self.assertEqual(m.SHA,'edafbcfae9eb4e97ccb491b63ad23d6655cc9747')
        self.assertEqual(m.TREE,'c8ccab3d141eb85fe3484a1749fc5275b89c70ad')
        plans=json.loads((PATH.parent/'codemagic_stages.json').read_text())
        native={s['name']:s for s in plans['native']}
        self.assertEqual(native['Compile simulator test bundles']['seconds'],1500)
        self.assertEqual(native['Unit tests']['seconds'],2700)
        self.assertNotIn('-only-testing',native['Unit tests']['script'])
        for name in ['Reduced checklist lifecycle controls','Checklist interaction regressions','Checklist privacy visual evidence']:
            self.assertIn(name,native)

    def test_cleanup_failure_blocks_success(self):
        m=self.module()
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            self.assertFalse(m.execute([{'name':'gate','script':'true','seconds':2}, {'name':'cleanup','script':'false','seconds':2,'always':True}],root,root/'evidence'))

    def test_rejects_wrong_source_identity(self):
        m=self.module()
        with self.assertRaises(ValueError):
            m.SHA = '0' * 40
            m.verify_source(PATH.parents[1])

    def test_nested_session_timeout_cleans_child_and_writes_receipt(self):
        import os
        import shlex
        m=self.module()
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            entry=root/'entry.py'
            entry.write_text("""import json,sys
from pathlib import Path
sys.path.insert(0, %r)
from verify_simulator_upgrade import Runner
out=Path('output'); out.mkdir()
r=Runner(out,100)
try:
 r.run([sys.executable,'-c',\"import os,time; from pathlib import Path; Path('child.pid').write_text(str(os.getpid())); time.sleep(60)\"],cwd=Path.cwd(),timeout=60)
except KeyboardInterrupt:
 pass
finally:
 (out/'result.json').write_text(json.dumps({'status':'failed','commands':r.steps}))
""" % str(PATH.parents[1]/'scripts'))
            wrapper=PATH.parent/'codemagic_entry.py'
            script='exec '+shlex.join([sys.executable,str(wrapper),str(entry),'--receipt',str(root/'receipt.json'),'--result',str(root/'output/result.json')])
            import signal
            import threading
            timer = None
            prior = signal.getsignal(signal.SIGTERM)
            if getattr(self, 'send_sigterm', False):
                def interrupted(signum, frame):
                    raise KeyboardInterrupt('SIGTERM regression')
                signal.signal(signal.SIGTERM, interrupted)
                timer = threading.Timer(1, lambda: os.kill(os.getpid(), signal.SIGTERM))
                timer.start()
            try:
                self.assertFalse(m.execute([{'name':'nested','script':script,'seconds':30 if timer else 1,'cooperative':True,'receipt':str(root/'receipt.json')}],root,root/'evidence'))
                self.assertTrue((root/'child.pid').exists(), 'nested process must actually start')
                pid=int((root/'child.pid').read_text())
                with self.assertRaises(ProcessLookupError): os.kill(pid,0)
                self.assertTrue(json.loads((root/'receipt.json').read_text())['cleanup_complete'])
            finally:
                if timer: timer.cancel()
                signal.signal(signal.SIGTERM, prior)
                if (root/'child.pid').exists():
                    try: os.kill(int((root/'child.pid').read_text()),9)
                    except ProcessLookupError: pass

    def test_nested_session_sigterm_cleans_child_and_writes_receipt(self):
        self.send_sigterm = True
        self.test_nested_session_timeout_cleans_child_and_writes_receipt()

    def test_missing_cleanup_receipt_blocks_success(self):
        m=self.module()
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            self.assertFalse(m.execute([{'name':'fake-success','script':'true','seconds':2,'receipt':str(root/'missing.json')}],root,root/'evidence'))

    def test_upgrade_cleanup_receipt_requires_deleted_owned_simulator(self):
        spec=importlib.util.spec_from_file_location('entry', PATH.parent/'codemagic_entry.py')
        entry=importlib.util.module_from_spec(spec); spec.loader.exec_module(entry)
        result={'commands':[{'exit_code':0}], 'simulator_id':'owned'}
        self.assertFalse(entry.cleanup_complete(result,True))
        result['isolated_simulator_deleted']=True
        self.assertTrue(entry.cleanup_complete(result,True))
        result['commands'][0]['exit_code']=None
        self.assertFalse(entry.cleanup_complete(result,True))
