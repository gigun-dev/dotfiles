"""Verify Nix reference auditing emits locations but never source values."""

import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/audit_nix_refs.py"


class NixRefAudit(unittest.TestCase):
    def test_reports_reference_kind_without_value(self):
        with tempfile.TemporaryDirectory(prefix="mini-nix-ref-audit-") as temporary:
            home = Path(temporary)
            agents = home / "Library/LaunchAgents"
            agents.mkdir(parents=True)
            secret_marker = "do-not-print-this-marker"
            with (agents / "fixture.plist").open("wb") as stream:
                plistlib.dump({
                    "ProgramArguments": ["/nix/store/example/bin/node", secret_marker],
                    "EnvironmentVariables": {"PATH": "/etc/profiles/per-user/test/bin"},
                }, stream)
            runner = home / ".local/share/asc-mcp-runner/.path"
            runner.parent.mkdir(parents=True)
            runner.write_text("/nix/store/example/bin\n")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--home", str(home)],
                check=True, capture_output=True, text=True,
            )
            self.assertNotIn(secret_marker, result.stdout)
            marker = "MINI_NIX_REF_AUDIT="
            self.assertTrue(result.stdout.startswith(marker))
            report = json.loads(result.stdout.removeprefix(marker))
            self.assertEqual(set(report["commands"]), {"gh", "fd", "node"})
            plist = report["plists"][0]
            self.assertEqual(plist["findings"], [
                {"key": "EnvironmentVariables.PATH", "reference": "nix_profile"},
                {"key": "ProgramArguments[0]", "reference": "nix_store"},
            ])
            runner_report = next(item for item in report["text_files"]
                                 if item["path"] == str(runner))
            self.assertEqual(runner_report["findings"], [{"line": 1, "reference": "nix_store"}])


if __name__ == "__main__":
    unittest.main()
