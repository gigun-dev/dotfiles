"""OS-only rollback と移行後の旧 image 復帰の境界を外部サービス無しで検証する。"""

import pathlib
import subprocess
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "rollback-safe.sh"


def compose(web="4.38.0@sha256:oldweb", worker="4.38.0@sha256:oldworker"):
    return (
        "services:\n"
        "  langfuse-worker:\n"
        f"    image: docker.langfuse.com/langfuse/langfuse-worker:{worker}\n"
        "  langfuse-web:\n"
        f"    image: docker.langfuse.com/langfuse/langfuse:{web}\n"
    )


class RollbackSafeTest(unittest.TestCase):
    def run_guard(self, before, after):
        with tempfile.TemporaryDirectory() as directory:
            paths = [pathlib.Path(directory) / name for name in ("before", "after")]
            for path, text in zip(paths, (before, after)):
                if text is not None:
                    path.write_text(text)
            return subprocess.run(
                ["bash", str(SCRIPT), *(str(path) for path in paths)],
                capture_output=True,
                text=True,
                check=False,
            )

    def test_os_only_change_keeps_rollback(self):
        result = self.run_guard(compose(), compose() + "  postgres:\n    image: postgres:17\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_pair_version_change_blocks_old_image_restore(self):
        self.assertEqual(
            self.run_guard(compose(), compose("4.46.0@sha256:newweb", "4.46.0@sha256:newworker")).returncode,
            1,
        )

    def test_single_worker_change_blocks_rollback(self):
        self.assertEqual(self.run_guard(compose(), compose(worker="4.46.0@sha256:newworker")).returncode, 1)

    def test_same_tag_changed_digest_blocks_rollback(self):
        self.assertEqual(self.run_guard(compose(), compose(web="4.38.0@sha256:replacement")).returncode, 1)

    def test_missing_or_unrecognized_pair_is_not_safe(self):
        for invalid in (None, "services:\n", compose().replace("langfuse-worker:", "unknown-worker:")):
            with self.subTest(invalid=invalid):
                self.assertEqual(self.run_guard(compose(), invalid).returncode, 2)

    def test_duplicate_pair_is_not_safe(self):
        self.assertEqual(self.run_guard(compose(), compose() + compose()).returncode, 2)

    def test_does_not_emit_compose_secrets(self):
        result = self.run_guard(compose(), "environment:\n  SECRET_VALUE: do-not-emit\n")
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("do-not-emit", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
