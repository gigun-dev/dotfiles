#!/usr/bin/env python3
"""Only public fixtures; no credential issuance, remote access or application."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

SCRIPT = Path(__file__).resolve().parents[1] / "prepare-job-heartbeat-registration.py"
spec = importlib.util.spec_from_file_location("registration", SCRIPT)
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


def fixture():
    return [{"source": source, "ownerId": "homelab", "destinations": ["bark"],
             "token": "public_fixture_existing_" + str(i) * 32,
             **({"monitorControl": True} if source == "uptime-monitor" else {})}
            for i, source in enumerate(["mac", "mini-vm", "uptime-monitor", "other"])]


def tokens():
    return {source: "public_fixture_job_" + str(i) * 32 for i, source in enumerate(r.SOURCES)}


class Preparation(unittest.TestCase):
    def test_preserves_four_existing_and_adds_three_without_control(self):
        old = fixture()
        before = copy.deepcopy(old)
        result = r.prepare(old, tokens())
        self.assertEqual(old, before)
        self.assertEqual(result[:4], before)
        self.assertEqual([x["source"] for x in result[4:]], list(r.SOURCES))
        for item in result[4:]:
            self.assertEqual(set(item), {"source", "ownerId", "destinations", "token"})
            self.assertEqual(item["ownerId"], "homelab")
            self.assertEqual(item["destinations"], ["bark"])

    def test_idempotent_retains_order_and_fields(self):
        old = r.prepare(fixture(), tokens())
        old.reverse()
        self.assertEqual(r.prepare(old, tokens()), old)

    def test_partial_registration_adds_only_missing(self):
        old = r.prepare(fixture(), tokens())[:-1]
        result = r.prepare(old, tokens())
        self.assertEqual(result[:6], old)
        self.assertEqual(len(result), 7)

    def test_same_source_mismatches_refused(self):
        for field, value in [("token", "changed_public_fixture_" + "a" * 32),
                             ("ownerId", "another"), ("destinations", ["other"]),
                             ("monitorControl", False), ("extra", "value")]:
            with self.subTest(field=field):
                old = r.prepare(fixture(), tokens())
                old[-1][field] = value
                with self.assertRaises(ValueError):
                    r.prepare(old, tokens())

    def test_duplicate_source_refused(self):
        old = r.prepare(fixture(), tokens())
        item = dict(old[-1], token="different_fixture_" + "b" * 32)
        with self.assertRaises(ValueError):
            r.prepare(old + [item], tokens())

    def test_reference_routing_refused(self):
        for change in ["missing", "duplicate", "owner", "destination"]:
            with self.subTest(change=change):
                old = fixture()
                if change == "missing": old.pop(1)
                if change == "duplicate": old.append(dict(old[1], token="duplicate_fixture_" + "a" * 32))
                if change == "owner": old[1]["ownerId"] = "wrong"
                if change == "destination": old[1]["destinations"] = ["elsewhere"]
                with self.assertRaises(ValueError): r.prepare(old, tokens())

    def test_exact_sources_required(self):
        for value in [{}, [], {**tokens(), "other": "a" * 32}]:
            with self.subTest(value=type(value).__name__):
                with self.assertRaises(ValueError): r.prepare(fixture(), value)

    def test_bad_tokens_and_duplicates_refused(self):
        for value in ["short", "a" * 31 + "\n", 3, None, fixture()[0]["token"], tokens()[r.SOURCES[1]]]:
            with self.subTest(value=type(value).__name__):
                incoming = tokens()
                incoming[r.SOURCES[0]] = value
                with self.assertRaises(ValueError): r.prepare(fixture(), incoming)

    def test_capacity_is_validated(self):
        old = fixture()
        for i in range(27):
            old.append(dict(old[0], source="extra" + str(i), token="fixture_extra_" + str(i).zfill(32)))
        with self.assertRaises(ValueError): r.prepare(old, tokens())


class Files(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.input = self.root / "existing.json"
        self.tokens = self.root / "tokens.json"
        self.output = self.root / "candidate.json"
        for path, value in [(self.input, fixture()), (self.tokens, tokens())]:
            path.write_text(json.dumps(value))
            path.chmod(0o600)

    def tearDown(self): self.tmp.cleanup()

    def run_cli(self):
        return subprocess.run(["python3", str(SCRIPT), "--credentials-file", str(self.input),
                               "--tokens-file", str(self.tokens), "--output", str(self.output)],
                              capture_output=True, text=True, timeout=10)

    def assert_failed_safely(self):
        result = self.run_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr.strip(), "job registration preparation failed; no credentials printed or applied")
        self.assertFalse(self.output.exists())

    def test_cli_success_private_output_silent_and_input_unchanged(self):
        before = self.input.read_bytes()
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout + result.stderr, "")
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.input.read_bytes(), before)
        self.assertEqual(len(json.loads(self.output.read_text())), 7)
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ["candidate.json", "existing.json", "tokens.json"])

    def test_existing_output_not_overwritten(self):
        self.output.write_text("unchanged")
        result = self.run_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.output.read_text(), "unchanged")
        self.assertEqual(len(list(self.root.iterdir())), 3)

    def test_output_symlink_not_followed(self):
        self.output.symlink_to(self.input)
        before = self.input.read_bytes()
        self.assertNotEqual(self.run_cli().returncode, 0)
        self.assertEqual(self.input.read_bytes(), before)

    def test_public_input_refused(self):
        for path in [self.input, self.tokens]:
            path.chmod(0o644)
            self.assert_failed_safely()
            path.chmod(0o600)

    def test_symlink_input_refused(self):
        original = self.input.with_suffix(".original")
        self.input.rename(original)
        self.input.symlink_to(original)
        self.assert_failed_safely()

    def test_fifo_refused_without_blocking(self):
        self.tokens.unlink()
        os.mkfifo(self.tokens, 0o600)
        self.assert_failed_safely()

    def test_public_output_directory_refused(self):
        self.root.chmod(0o755)
        self.assert_failed_safely()

    def test_duplicate_json_keys_refused(self):
        self.tokens.write_text('{"mini-vm-autoswitch":"first","mini-vm-autoswitch":"second"}')
        self.assert_failed_safely()

    def test_foreign_owned_input_refused(self):
        original = os.fstat
        def foreign(fd):
            info = original(fd)
            return SimpleNamespace(st_mode=info.st_mode, st_uid=os.geteuid() + 1,
                                   st_size=info.st_size)
        with patch.object(r.os, "fstat", foreign):
            with self.assertRaises(ValueError): r.read_private_json(self.input)

    def test_foreign_owned_output_directory_refused(self):
        original = os.fstat
        def foreign(fd):
            info = original(fd)
            return SimpleNamespace(st_mode=info.st_mode, st_uid=os.geteuid() + 1)
        with patch.object(r.os, "fstat", foreign):
            with self.assertRaises(ValueError): r.write_candidate(self.output, [])
        self.assertFalse(self.output.exists())

    def test_directory_replacement_cannot_redirect_publication(self):
        stage = self.root / "stage"
        stage.mkdir(mode=0o700)
        moved = self.root / "moved"
        public = self.root / "public"
        public.mkdir(mode=0o755)
        original = os.fstat
        swapped = False
        def replace_after_check(fd):
            nonlocal swapped
            info = original(fd)
            if not swapped and r.stat.S_ISDIR(info.st_mode):
                swapped = True
                stage.rename(moved)
                stage.symlink_to(public, target_is_directory=True)
            return info
        with patch.object(r.os, "fstat", replace_after_check):
            r.write_candidate(stage / "candidate.json", [])
        self.assertTrue(swapped)
        self.assertEqual(list(public.iterdir()), [])
        self.assertEqual((moved / "candidate.json").read_text(), "[]\n")
        self.assertEqual([p.name for p in moved.iterdir()], ["candidate.json"])

    def test_output_directory_symlink_refused(self):
        link = self.root / "link"
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(OSError): r.write_candidate(link / "candidate.json", [])
        self.assertFalse(self.output.exists())

    def test_oversized_and_invalid_json_refused(self):
        for data in ["private_fixture_marker", "x" * 131073]:
            self.tokens.write_text(data)
            self.assert_failed_safely()


if __name__ == "__main__": unittest.main()
