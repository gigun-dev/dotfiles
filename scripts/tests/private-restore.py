#!/usr/bin/env python3
"""Public fixtures for the read-only private restore verifier."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "verify-private-restore.py"
EXAMPLE = Path(__file__).resolve().parents[2] / "docs/private-recovery-manifest.example.json"
spec = importlib.util.spec_from_file_location("private_restore", SCRIPT)
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)


def manifest(objects=1):
    return {
        "schema_version": 1,
        "owner_role": "owner",
        "primary_store_ref": "primary-a",
        "backup_store_ref": "backup-b",
        "failure_domains_independent": True,
        "objects": [
            {
                "id": f"record-{index}",
                "primary_file": f"primary-{index}.txt",
                "restored_file": f"restored-{index}.txt",
                "expected_mode": "0600",
                "public_counterparts": [f"docs/public-{index}.md"],
                "primary_read_verified": True,
                "backup_read_verified": True,
                "human_readable_verified": True,
                "restore_test_at": "2026-11-09T00:00:00Z",
                "remaining_gaps": [],
            }
            for index in range(objects)
        ],
    }


class RestoreFiles(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.primary = self.root / "primary"
        self.restored = self.root / "restored"
        self.primary.mkdir(mode=0o700)
        self.restored.mkdir(mode=0o700)
        self.manifest = self.root / "manifest.json"
        self.write_manifest(manifest(2))
        for index in range(2):
            for directory, prefix in ((self.primary, "primary"), (self.restored, "restored")):
                path = directory / f"{prefix}-{index}.txt"
                path.write_bytes(("public fixture " + str(index)).encode())
                path.chmod(0o600)

    def tearDown(self):
        self.tmp.cleanup()

    def write_manifest(self, value):
        self.manifest.write_text(json.dumps(value))
        self.manifest.chmod(0o600)

    def run_cli(self, env=None):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--manifest", str(self.manifest),
             "--primary-root", str(self.primary), "--restored-root", str(self.restored)],
            capture_output=True, text=True, timeout=10, env=env,
        )

    def assert_safe_failure(self):
        result = self.run_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr.strip(), v.FAILURE)
        combined = result.stdout + result.stderr
        self.assertNotIn(str(self.root), combined)
        self.assertNotIn("public fixture", combined)

    def test_success_is_silent_and_read_only(self):
        paths = [self.manifest, *self.primary.iterdir(), *self.restored.iterdir()]
        before = {path: (path.read_bytes(), path.stat().st_mode, path.stat().st_mtime_ns) for path in paths}
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout + result.stderr, "")
        after = {path: (path.read_bytes(), path.stat().st_mode, path.stat().st_mtime_ns) for path in paths}
        self.assertEqual(after, before)
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ["manifest.json", "primary", "restored"])

    def test_runs_without_path(self):
        env = dict(os.environ, PATH="")
        result = self.run_cli(env)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_content_and_size_mismatch_fail_safely(self):
        for content in (b"different fixture", b""):
            with self.subTest(size=len(content)):
                path = self.restored / "restored-0.txt"
                original = path.read_bytes()
                path.write_bytes(content)
                self.assert_safe_failure()
                path.write_bytes(original)

    def test_same_root_is_refused(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--manifest", str(self.manifest),
             "--primary-root", str(self.primary), "--restored-root", str(self.primary)],
            capture_output=True, text=True, timeout=10,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr.strip(), v.FAILURE)

    def test_hardlink_is_refused(self):
        target = self.restored / "restored-0.txt"
        target.unlink()
        os.link(self.primary / "primary-0.txt", target)
        self.assert_safe_failure()

    def test_symlinks_and_fifo_are_refused_without_blocking(self):
        cases = []
        original = self.primary / "primary-0.txt"
        original.rename(self.primary / "real.txt")
        original.symlink_to("real.txt")
        cases.append("file symlink")
        self.assert_safe_failure()
        original.unlink()
        os.mkfifo(original, 0o600)
        cases.append("fifo")
        self.assert_safe_failure()
        self.assertEqual(cases, ["file symlink", "fifo"])

    def test_manifest_and_root_symlinks_are_refused(self):
        real = self.manifest.with_name("real.json")
        self.manifest.rename(real)
        self.manifest.symlink_to(real)
        self.assert_safe_failure()
        self.manifest.unlink()
        real.rename(self.manifest)
        link = self.root / "primary-link"
        link.symlink_to(self.primary, target_is_directory=True)
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--manifest", str(self.manifest),
             "--primary-root", str(link), "--restored-root", str(self.restored)],
            capture_output=True, text=True, timeout=10,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr.strip(), v.FAILURE)

    def test_public_permissions_are_refused(self):
        for path, mode in ((self.manifest, 0o644), (self.primary, 0o755),
                           (self.primary / "primary-0.txt", 0o644),
                           (self.primary / "primary-0.txt", 0o700)):
            with self.subTest(path=path.name, mode=oct(mode)):
                old = path.stat().st_mode & 0o777
                path.chmod(mode)
                self.assert_safe_failure()
                path.chmod(old)

    def test_oversized_manifest_and_file_are_refused(self):
        original = self.manifest.read_bytes()
        self.manifest.write_bytes(b"x" * (v.MANIFEST_LIMIT + 1))
        self.assert_safe_failure()
        self.manifest.write_bytes(original)
        path = self.primary / "primary-0.txt"
        with path.open("wb") as stream:
            stream.truncate(v.FILE_LIMIT + 1)
        self.assert_safe_failure()

    def test_duplicate_json_key_and_bad_encoding_are_refused(self):
        for data in (b'{"schema_version":1,"schema_version":1}', b"\xff"):
            with self.subTest(data=data[:1]):
                self.manifest.write_bytes(data)
                self.assert_safe_failure()


class ManifestValidation(unittest.TestCase):
    def assert_invalid(self, value):
        with self.assertRaises((ValueError, TypeError)):
            v.validate_manifest(value)

    def test_public_example_is_schema_valid_but_not_attested(self):
        value = json.loads(EXAMPLE.read_text())
        self.assertIs(v.validate_manifest(value, require_attestation=False), value)
        self.assert_invalid(value)

    def test_unknown_missing_and_wrong_scalar_types_are_refused(self):
        for mutate in (
            lambda x: x.update(extra=True),
            lambda x: x.pop("owner_role"),
            lambda x: x.update(schema_version=True),
            lambda x: x.update(objects={}),
            lambda x: x.update(failure_domains_independent=1),
        ):
            value = manifest()
            mutate(value)
            self.assert_invalid(value)

    def test_store_and_attestation_gates_are_enforced(self):
        changes = (
            ("backup_store_ref", "primary-a"),
            ("failure_domains_independent", False),
        )
        for key, replacement in changes:
            value = manifest()
            value[key] = replacement
            self.assert_invalid(value)
        for key, replacement in (("primary_read_verified", False),
                                 ("backup_read_verified", False),
                                 ("human_readable_verified", False),
                                 ("restore_test_at", None),
                                 ("remaining_gaps", ["open item"])):
            value = manifest()
            value["objects"][0][key] = replacement
            self.assert_invalid(value)

    def test_object_count_ids_and_filenames_are_enforced(self):
        for value in (manifest(0), manifest(33)):
            self.assert_invalid(value)
        for field, replacement in (("id", "Bad"), ("primary_file", "../secret"),
                                   ("restored_file", "nested/file"),
                                   ("primary_file", "back\\slash")):
            value = manifest(2)
            value["objects"][1][field] = replacement
            self.assert_invalid(value)
        for field in ("id", "primary_file", "restored_file"):
            value = manifest(2)
            value["objects"][1][field] = value["objects"][0][field]
            self.assert_invalid(value)

    def test_public_paths_timestamp_and_unknown_object_key_are_enforced(self):
        for replacement in (["/absolute"], ["docs/../private"], ["docs/./private"],
                            ["docs//private"], ["same", "same"]):
            value = manifest()
            value["objects"][0]["public_counterparts"] = replacement
            self.assert_invalid(value)
        value = manifest()
        value["objects"][0]["restore_test_at"] = "2026-99-99T00:00:00Z"
        self.assert_invalid(value)
        value = manifest()
        value["objects"][0]["extra"] = True
        self.assert_invalid(value)

    def test_metadata_change_during_compare_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            left = Path(directory) / "left"
            right = Path(directory) / "right"
            left.write_bytes(b"same")
            right.write_bytes(b"same")
            for path in (left, right):
                path.chmod(0o600)
            with left.open("rb") as left_stream, right.open("rb") as right_stream:
                before_left = os.fstat(left_stream.fileno())
                before_right = os.fstat(right_stream.fileno())
                left.write_bytes(b"same")
                with self.assertRaises(ValueError):
                    v.compare_open_files(left_stream.fileno(), right_stream.fileno(),
                                         before_left, before_right)


if __name__ == "__main__":
    unittest.main()
