#!/usr/bin/env python3
"""Exercise every accepted path through the required CI gate."""

import os
from pathlib import Path
import subprocess
import unittest


SCRIPT = Path(__file__).parents[1] / "ci-required-gate.sh"
RESULTS = ("success", "failure", "cancelled", "skipped")


class RequiredGateTests(unittest.TestCase):
    def run_gate(self, *, event="pull_request", changed="true", changes="success",
                 check="success", build="success", secret_scan="success"):
        env = {
            "PATH": os.environ.get("PATH", ""),
            "CI_EVENT_NAME": event,
            "CI_NIX_CHANGED": changed,
            "CI_CHANGES_RESULT": changes,
            "CI_CHECK_RESULT": check,
            "CI_BUILD_RESULT": build,
            "CI_SECRET_SCAN_RESULT": secret_scan,
        }
        return subprocess.run(
            [os.environ.get("TEST_SH", "/bin/sh"), str(SCRIPT)],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_nix_change_requires_both_jobs_to_succeed(self):
        for check in RESULTS:
            for build in RESULTS:
                with self.subTest(check=check, build=build):
                    expected = check == build == "success"
                    self.assertEqual(self.run_gate(check=check, build=build).returncode == 0, expected)

    def test_change_detection_must_succeed(self):
        for changes in RESULTS:
            with self.subTest(changes=changes):
                expected = changes == "success"
                self.assertEqual(self.run_gate(changes=changes).returncode == 0, expected)

    def test_secret_scan_must_succeed(self):
        for secret_scan in RESULTS:
            with self.subTest(secret_scan=secret_scan):
                expected = secret_scan == "success"
                self.assertEqual(
                    self.run_gate(secret_scan=secret_scan).returncode == 0,
                    expected,
                )

    def test_non_nix_change_accepts_only_deliberate_skips(self):
        for check in RESULTS:
            for build in RESULTS:
                with self.subTest(check=check, build=build):
                    expected = check == build == "skipped"
                    result = self.run_gate(changed="false", check=check, build=build)
                    self.assertEqual(result.returncode == 0, expected)

    def test_manual_run_always_requires_validation(self):
        passed = self.run_gate(event="workflow_dispatch", changed="false")
        skipped = self.run_gate(
            event="workflow_dispatch", changed="false", check="skipped", build="skipped"
        )
        self.assertEqual(passed.returncode, 0)
        self.assertNotEqual(skipped.returncode, 0)

    def test_missing_or_unknown_metadata_fails_closed(self):
        for key, value in (
            ("event", "schedule"),
            ("changed", ""),
            ("changes", ""),
            ("check", "timed_out"),
            ("build", ""),
            ("secret_scan", ""),
        ):
            with self.subTest(key=key):
                self.assertNotEqual(self.run_gate(**{key: value}).returncode, 0)


if __name__ == "__main__":
    unittest.main()
