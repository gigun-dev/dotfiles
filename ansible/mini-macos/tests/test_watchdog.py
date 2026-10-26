"""Exercise observation-only behavior with all network commands replaced by fixtures."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


class WatchdogObservation(unittest.TestCase):
    def test_repeated_failure_is_logged_without_wifi_operation(self):
        with tempfile.TemporaryDirectory(prefix="watchdog-observe-") as tmp:
            base = Path(tmp)
            commands = base / "bin"
            commands.mkdir()
            mocks = {
                "route": "printf 'gateway: 192.0.2.1\\ninterface: en1\\n'",
                "ifconfig": "printf 'status: active\\ninet 192.0.2.2\\n'",
                "netstat": "printf 'en1 <Link#1> 0 0 0 0 0 0 0 0\\n'",
                "ping": "exit 1",
                "nc": "exit 1",
                "dig": "exit 0",
                "networksetup": '''if [ "$1" = -listallhardwareports ]; then
printf 'Hardware Port: Wi-Fi\\nDevice: en1\\n'
else
printf '%s\\n' "$*" >> "$FORBIDDEN_CALLS"
exit 99
fi''',
            }
            for name, body in mocks.items():
                p = commands / name
                p.write_text("#!/bin/sh\n" + body + "\n")
                p.chmod(0o755)
            log = base / "logs"
            forbidden = base / "forbidden"
            env = {"PATH": str(commands) + ":/usr/bin:/bin", "HOME": str(base),
                   "NET_WATCHDOG_DIR": str(log), "NET_WATCHDOG_NO_REMEDIATE": "1",
                   "FORBIDDEN_CALLS": str(forbidden)}
            for _ in range(3):
                result = subprocess.run(["/bin/bash", str(ROOT / "nix/modules/darwin/network-watchdog.sh")],
                                        env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
            rows = [json.loads(line) for line in (log / "samples.jsonl").read_text().splitlines()]
            self.assertEqual([r["ev"] for r in rows], ["sample"] * 3)
            self.assertEqual([r["bad_n"] for r in rows], [1, 2, 3])
            self.assertTrue(all(r["bad"] == 1 and r["remediated"] == 0 for r in rows))
            self.assertFalse(forbidden.exists(), "Wi-Fi operation must never be attempted")

    def test_every_shipped_service_declaration_disables_remediation(self):
        for relative in ["bootstrap.sh", "nix/modules/darwin/net-watchdog-system-install.sh",
                         "ansible/mini-macos/templates/network-watchdog.plist.j2"]:
            self.assertIn('<key>NET_WATCHDOG_NO_REMEDIATE</key><string>1</string>',
                          (ROOT / relative).read_text())
        self.assertIn('EnvironmentVariables.NET_WATCHDOG_NO_REMEDIATE = "1";',
                      (ROOT / "nix/modules/darwin/network-watchdog.nix").read_text())
