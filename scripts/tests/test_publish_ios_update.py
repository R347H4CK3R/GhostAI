import importlib.util
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("publish_ios_update", Path(__file__).parents[1] / "publish_ios_update.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)

class PublishIOSUpdateTests(unittest.TestCase):
    def run_fixture(self):
        return {
            "repository": {"full_name": publisher.REPOSITORY},
            "head_repository": {"full_name": publisher.REPOSITORY},
            "head_branch": publisher.BRANCH, "path": ".github/workflows/ios.yml",
            "event": "push", "status": "completed", "conclusion": "success",
            "head_sha": "a" * 40, "run_number": 40,
        }

    def test_only_completed_successful_release_branch_run(self):
        self.assertEqual(publisher.validate_run(self.run_fixture()), 40)
        for key, value in [
            ("head_branch", "main"), ("event", "pull_request"), ("conclusion", "failure"),
            ("status", "in_progress"), ("path", ".github/workflows/other.yml"),
            ("head_sha", "bad"), ("run_number", True),
            ("head_repository", {"full_name": "other/fork"}),
        ]:
            with self.subTest(key=key):
                run = self.run_fixture()
                run[key] = value
                with self.assertRaises(ValueError):
                    publisher.validate_run(run)

    def test_ipa_must_match_build_bundle_and_platform(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app.ipa"
            good = {
                "CFBundleIdentifier": "dev.asterionveyra.assistant",
                "CFBundleVersion": "40", "CFBundleShortVersionString": "0.3.3",
                "CFBundleSupportedPlatforms": ["iPhoneOS"],
            }
            def write(info):
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr("Payload/AsterionVeyra.app/Info.plist", plistlib.dumps(info))
            write(good)
            self.assertEqual(publisher.validate_ipa(path, 40), good)
            for key, value in [
                ("CFBundleVersion", "39"), ("CFBundleIdentifier", "other.app"),
                ("CFBundleSupportedPlatforms", ["iPhoneSimulator"]),
            ]:
                write(dict(good, **{key: value}))
                with self.assertRaises(ValueError):
                    publisher.validate_ipa(path, 40)

if __name__ == "__main__":
    unittest.main()
