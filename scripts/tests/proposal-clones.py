#!/usr/bin/env python3
"""Exercise shipped proposal shells against real, isolated Git repositories."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
GIT = shutil.which("git")
PYTHON = shutil.which("python3")


class CloneTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="proposal-clones-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.audit = self.root / "audit"
        self.audit.mkdir()
        self.config = self.root / "gitconfig"
        self.config.write_text("[user]\nname = Synthetic\nemail = synthetic@example.invalid\n"
                               "[commit]\ngpgsign = false\n[core]\nhooksPath = /dev/null\n")
        self.env = dict({k: v for k, v in os.environ.items() if not k.startswith("GIT_")},
                        HOME=str(self.root), GIT_CONFIG_NOSYSTEM="1",
                        GIT_CONFIG_GLOBAL=str(self.config), REAL_GIT=GIT,
                        AUDIT=str(self.audit), PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        seed = self.root / "seed"
        seed.mkdir()
        self.git(seed, "init", "-q", "-b", "main")
        (seed / "flake.lock").write_text('{"revision":"base"}\n')
        compose = seed / "infra/langfuse/compose.yaml"
        compose.parent.mkdir(parents=True)
        compose.write_text("services:\n  web:\n    image: docker.langfuse.com/langfuse/langfuse:4.1.0@sha256:" + "0" * 64
                           + "\n  worker:\n    image: docker.langfuse.com/langfuse/langfuse-worker:4.1.0@sha256:" + "0" * 64 + "\n")
        (seed / "runtime.txt").write_text("committed\n")
        self.git(seed, "add", ".")
        self.git(seed, "commit", "-qm", "fixture")
        self.base = self.git(seed, "rev-parse", "HEAD").stdout.strip()
        self.remote = self.root / "upstream.git"
        self.git(self.root, "clone", "--quiet", "--bare", str(seed), str(self.remote))
        self.native = self.root / "runtime"
        self.git(self.root, "clone", "--quiet", "--single-branch", str(self.remote), str(self.native))
        self.git(self.native, "fetch", "--quiet", "origin")
        (self.native / "runtime.txt").write_text("uncommitted user change\n")
        (self.native / "private.txt").write_text("synthetic private fixture\n")
        native_compose = self.native / "infra/langfuse/compose.yaml"
        native_compose.write_text(native_compose.read_text().replace("4.1.0", "9.9.9"))
        self.before = self.snapshot(self.native)
        self.objects = {self.identity(p) for p in (self.remote / "objects").rglob("*") if p.is_file()}
        self.install_commands()
        self.scripts = {}
        for kind in ("fast", "slow", "langfuse"):
            module = ROOT / "nix/modules/nixos" / ("services/langfuse.nix" if kind == "langfuse" else "mini-vm.nix")
            name = "langfuse-update-propose" if kind == "langfuse" else "dotfiles-lock-propose"
            body = module.read_text().split(f'pkgs.writeShellScript "{name}" \'\'\n', 1)[1].split("\n  '';", 1)[0]
            body = textwrap.dedent(body).replace("''${", "${")
            # A local transport makes omitted --no-hardlinks detectable by inode checks.
            body = body.replace("https://github.com/${dotfilesRepo}.git", shlex.quote(str(self.remote)))
            body = body.replace("https://github.com/gigun-dev/dotfiles.git", shlex.quote(str(self.remote)))
            body = body.replace("${dotfilesDir}", shlex.quote(str(self.native)))
            body = body.replace("${jobHeartbeatSnapshot}", "export DOTFILES_JOB_HEARTBEAT_ENABLED=0")
            body = body.replace("${jobHeartbeat}", "heartbeat")
            body = body.replace("${environmentFile}", shlex.quote(str(self.root / "synthetic.env")))
            body = re.sub(r"\$\{pkgs\.[^}]+\}/bin/([\w-]+)", r"\1", body)
            self.scripts[kind] = self.root / (kind + ".sh")
            self.scripts[kind].write_text(body)

    def git(self, cwd, *args, check=True, input=None):
        return subprocess.run([GIT, "-C", str(cwd), *args], env=self.env,
                              capture_output=True, text=True, check=check, input=input)

    @staticmethod
    def identity(path):
        s = path.stat()
        return s.st_dev, s.st_ino

    @staticmethod
    def snapshot(path):
        return {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in path.rglob("*") if p.is_file()}

    def command(self, name, body):
        target = self.bin / name
        target.write_text("#!" + PYTHON + "\n" + textwrap.dedent(body))
        target.chmod(0o755)

    def install_commands(self):
        self.command("git", """
            import os, subprocess, sys, json
            args = sys.argv[1:]
            if args and args[0] == os.environ.get('FAIL_GIT'):
                with open(os.environ['AUDIT'] + '/' + os.environ['KIND'] + '.events', 'a') as f:
                    f.write(json.dumps({'type':'injected-failure', 'command':args[0]}) + '\\n')
                sys.exit(23)
            if args and args[0] == 'push':
                head = subprocess.check_output([os.environ['REAL_GIT'], 'rev-parse', 'HEAD'], text=True).strip()
                with open(os.environ['AUDIT'] + '/' + os.environ['KIND'] + '.events', 'a') as f:
                    f.write(json.dumps({'type':'push', 'head':head}) + '\\n')
            os.execv(os.environ['REAL_GIT'], [os.environ['REAL_GIT']] + args)
        """)
        self.command("nix", """
            import os, pathlib, subprocess, sys, json, time
            kind = os.environ['KIND']; root = pathlib.Path(os.environ['AUDIT'])
            if sys.argv[1:3] == ['flake', 'update']:
                p = pathlib.Path('flake.lock'); d = json.loads(p.read_text()); d['candidate'] = kind
                p.write_text(json.dumps(d) + '\\n'); print('synthetic lock update'); sys.exit(0)
            assert sys.argv[1] == 'build', sys.argv
            git = os.environ['REAL_GIT']
            common = pathlib.Path(subprocess.check_output([git, 'rev-parse', '--path-format=absolute', '--git-common-dir'], text=True).strip()).resolve()
            head = subprocess.check_output([git, 'rev-parse', 'HEAD'], text=True).strip()
            clean = subprocess.run([git, 'diff', '--quiet']).returncode == 0
            identity = subprocess.check_output([git, 'show', '-s', '--format=%an%n%ae%n%cn%n%ce', 'HEAD'], text=True).splitlines()
            local_config = subprocess.run([git, 'config', '--local', '--get-regexp', r'^(user\\.|credential\\.|core\\.hookspath)'], capture_output=True, text=True)
            assert local_config.returncode in (0, 1)
            objects = [[p.stat().st_dev, p.stat().st_ino] for p in (common/'objects').rglob('*') if p.is_file()]
            with open(root / (kind + '.events'), 'a') as f:
                f.write(json.dumps({'type':'build','head':head,'common':str(common),'clean':clean,
                                   'alternates':(common/'objects/info/alternates').exists(),'objects':objects,
                                   'identity':identity,'localIdentityHooksCredentials':local_config.stdout}) + '\\n')
            if os.environ.get('CHECK_CREDENTIALS') == '1':
                credential = subprocess.run([git, 'credential', 'fill'], input='protocol=https\\nhost=synthetic.invalid\\n\\n', capture_output=True, text=True)
                assert credential.returncode == 0
                fields = dict(s.split('=', 1) for s in credential.stdout.splitlines() if '=' in s)
                assert fields.get('username') == 'synthetic-global'
                assert fields.get('password') == 'fixed-fake-global-password'
            (root / (kind + '.ready')).touch()
            if os.environ.get('BARRIER') == '1':
                deadline = time.monotonic() + 15
                while not all((root/(k+'.ready')).exists() for k in ['fast','slow','langfuse']):
                    if time.monotonic() > deadline: raise RuntimeError('proposal concurrency barrier timed out')
                    time.sleep(.01)
            if os.environ.get('FAIL_BUILD') == '1': sys.exit(19)
        """)
        self.command("gh", """
            import sys
            if sys.argv[1:3] == ['pr','view']: print('off')
        """)
        self.command("heartbeat", """
            import sys
            if sys.argv[1] == 'begin': print('synthetic-receipt')
        """)
        self.command("curl", "print('[]')\n")
        self.command("jq", "import os, sys; sys.stdin.read(); print(os.environ.get('RELEASE', 'v4.2.0'))\n")
        self.command("skopeo", "print('1' * 64)\n")
        self.command("docker-compose", "import sys; assert sys.argv[-2:] == ['config', '--quiet']\n")
        # BSD sed takes a separate empty backup suffix; GNU sed uses bare -i.
        sed = shutil.which("sed")
        is_gnu = "GNU" in subprocess.run([sed, "--version"], capture_output=True, text=True).stdout
        self.command("sed", f"""
            import os, sys
            args = sys.argv[1:]
            if '-i' in args and {not is_gnu!r}: args.insert(args.index('-i') + 1, '')
            os.execv({sed!r}, [{sed!r}] + args)
        """)

    def start(self, kind, **extra):
        state = self.root / ("state-" + kind)
        state.mkdir(exist_ok=True)
        legacy = state / ("worktree" if kind == "langfuse" else kind)
        legacy.mkdir(exist_ok=True)
        (legacy / "preserve.txt").write_text("legacy candidate\n")
        env = dict(self.env, KIND=kind, STATE_DIRECTORY=str(state), **extra)
        args = ["bash", str(self.scripts[kind])]
        if kind != "langfuse": args.append(kind)
        return subprocess.Popen(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def events(self, kind):
        path = self.audit / (kind + ".events")
        return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []

    def test_parallel_proposals_have_independent_refs_and_leave_runtime_untouched(self):
        processes = {k: self.start(k, BARRIER="1") for k in ("fast", "slow", "langfuse")}
        try:
            # Emulate the runtime updater fetching while all proposal builds overlap.
            self.git(self.native, "fetch", "--quiet", "origin")
            for kind, process in processes.items():
                stdout, stderr = process.communicate(timeout=25)
                self.assertEqual(process.returncode, 0, (kind, stdout, stderr))
        finally:
            for process in processes.values():
                if process.poll() is None: process.kill(); process.communicate()
        common = []
        for kind in processes:
            events = self.events(kind); builds = [e for e in events if e['type'] == 'build']
            push = next(e for e in events if e['type'] == 'push')
            self.assertEqual(len(builds), 1 if kind == "langfuse" else 2)
            self.assertTrue(all(e['head'] == push['head'] and e['clean'] and not e['alternates'] for e in builds))
            self.assertTrue(all(tuple(i) not in self.objects for i in builds[0]['objects']))
            self.assertLess(max(i for i, e in enumerate(events) if e['type'] == 'build'), events.index(push))
            common.append(builds[0]['common'])
            branch = "auto/langfuse-v4" if kind == "langfuse" else "auto/lock-" + kind
            self.assertEqual(self.git(self.remote, 'rev-parse', 'refs/heads/' + branch).stdout.strip(), push['head'])
            state = self.root / ("state-" + kind)
            self.assertEqual(list(state.glob('clone.*' if kind == "langfuse" else kind + '-clone.*')), [])
            self.assertTrue((state / ("worktree" if kind == "langfuse" else kind) / "preserve.txt").exists())
        self.assertEqual(len(set(common)), 3)
        self.assertTrue(all(p != str(self.native / '.git') for p in common))
        self.assertEqual(self.snapshot(self.native), self.before)
        self.assertEqual(self.git(self.remote, 'rev-parse', 'main').stdout.strip(), self.base)

    def test_failed_build_keeps_candidate_and_does_not_publish(self):
        for kind in ('fast', 'langfuse'):
            with self.subTest(kind=kind):
                process = self.start(kind, FAIL_BUILD='1')
                stdout, stderr = process.communicate(timeout=10)
                self.assertNotEqual(process.returncode, 0, (stdout, stderr))
                pattern = 'clone.*' if kind == 'langfuse' else 'fast-clone.*'
                retained = list((self.root / ('state-' + kind)).glob(pattern))
                self.assertEqual(len(retained), 1)
                self.assertTrue((retained[0] / '.git').is_dir())
                self.assertNotEqual(self.git(retained[0], 'rev-parse', 'HEAD').stdout.strip(), self.base)
                self.assertIn('retained clone:', stderr)
                self.assertFalse(any(e['type'] == 'push' for e in self.events(kind)))
                branch = 'auto/langfuse-v4' if kind == 'langfuse' else 'auto/lock-fast'
                self.assertEqual(self.git(self.remote, 'show-ref', '--verify', 'refs/heads/' + branch, check=False).returncode, 128)
                self.assertEqual(self.snapshot(self.native), self.before)

    def test_langfuse_no_change_uses_upstream_and_cleans_own_clone(self):
        process = self.start('langfuse', RELEASE='v4.1.0')
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, (stdout, stderr))
        self.assertFalse((self.audit / 'langfuse.events').exists())
        self.assertEqual(list((self.root / 'state-langfuse').glob('clone.*')), [])
        self.assertTrue((self.root / 'state-langfuse/worktree/preserve.txt').exists())
        self.assertEqual(self.snapshot(self.native), self.before)

    def test_clone_and_commit_failures_keep_candidates_without_publish(self):
        for kind in ('fast', 'langfuse'):
            for failure in ('clone', 'commit'):
                with self.subTest(kind=kind, failure=failure):
                    state = self.root / ('state-' + kind)
                    pattern = 'clone.*' if kind == 'langfuse' else 'fast-clone.*'
                    previous = set(state.glob(pattern))
                    process = self.start(kind, FAIL_GIT=failure)
                    stdout, stderr = process.communicate(timeout=10)
                    self.assertEqual(process.returncode, 23, (stdout, stderr))
                    self.assertEqual(self.events(kind)[-1], {'type': 'injected-failure', 'command': failure})
                    retained = set(state.glob(pattern)) - previous
                    self.assertEqual(len(retained), 1)
                    candidate = retained.pop()
                    self.assertEqual((candidate / '.git').is_dir(), failure == 'commit')
                    if failure == 'commit':
                        self.assertEqual(self.git(candidate, 'rev-parse', 'HEAD').stdout.strip(), self.base)
                        self.assertEqual(self.git(candidate, 'diff', '--cached', '--quiet', check=False).returncode, 1)
                    self.assertIn('retained clone:', stderr)
                    self.assertFalse(any(e['type'] == 'push' for e in self.events(kind)))
                    branch = 'auto/langfuse-v4' if kind == 'langfuse' else 'auto/lock-fast'
                    self.assertEqual(self.git(self.remote, 'show-ref', '--verify', 'refs/heads/' + branch, check=False).returncode, 128)
                    self.assertEqual(self.snapshot(self.native), self.before)

    def test_clones_use_global_identity_and_helper_without_runtime_local_overrides(self):
        self.command('global-credential', """
            import sys
            sys.stdin.read()
            if sys.argv[1] == 'get':
                print('username=synthetic-global')
                print('password=fixed-fake-global-password')
        """)
        self.command('runtime-credential', """
            import sys
            sys.stdin.read()
            if sys.argv[1] == 'get':
                print('username=synthetic-runtime')
                print('password=fixed-fake-runtime-password')
        """)
        self.git(self.root, 'config', '--file', str(self.config), 'credential.helper', shlex.quote(str(self.bin / 'global-credential')))
        self.git(self.native, 'config', '--local', 'user.name', 'Runtime Only')
        self.git(self.native, 'config', '--local', 'user.email', 'runtime@example.invalid')
        hooks = self.root / 'runtime-hooks'
        hooks.mkdir()
        hook = hooks / 'pre-commit'
        hook_marker = self.root / 'runtime-hook-ran'
        hook.write_text('#!/bin/sh\nprintf ran > ' + shlex.quote(str(hook_marker)) + '\nexit 91\n')
        hook.chmod(0o755)
        self.git(self.native, 'config', '--local', 'core.hooksPath', str(hooks))
        self.git(self.native, 'config', '--local', '--add', 'credential.helper', '')
        self.git(self.native, 'config', '--local', '--add', 'credential.helper', shlex.quote(str(self.bin / 'runtime-credential')))
        self.env['GIT_TERMINAL_PROMPT'] = '0'
        native_head = self.git(self.native, 'rev-parse', 'HEAD').stdout
        blocked_commit = self.git(self.native, 'commit', '--allow-empty', '-qm', 'synthetic hook probe', check=False)
        self.assertNotEqual(blocked_commit.returncode, 0)
        self.assertEqual(hook_marker.read_text(), 'ran')
        self.assertEqual(self.git(self.native, 'rev-parse', 'HEAD').stdout, native_head)
        native_credential = self.git(self.native, 'credential', 'fill', input='protocol=https\nhost=synthetic.invalid\n\n').stdout
        self.assertIn('username=synthetic-runtime', native_credential)
        self.before = self.snapshot(self.native)
        for kind in ('fast', 'langfuse'):
            with self.subTest(kind=kind):
                process = self.start(kind, CHECK_CREDENTIALS='1')
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, (stdout, stderr))
                builds = [e for e in self.events(kind) if e['type'] == 'build']
                self.assertTrue(builds)
                self.assertTrue(all(e['head'] != self.base and e['clean'] for e in builds))
                self.assertTrue(all(e['identity'] == ['Synthetic', 'synthetic@example.invalid', 'Synthetic', 'synthetic@example.invalid'] for e in builds))
                self.assertTrue(all(not e['localIdentityHooksCredentials'] for e in builds))
                self.assertEqual(self.snapshot(self.native), self.before)


if __name__ == '__main__':
    unittest.main()
