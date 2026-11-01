"""Run real Ansible file tasks against disposable local homes, never SSH."""
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

from jinja2 import Environment, StrictUndefined
import yaml

ROOT = Path(__file__).resolve().parents[1]
PLAYBOOK = Path(sys.executable).parent / "ansible-playbook"


class MigrationFixture:
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="mini-ansible-test-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.home = self.base / "home"
        self.repo = self.base / "repo"
        self.home.mkdir()
        (self.base / "tasks").mkdir()
        shutil.copy2(ROOT / "tasks/validate_tool_policy.yml",
                     self.base / "tasks/validate_tool_policy.yml")
        (self.base / "ansible.cfg").write_text("[defaults]\n")
        (self.repo / "zsh").mkdir(parents=True)
        (self.repo / "zsh/.zshenv").write_text("export XDG_CACHE_HOME=${HOME}/.cache\n")
        self.variables = yaml.safe_load((ROOT / "group_vars/mini_macos.yml").read_text())
        self.variables.update(mini_controller_repo=str(ROOT.parent.parent),
                              mini_stage_dir=str(self.home / "Library/Application Support/dotfiles-migration/network-watchdog"),
                              mini_home=str(self.home), mini_repo=str(self.repo),
                              mini_shell_links=[{"src": "zsh/.zshenv", "dest": ".zshenv"}])

    def run_tasks(self, task_file, variables=None, check=False):
        play = [{"name": "Isolated fixture", "hosts": "mini", "connection": "local",
                 "gather_facts": False, "vars": variables or self.variables,
                 "tasks": [{"name": "Exercise production tasks", "ansible.builtin.import_tasks":
                            str(ROOT / "tasks" / task_file)}]}]
        path = self.base / "fixture.yml"
        path.write_text(yaml.safe_dump(play))
        env = os.environ.copy()
        env.update(ANSIBLE_LOCAL_TEMP=str(self.base / "local-tmp"),
                   ANSIBLE_REMOTE_TEMP=str(self.base / "remote-tmp"),
                   ANSIBLE_CONFIG=str(self.base / "ansible.cfg"), ANSIBLE_NOCOLOR="1")
        args = [str(PLAYBOOK), "-i", "mini,", str(path), "-e",
                json.dumps({"ansible_python_interpreter": sys.executable})]
        if check:
            args += ["--check", "--diff"]
        return subprocess.run(args, cwd=self.base, env=env, capture_output=True, text=True, timeout=60)

    def configure_tool(self, name, source, destination, accepted_existing=None, force=False):
        policy = self.variables["mini_tool_policy"][name]
        policy["target"]["version"] = "1.0-test"
        policy["target"]["source"] = {
            "kind": "homebrew_cellar",
            "path": str(source),
            "integrity": {
                "kind": "executable_sha256",
                "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
            },
        }
        policy["target"]["selection"] = {
            "mode": "interactive_cli",
            "state": "selected",
            "destination": str(destination),
            "accepted_existing": accepted_existing or [str(source)],
            "force": force,
        }
        policy["adoption"] = {"state": "adopted", "owner": "ansible"}
        self.variables["mini_tool_name"] = name

class Migration(MigrationFixture, unittest.TestCase):
    def test_adopted_tool_defaults_match_the_pre_refactor_values(self):
        expected = {
            "fzf": ("0.74.5", "/usr/local/Cellar/fzf/0.74.5/bin/fzf",
                    "ba4b0df70d7fd9e8dd0d2fa479d68c2bc10859449c86e6f7e2d1856d663d1111",
                    "/usr/local/bin/fzf", ["/usr/local/Cellar/fzf/0.74.5/bin/fzf"], False),
            "zoxide": ("0.10.0", "/usr/local/Cellar/zoxide/0.10.0/bin/zoxide",
                       "e376d3046098c87fa25ed385bb4d1bc1e72c2c8b88f919ddaf912a19f6442a9f",
                       "/usr/local/bin/zoxide", ["/usr/local/Cellar/zoxide/0.10.0/bin/zoxide"], False),
            "ripgrep": ("15.2.0", "/usr/local/Cellar/ripgrep/15.2.0/bin/rg",
                        "f8cf484393a97aaaa4ce35df1c5ea2790f6b8af6d86c8d31b3e694369dc5ebb4",
                        "/usr/local/bin/rg", ["/usr/local/Cellar/ripgrep/15.2.0/bin/rg"], False),
            "xcodegen": ("2.46.0", "/usr/local/Cellar/xcodegen/2.46.0/bin/xcodegen",
                         "b8714a29ed5d40319ff8a653e08fa684c756deee1ff0db15cac66b6392a55ba3",
                         "/usr/local/bin/xcodegen",
                         ["../Cellar/xcodegen/2.46.0/bin/xcodegen",
                          "/usr/local/Cellar/xcodegen/2.46.0/bin/xcodegen"], True),
        }
        self.assertEqual(self.variables["mini_targets"], [])
        for name, (version, source, checksum, destination, accepted, force) in expected.items():
            with self.subTest(tool=name):
                policy = self.variables["mini_tool_policy"][name]
                self.assertEqual(policy["target"]["version"], version)
                self.assertEqual(policy["target"]["source"]["path"], source)
                self.assertEqual(policy["target"]["source"]["integrity"],
                                 {"kind": "executable_sha256", "sha256": checksum})
                self.assertEqual(policy["target"]["selection"]["mode"], "interactive_cli")
                self.assertEqual(policy["target"]["selection"]["state"], "selected")
                self.assertEqual(policy["target"]["selection"]["destination"], destination)
                self.assertEqual(policy["target"]["selection"]["accepted_existing"], accepted)
                self.assertEqual(policy["target"]["selection"]["force"], force)
                self.assertEqual(policy["target"]["update_policy"], "manual")
                self.assertEqual(policy["adoption"], {"state": "adopted", "owner": "ansible"})

    def test_policy_driven_selection_is_idempotent_and_preserves_unknown_state(self):
        fixtures = {}
        for name in ("fzf", "zoxide", "ripgrep", "xcodegen"):
            with self.subTest(tool=name):
                source = self.home / f"verified-{name}"
                source.write_text("#!/bin/sh\nexit 0\n")
                source.chmod(0o755)
                destination = self.home / name
                self.configure_tool(name, source, destination)
                result = self.run_tasks("select_tool.yml", check=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(destination.exists())
                result = self.run_tasks("select_tool.yml")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(destination.resolve(), source)
                result = self.run_tasks("select_tool.yml")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout, r"changed=0\s")
                fixtures[name] = (source, destination)

        source, destination = fixtures["fzf"]
        destination.unlink()
        destination.write_text("preserve")
        self.variables["mini_tool_name"] = "fzf"
        result = self.run_tasks("select_tool.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(destination.read_text(), "preserve")
        destination.unlink()
        source.write_text("changed executable")
        result = self.run_tasks("select_tool.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(destination.exists())

    def test_xcodegen_known_legacy_link_transfers_only_that_link(self):
        source = self.base / "usr/local/Cellar/xcodegen/2.46.0/bin/xcodegen"
        source.parent.mkdir(parents=True)
        source.write_text("#!/bin/sh\necho Version: 2.46.0\n")
        source.chmod(0o755)
        dest = self.base / "usr/local/bin/xcodegen"
        dest.parent.mkdir(parents=True)
        legacy = "../Cellar/xcodegen/2.46.0/bin/xcodegen"
        dest.symlink_to(legacy)
        self.configure_tool("xcodegen", source, dest,
                            accepted_existing=[legacy, str(source)], force=True)
        result = self.run_tasks("select_tool.yml", check=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(os.readlink(dest), legacy)
        result = self.run_tasks("select_tool.yml")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(dest.resolve(), source)
        self.assertEqual(os.readlink(dest), str(source))
        result = self.run_tasks("select_tool.yml")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stdout, r"changed=0\s")
        dest.unlink()
        dest.symlink_to(self.base / "other-missing-source")
        result = self.run_tasks("select_tool.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(os.readlink(dest), str(self.base / "other-missing-source"))

    def test_missing_link_preview_apply_and_second_apply(self):
        preview = self.run_tasks("shell.yml", check=True)
        self.assertEqual(preview.returncode, 0, preview.stdout + preview.stderr)
        self.assertFalse((self.home / ".zshenv").exists())
        self.assertFalse((self.home / ".config").exists())
        first = self.run_tasks("shell.yml")
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertEqual((self.home / ".zshenv").resolve(), self.repo / "zsh/.zshenv")
        self.assertTrue((self.home / ".config/zsh").is_dir())
        self.assertFalse((self.base / ".config").exists())
        second = self.run_tasks("shell.yml")
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertRegex(second.stdout, r"changed=0\s")

    def test_regular_file_and_other_link_are_preserved(self):
        dest = self.home / ".zshenv"
        dest.write_text("existing configuration")
        result = self.run_tasks("shell.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Preserve the existing object", result.stdout)
        self.assertEqual(dest.read_text(), "existing configuration")
        dest.unlink()
        dest.symlink_to(self.base / "other-missing-source")
        result = self.run_tasks("shell.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Preserve the existing object", result.stdout)
        self.assertEqual(os.readlink(dest), str(self.base / "other-missing-source"))

    def test_missing_source_prevents_partial_application(self):
        self.variables["mini_shell_links"].append({"src": "missing", "dest": ".zshrc"})
        result = self.run_tasks("shell.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TASK [Require every source", result.stdout)
        self.assertFalse((self.home / ".zshenv").exists())

    def test_manager_link_to_same_final_source_is_preserved(self):
        managed = self.base / "manager-link"
        managed.symlink_to(self.repo / "zsh/.zshenv")
        dest = self.home / ".zshenv"
        dest.symlink_to(managed)
        result = self.run_tasks("shell.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Preserve the existing object", result.stdout)
        self.assertEqual(os.readlink(dest), str(managed))

    def test_preflight_rejects_unacknowledged_unknown_and_unowned_targets(self):
        # Assertions run before any remote command. The local fixture never contacts mini.
        base = yaml.safe_load((ROOT / "group_vars/mini_macos.yml").read_text())
        base.update(inventory_hostname="mini", ansible_host="mini", ansible_user="gigun")
        for targets, ack, owner in [(["shell"], False, "ansible"),
                                    (["unknown"], True, "ansible"),
                                    (["shell"], True, "legacy")]:
            with self.subTest(targets=targets, ack=ack, owner=owner):
                variables = copy.deepcopy(base)
                variables.update(mini_targets=targets, mini_apply_ack=ack)
                variables["mini_owners"]["shell"] = owner
                result = self.run_tasks("preflight.yml", variables)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('"evaluated_to": false', result.stdout)
                self.assertNotIn("TASK [Read target operating", result.stdout)

    def test_pending_candidates_refuse_selection(self):
        base = yaml.safe_load((ROOT / "group_vars/mini_macos.yml").read_text())
        base.update(inventory_hostname="mini", ansible_host="mini", ansible_user="gigun")
        for name in ("fd", "vivid", "asc"):
            with self.subTest(tool=name):
                variables = copy.deepcopy(base)
                variables.update(mini_targets=[name], mini_apply_ack=True)
                result = self.run_tasks("preflight.yml", variables)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Retire the previous writer", result.stdout)
                self.assertNotIn("TASK [Read target operating", result.stdout)

    def test_tool_owner_cannot_be_declared_twice(self):
        variables = yaml.safe_load((ROOT / "group_vars/mini_macos.yml").read_text())
        variables["mini_owners"]["fzf"] = "ansible"
        result = self.run_tasks("validate_tool_policy.yml", variables)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Declare each target owner in exactly one location", result.stdout)

    def test_missing_tool_integrity_is_rejected(self):
        variables = yaml.safe_load((ROOT / "group_vars/mini_macos.yml").read_text())
        del variables["mini_tool_policy"]["fzf"]["target"]["source"]["integrity"]["sha256"]
        result = self.run_tasks("validate_tool_policy.yml", variables)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Tool target metadata is incomplete", result.stdout)

    def test_protected_service_path_is_allowed_but_user_path_is_rejected(self):
        variables = yaml.safe_load((ROOT / "group_vars/mini_macos.yml").read_text())
        service = copy.deepcopy(variables["mini_tool_policy"]["fzf"])
        variables["mini_tool_policy"]["test_signer"] = service
        selection = service["target"]["selection"]
        selection.update(mode="protected_service", destination="/nix/store/abc123/bin/signer")
        allowed = (
            "/nix/store/abc123/bin/signer",
            "/nix/store/abc123/libexec/vendor/bin/signer",
            "/run/current-system/sw/bin/signer",
            "/Library/PrivilegedHelperTools/signer",
        )
        for destination in allowed:
            with self.subTest(destination=destination):
                selection["destination"] = destination
                result = self.run_tasks("validate_tool_policy.yml", variables)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        rejected = (
            "/Users/gigun/.local/bin/signer",
            "/usr/local/bin/signer",
            "/nix/store/abc123/../Users/gigun/.local/bin/asc",
            "/nix/store/abc123/./bin/signer",
            "/run/current-system/sw/bin/../Users/gigun/.local/bin/asc",
            "/run/current-system/sw/bin/./signer",
            "/Library/PrivilegedHelperTools/signer/../../../Users/gigun/.local/bin/asc",
            "/Library/PrivilegedHelperTools/./signer",
            "/run/current-system/sw/bin/signer/extra",
            "/Library/PrivilegedHelperTools/signer/extra",
            "/nix/storeevil/abc123/bin/signer",
            "/run/current-system/sw/bin-extra/signer",
            "/Library/PrivilegedHelperTools-extra/signer",
            "/nix/store/abc123/tool\nname/../../../../Users/gigun/.local/bin/asc",
            "/nix/store/abc123/bin/signer\n",
        )
        for destination in rejected:
            with self.subTest(destination=destination):
                selection["destination"] = destination
                result = self.run_tasks("validate_tool_policy.yml", variables)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Tool target metadata is incomplete", result.stdout)

    def test_other_host_is_rejected_before_any_command(self):
        variables = yaml.safe_load((ROOT / "group_vars/mini_macos.yml").read_text())
        variables.update(ansible_host="mini-vm", ansible_user="gigun")
        result = self.run_tasks("preflight.yml", variables)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('"assertion": "ansible_host', result.stdout)
        self.assertNotIn("TASK [Read target operating", result.stdout)

    def test_existing_directory_permissions_are_preserved(self):
        config = self.home / ".config"
        config.mkdir(mode=0o700)
        result = self.run_tasks("shell.yml")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(config.stat().st_mode & 0o777, 0o700)

    def test_staging_never_follows_live_directory_link(self):
        stage = Path(self.variables["mini_stage_dir"])
        stage.parent.mkdir(parents=True)
        live = self.home / "live"
        live.mkdir()
        script = live / "network-watchdog.sh"
        script.write_text("live sentinel")
        stage.symlink_to(live, target_is_directory=True)
        result = self.run_tasks("launchd.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TASK [Refuse staging through links", result.stdout)
        self.assertEqual(script.read_text(), "live sentinel")

    def test_plist_preserves_user_service_and_no_staging_activation(self):
        template = (ROOT / "templates/network-watchdog.plist.j2").read_text()
        rendered = Environment(undefined=StrictUndefined).from_string(template).render(mini_home="/Users/gigun")
        plist = plistlib.loads(rendered.encode())
        self.assertEqual(plist["Label"], "dev.gigun.net-watchdog")
        self.assertEqual(plist["EnvironmentVariables"]["NET_WATCHDOG_NO_REMEDIATE"], "1")
        self.assertEqual(plist["StartInterval"], 30)
        self.assertTrue(plist["RunAtLoad"])
        self.assertEqual(plist["ProgramArguments"], ["/bin/bash", "/Users/gigun/Library/Application Support/net-watchdog/network-watchdog.sh"])
        self.assertEqual(plist["EnvironmentVariables"]["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        for task in yaml.safe_load((ROOT / "tasks/launchd.yml").read_text()):
            self.assertFalse(any(k in task for k in ["ansible.builtin.command", "ansible.builtin.shell", "community.general.launchd", "notify"]))
        self.assertNotIn("handlers:", (ROOT / "apply.yml").read_text())


if __name__ == "__main__":
    unittest.main()
