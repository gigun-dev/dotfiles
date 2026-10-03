"""移行後の初回失敗と同候補 retry で旧世代へ遡らない境界。"""
import pathlib
import subprocess
import tempfile
import unittest

SCRIPTS = pathlib.Path(__file__).resolve().parents[1]


class RollbackTargetTest(unittest.TestCase):
    def test_target_is_running_system_before_this_attempt(self):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory).resolve()
            systems = {}
            for name, version in (("old49", "4.38.0"), ("migrated50", "4.46.0"), ("os_update", "4.46.0")):
                path = base / name
                (path / "etc/langfuse").mkdir(parents=True)
                (path / "bin").mkdir()
                (path / "bin/switch-to-configuration").write_text("#!/bin/sh\nexit 0\n")
                (path / "bin/switch-to-configuration").chmod(0o755)
                (path / "etc/langfuse/compose.yaml").write_text(
                    f"image: docker.langfuse.com/langfuse/langfuse:{version}@sha256:web\n"
                    f"image: docker.langfuse.com/langfuse/langfuse-worker:{version}@sha256:worker\n"
                )
                systems[name] = path

            def target(previous, current):
                return subprocess.run(
                    ["bash", str(SCRIPTS / "rollback-target.sh"), str(systems[previous]),
                     str(systems[current]), str(SCRIPTS / "rollback-safe.sh")],
                    capture_output=True, text=True, check=False,
                )

            first_failure = target("old49", "migrated50")
            self.assertNotEqual(first_failure.returncode, 0)
            self.assertEqual(first_failure.stdout, "")
            retry_failure = target("migrated50", "migrated50")
            self.assertEqual(retry_failure.returncode, 0, retry_failure.stderr)
            self.assertEqual(retry_failure.stdout.strip(), str(systems["migrated50"]))
            os_failure = target("migrated50", "os_update")
            self.assertEqual(os_failure.returncode, 0, os_failure.stderr)
            self.assertEqual(os_failure.stdout.strip(), str(systems["migrated50"]))


if __name__ == "__main__":
    unittest.main()
