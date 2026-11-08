#!/usr/bin/env python3
"""Publish only an existing successful, same-repository iOS CI artifact."""
import json
import os
import plistlib
import re
import subprocess
import tempfile
import zipfile
from pathlib import Path

REPOSITORY = "R347H4CK3R/GhostAI"
BRANCH = "feature/paired-execution-protocol"
ASSET = "AsterionVeyra-unsigned.ipa"

def gh(*args):
    return subprocess.check_output(["gh", *args], text=True)

def validate_run(run):
    if (run.get("repository", {}).get("full_name") != REPOSITORY
            or run.get("head_repository", {}).get("full_name") != REPOSITORY
            or run.get("head_branch") != BRANCH
            or run.get("path") != ".github/workflows/ios.yml"
            or run.get("event") not in ("push", "workflow_dispatch")
            or run.get("status") != "completed"
            or run.get("conclusion") != "success"
            or not re.fullmatch(r"[0-9a-f]{40}", run.get("head_sha", ""))
            or type(run.get("run_number")) is not int
            or run["run_number"] <= 0):
        raise ValueError("Run is not a successful release-branch iOS build")
    return run["run_number"]

def validate_ipa(path, build):
    if not 0 < path.stat().st_size <= 536_870_912:
        raise ValueError("IPA size outside bounds")
    with zipfile.ZipFile(path) as archive:
        target = "Payload/AsterionVeyra.app/Info.plist"
        entries = [entry for entry in archive.infolist() if entry.filename == target]
        if len(entries) != 1 or entries[0].file_size > 1_048_576:
            raise ValueError("IPA has no unique bounded app metadata")
        info = plistlib.loads(archive.read(entries[0]))
    if (info.get("CFBundleIdentifier") != "dev.asterionveyra.assistant"
            or info.get("CFBundleVersion") != str(build)
            or "iPhoneOS" not in info.get("CFBundleSupportedPlatforms", [])
            or not isinstance(info.get("CFBundleShortVersionString"), str)):
        raise ValueError("IPA identity/build/platform does not match verified run")
    return info

def main():
    run_id = os.environ["UPDATE_RUN_ID"]
    if not re.fullmatch(r"[1-9][0-9]*", run_id):
        raise ValueError("Expected numeric workflow run ID")
    if os.environ.get("GITHUB_REPOSITORY") != REPOSITORY or os.environ.get("GITHUB_REF_NAME") != BRANCH:
        raise ValueError("Publish from the release branch in the original repository")
    run = json.loads(gh("api", f"repos/{REPOSITORY}/actions/runs/{run_id}"))
    build = validate_run(run)
    pages = json.loads(gh("api", "--paginate", "--slurp", f"repos/{REPOSITORY}/actions/runs/{run_id}/jobs?filter=latest"))
    jobs = [job for page in pages for job in page["jobs"]]
    required = {"ios", "ios-pairing-tls-preflight", "android",
                "desktop-companion (ubuntu-latest)", "desktop-companion (windows-latest)",
                "desktop-companion (macos-latest)"}
    if not required.issubset({job["name"] for job in jobs if job["conclusion"] == "success"}):
        raise ValueError("Required verification jobs did not all pass")
    releases = json.loads(gh("api", "--paginate", "--slurp", f"repos/{REPOSITORY}/releases?per_page=100"))
    for page in releases:
        for release in page:
            match = re.fullmatch(r"ios-build-([1-9][0-9]*)", release["tag_name"])
            if match and int(match[1]) >= build:
                raise ValueError("An equal or newer release already exists; never replace or downgrade")
    with tempfile.TemporaryDirectory(prefix="asterion-release-") as folder:
        gh("run", "download", run_id, "--repo", REPOSITORY,
           "--name", "AsterionVeyra-unsigned-IPA", "--dir", folder)
        path = Path(folder) / ASSET
        info = validate_ipa(path, build)
        notes = Path(folder) / "release-notes.txt"
        notes.write_text(
            f"Asterion Veyra {info['CFBundleShortVersionString']} — build {build}\n\n"
            f"Verified commit: {run['head_sha']}\n"
            f"CI evidence: https://github.com/{REPOSITORY}/actions/runs/{run_id}\n\n"
            "Unsigned IPA for SideStore to sign. Keep the existing app installed and use "
            "the same signing account. Export important chats and notes before updating. "
            "CI success does not establish physical-device behavior or SideStore data retention.\n",
            encoding="utf-8")
        # Creating the ref is atomic: an existing tag fails closed rather than
        # letting gh release create silently attach to an unrelated commit.
        # A partial publication needs manual reconciliation, never tag replacement.
        gh("api", "--method", "POST", f"repos/{REPOSITORY}/git/refs",
           "-f", f"ref=refs/tags/ios-build-{build}", "-f", f"sha={run['head_sha']}")
        gh("release", "create", f"ios-build-{build}", str(path), "--repo", REPOSITORY,
           "--verify-tag", "--title", f"Asterion Veyra build {build}",
           "--notes-file", str(notes), "--latest")

if __name__ == "__main__":
    main()
