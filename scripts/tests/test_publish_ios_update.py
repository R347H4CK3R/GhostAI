import importlib.util
import plistlib
import tempfile
import json
import os
import subprocess
from unittest import mock
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

class PublishOrchestrationTests(unittest.TestCase):
    def invoke(self, *, tag_exists=False, missing_job=False, existing_build=None, ipa_build="40"):
        run = PublishIOSUpdateTests().run_fixture()
        jobs = [
            {"name": name, "conclusion": "success"}
            for name in ("ios", "ios-pairing-tls-preflight", "android",
                         "desktop-companion (ubuntu-latest)", "desktop-companion (windows-latest)",
                         "desktop-companion (macos-latest)")
        ]
        if missing_job:
            jobs.pop()
        releases = [] if existing_build is None else [{"tag_name": f"ios-build-{existing_build}"}]
        calls = []

        def gh(*args):
            calls.append(args)
            if args[:2] == ("api", f"repos/{publisher.REPOSITORY}/actions/runs/123"):
                return json.dumps(run)
            if args[:3] == ("api", "--paginate", "--slurp"):
                return json.dumps([{"jobs": jobs}] if "/jobs?" in args[-1] else [releases])
            if args[:2] == ("run", "download"):
                folder = Path(args[args.index("--dir") + 1])
                info = {"CFBundleIdentifier": "dev.asterionveyra.assistant",
                        "CFBundleVersion": ipa_build, "CFBundleShortVersionString": "0.3.4",
                        "CFBundleSupportedPlatforms": ["iPhoneOS"]}
                with zipfile.ZipFile(folder / publisher.ASSET, "w") as archive:
                    archive.writestr("Payload/AsterionVeyra.app/Info.plist", plistlib.dumps(info))
                return ""
            if args[:3] == ("api", "--method", "POST"):
                if tag_exists:
                    raise subprocess.CalledProcessError(1, ["gh", *args], stderr="Reference already exists")
                return json.dumps({"ref": "refs/tags/ios-build-40"})
            if args[:2] == ("release", "create"):
                return "https://github.com/R347H4CK3R/GhostAI/releases/tag/ios-build-40"
            self.fail(f"Unexpected external command: {args}")

        environment = {"UPDATE_RUN_ID": "123", "GITHUB_REPOSITORY": publisher.REPOSITORY,
                       "GITHUB_REF_NAME": publisher.BRANCH}
        error = None
        with mock.patch.dict(os.environ, environment), mock.patch.object(publisher, "gh", side_effect=gh):
            try:
                publisher.main()
            except (ValueError, subprocess.CalledProcessError) as caught:
                error = caught
        return calls, error

    def test_publisher_creates_exact_verified_tag_before_release(self):
        calls, error = self.invoke()
        self.assertIsNone(error)
        tag = ("api", "--method", "POST", f"repos/{publisher.REPOSITORY}/git/refs",
               "-f", "ref=refs/tags/ios-build-40", "-f", "sha=" + "a" * 40)
        self.assertIn(tag, calls)
        release = next(call for call in calls if call[:2] == ("release", "create"))
        self.assertLess(calls.index(tag), calls.index(release))
        self.assertIn("--verify-tag", release)
        self.assertNotIn("--target", release)

    def test_any_existing_tag_stops_publication_without_replacement(self):
        calls, error = self.invoke(tag_exists=True)
        self.assertIsInstance(error, subprocess.CalledProcessError)
        self.assertFalse(any(call[:2] == ("release", "create") for call in calls))

    def test_missing_job_existing_release_or_wrong_ipa_never_creates_tag_or_release(self):
        for options in ({"missing_job": True}, {"existing_build": 40},
                        {"existing_build": 41}, {"ipa_build": "39"}):
            with self.subTest(options=options):
                calls, error = self.invoke(**options)
                self.assertIsInstance(error, ValueError)
                self.assertFalse(any(call[:3] == ("api", "--method", "POST") for call in calls))
                self.assertFalse(any(call[:2] == ("release", "create") for call in calls))


if __name__ == "__main__":
    unittest.main()
