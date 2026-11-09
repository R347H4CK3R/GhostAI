import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(SCRIPTS))
import verify_simulator_upgrade as upgrade

class BaselineTests(unittest.TestCase):
    def test_original_baseline_default_is_unchanged(self):
        self.assertTrue(hasattr(upgrade,'DEFAULT_BASELINE'), 'explicit baseline contract is required')
        self.assertEqual(upgrade.DEFAULT_BASELINE,('8074b807a864a79e659200ee9521141c3c00df98','0.3.0','17'))
    def test_exact_live_baseline_is_allowed(self):
        self.assertTrue(hasattr(upgrade,'validate_baseline'), 'baseline validation is required')
        self.assertEqual(upgrade.validate_baseline(('59aa7329efa87ce01b247ca309941c20b2e3dc8d','0.3.6','44')),('59aa7329efa87ce01b247ca309941c20b2e3dc8d','0.3.6','44'))
    def test_unknown_or_mismatched_baseline_fails_closed(self):
        self.assertTrue(hasattr(upgrade,'validate_baseline'), 'baseline validation is required')
        for baseline in [('a'*40,'0.3.6','44'),('59aa7329efa87ce01b247ca309941c20b2e3dc8d','0.3.0','17'),('main','0.3.6','44'),('59aa7329efa87ce01b247ca309941c20b2e3dc8d','0.3.6',44)]:
            with self.subTest(baseline=baseline),self.assertRaises(ValueError): upgrade.validate_baseline(baseline)
    def test_wrapper_pins_live_baseline_without_changing_original_default(self):
        path=SCRIPTS/'jarvis_verify_upgrade.py'
        self.assertTrue(path.exists(),'Jarvis upgrade wrapper required')
        spec=importlib.util.spec_from_file_location('jarvis_upgrade',path)
        wrapper=importlib.util.module_from_spec(spec);spec.loader.exec_module(wrapper)
        with patch.object(upgrade,'main',return_value=7) as main:
            self.assertEqual(wrapper.main(['--output','test-output']),7)
            main.assert_called_once_with(['--output','test-output'],baseline=('59aa7329efa87ce01b247ca309941c20b2e3dc8d','0.3.6','44'))
        self.assertEqual(upgrade.DEFAULT_BASELINE,('8074b807a864a79e659200ee9521141c3c00df98','0.3.0','17'))
    def test_baseline_metadata_mismatch_and_candidate_downgrade_rejected(self):
        self.assertTrue(hasattr(upgrade,'validate_upgrade_versions'),'metadata validation required')
        baseline=('59aa7329efa87ce01b247ca309941c20b2e3dc8d','0.3.6','44')
        upgrade.validate_upgrade_versions({'version':'0.3.6','build':'44'},{'version':'0.4.0'},baseline)
        for old,new in [({'version':'0.3.0','build':'44'},'0.4.0'),({'version':'0.3.6','build':'17'},'0.4.0'),({'version':'0.3.6','build':'44'},'0.3.6'),({'version':'0.3.6','build':'44'},'0.3.5')]:
            with self.subTest(old=old,new=new),self.assertRaises(ValueError):upgrade.validate_upgrade_versions(old,{'version':new},baseline)

if __name__=='__main__':unittest.main()
