"""Run real Ansible file tasks against disposable local homes, never SSH."""
import copy
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

from jinja2 import Environment, StrictUndefined
import yaml

ROOT = Path(__file__).resolve().parents[1]
PLAYBOOK = Path(sys.executable).parent / "ansible-playbook"


class Migration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="mini-ansible-test-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.home = self.base / "home"
        self.repo = self.base / "repo"
        self.home.mkdir()
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

    def test_staging_check_apply_and_idempotency(self):
        stage = Path(self.variables["mini_stage_dir"])
        result = self.run_tasks("launchd.yml", check=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(stage.exists())
        result = self.run_tasks("launchd.yml")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((stage / "network-watchdog.sh").read_bytes(),
                         (ROOT.parent.parent / "nix/modules/darwin/network-watchdog.sh").read_bytes())
        result = self.run_tasks("launchd.yml")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stdout, r"changed=0\s")

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
