"""Test explicit inventory selection without connecting to any host."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from jinja2 import Environment, StrictUndefined
import yaml

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent.parent
INVENTORY = Path(sys.executable).parent / "ansible-inventory"


class InventorySelection(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="mini-inventory-test-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.config = self.base / "ansible.cfg"
        self.config.write_text(f"[defaults]\ninventory = {ROOT / 'inventory.yml'}\n")
        self.env = os.environ.copy()
        self.env.update(ANSIBLE_CONFIG=str(self.config), ANSIBLE_HOME=str(self.base / "ansible"),
                        ANSIBLE_NOCOLOR="1")

    def inventory(self, path):
        return subprocess.run(
            [str(INVENTORY), "-i", str(path), "--playbook-dir", str(ROOT), "--list"],
            cwd=self.base, env=self.env, capture_output=True, text=True, timeout=30,
        )

    def parsed_inventory(self, path):
        result = self.inventory(path)
        # Never include Ansible output in failures: it may contain personal inventory values.
        self.assertEqual(result.returncode, 0, "explicit inventory could not be parsed")
        return json.loads(result.stdout)

    def test_private_copy_has_same_groups_and_host_variables(self):
        private = self.base / "inventory.private.yml"
        shutil.copyfile(ROOT / "inventory.yml", private)
        original = self.parsed_inventory(ROOT / "inventory.yml")
        selected = self.parsed_inventory(private)
        self.assertTrue(set(original) == set(selected), "inventory groups differ")
        for group in set(original) - {"_meta"}:
            self.assertTrue(original[group] == selected[group], "group membership differs")
        self.assertTrue(set(original["_meta"]["hostvars"]) == set(selected["_meta"]["hostvars"]),
                        "inventory host names differ")
        for host, variables in original["_meta"]["hostvars"].items():
            other = selected["_meta"]["hostvars"][host]
            self.assertTrue(variables == other, "host variables differ")

    def test_missing_and_invalid_explicit_inventory_do_not_fallback(self):
        invalid = self.base / "invalid.yml"
        invalid.write_text("all: [unterminated\n")
        for path in (self.base / "missing.yml", invalid):
            with self.subTest(case=path.name):
                result = self.inventory(path)
                self.assertEqual(result.returncode, 0, "inventory command failed unexpectedly")
                parsed = json.loads(result.stdout)
                self.assertFalse(parsed["_meta"]["hostvars"], "unexpected fallback hosts")
                self.assertNotIn("mini_macos", parsed, "unexpected fallback group")
                self.assertTrue(result.stderr.strip(), "missing inventory warning")

    def test_example_fails_production_identity_assertions(self):
        original = self.parsed_inventory(ROOT / "inventory.yml")
        example = self.parsed_inventory(ROOT / "inventory.example.yml")
        task = yaml.safe_load((ROOT / "tasks/preflight.yml").read_text())[0]
        expressions = task["ansible.builtin.assert"]["that"][:5]
        self.assertEqual(len(expressions), 5)
        evaluate = Environment(undefined=StrictUndefined).compile_expression

        def identity_results(inventory):
            hosts = inventory["_meta"]["hostvars"]
            self.assertEqual(len(hosts), 1)
            host, variables = next(iter(hosts.items()))
            return [bool(evaluate(expression)(**dict(variables, inventory_hostname=host)))
                    for expression in expressions]

        self.assertTrue(all(identity_results(original)), "existing inventory fails identity guard")
        self.assertFalse(all(identity_results(example)), "example passed identity guard")

    def test_synthetic_identity_and_platform_mismatches_are_rejected(self):
        inventory = self.parsed_inventory(ROOT / "inventory.yml")
        host, variables = next(iter(inventory["_meta"]["hostvars"].items()))
        variables = dict(variables, inventory_hostname=host)
        tasks = yaml.safe_load((ROOT / "tasks/preflight.yml").read_text())
        identity = tasks[0]["ansible.builtin.assert"]["that"][:5]
        platform = tasks[-1]["ansible.builtin.assert"]["that"]
        evaluate = Environment(undefined=StrictUndefined).compile_expression
        for key in ("inventory_hostname", "ansible_host", "ansible_user", "mini_home", "mini_repo"):
            with self.subTest(field=key):
                changed = dict(variables, **{key: "invalid-fixture"})
                self.assertFalse(all(evaluate(expr)(**changed) for expr in identity))
        for system, user in (("Linux x86_64", "gigun"), ("Darwin arm64", "gigun"),
                             ("Darwin x86_64", "root")):
            with self.subTest(system=system, user=user):
                facts = {"mini_platform": {"stdout": system}, "mini_identity": {"stdout": user}}
                self.assertFalse(all(evaluate(expr)(**facts) for expr in platform))

    def test_private_inventory_is_ignored_but_example_is_tracked(self):
        def ignored(path):
            return subprocess.run(["git", "check-ignore", "--no-index", "-q", path],
                                  cwd=REPO, capture_output=True).returncode
        self.assertEqual(ignored("ansible/mini-macos/inventory.private.yml"), 0)
        self.assertEqual(ignored("ansible/mini-macos/inventory.example.yml"), 1)
        tracked = subprocess.run(["git", "ls-files", "--error-unmatch",
                                  "ansible/mini-macos/inventory.example.yml"],
                                 cwd=REPO, capture_output=True)
        self.assertEqual(tracked.returncode, 0)


if __name__ == "__main__":
    unittest.main()
