#!/usr/bin/env python3
"""Exercise both shipped notification transports without sending notifications."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]


class Routing(unittest.TestCase):
    def test_transports(self):
        for custom in (False, True, "insecure"):
            for hook in (False, True):
                with self.subTest(custom=custom, hook=hook), tempfile.TemporaryDirectory() as directory:
                    base = Path(directory)
                    (base / 'claude/hooks').mkdir(parents=True)
                    (base / 'secrets').mkdir()
                    (base / '.ssh').mkdir()
                    (base / 'secrets/bark-env.age').touch()
                    (base / '.ssh/id_ed25519').touch()
                    env = dict(os.environ, HOME=str(base), FIXTURE=str(base), BARK_DEVICE_KEY='fixture-key', BARK_ENCRYPT_KEY='0123456789abcdefABCDEFGHIJKLMNOP', BARK_ENCRYPT_IV='i' * 16)
                    if custom:
                        env['BARK_PUSH_URL'] = ('http://' if custom == 'insecure' else 'https://') + 'fixture.invalid/private/key'
                    else:
                        env.pop('BARK_PUSH_URL', None)
                    for name, body in {
                        'curl': "#!/usr/bin/env python3\nimport json,os,sys\nfrom pathlib import Path\nPath(os.environ['FIXTURE'],'request').write_text(json.dumps(sys.argv[1:]))\nprint('{\"code\":200}')\n",
                        'journalctl': '#!/bin/sh\nprintf fixture-body',
                        'age': '#!/bin/sh\nenv | sort | sed -n "/^BARK_/p"',
                    }.items():
                        path = base / name
                        path.write_text(body)
                        path.chmod(0o755)
                    env['PATH'] = str(base) + os.pathsep + env['PATH']
                    if hook:
                        script = base / 'claude/hooks/bark-notify.sh'
                        script.write_text((ROOT / 'claude/hooks/bark-notify.sh').read_text())
                        transcript = base / 'transcript'
                        transcript.write_text('{"url":"https://claude.ai/code/session_fixture"}\n')
                        data = json.dumps({'title': 'fixture-title', 'message': 'fixture-body', 'cwd': '/fixture', 'transcript_path': str(transcript)})
                        args = ['bash', str(script)]
                    else:
                        source = (ROOT / 'nix/modules/nixos/mini-vm.nix').read_text()
                        body = source.split('barkNotifyUnitFailure = pkgs.writeShellScript "bark-notify-unit-failure" \'\'\n', 1)[1].split("\n  '';", 1)[0]
                        body = re.sub(r'\$\{(?:pkgs\.[^}]+|config.systemd.package)\}/bin/(\w+)', lambda m: str(base / m[1]) if m[1] in ('curl', 'journalctl', 'systemctl') else shutil.which(m[1]), body)
                        body = body.replace('${pkgs.cacert}', '/fixture').replace("''${", '${').replace(r'\\n', r'\n')
                        script = base / 'helper'
                        script.write_text(body)
                        data = ''
                        args = ['bash', str(script), 'fixture.service', 'fixture-title']
                    result = subprocess.run(args, input=data, env=env, capture_output=True, text=True, timeout=10)
                    if custom == 'insecure':
                        self.assertEqual(result.returncode, 0 if hook else 1)
                        self.assertFalse((base / 'request').exists())
                        continue
                    self.assertEqual(result.returncode, 0, result.stderr)
                    for _ in range(100):
                        if (base / 'request').exists():
                            break
                        time.sleep(0.02)
                    request = json.loads((base / 'request').read_text())
                    self.assertEqual(request[-1], env.get('BARK_PUSH_URL', 'https://api.day.app/fixture-key'))
                    self.assertTrue(any(arg.startswith('ciphertext=') for arg in request))
                    self.assertIn('iv=' + 'i' * 16, request)
                    self.assertNotIn('https://fixture.invalid', result.stdout + result.stderr)


class UnitFailureBody(unittest.TestCase):
    """Run the real helper with stub journalctl/systemctl/curl and inspect the decrypted-before payload."""

    KEY = '0123456789abcdefABCDEFGHIJKLMNOP'
    DEVICE = 'device-key-secret'

    def run_helper(self, unit, journal, props='Result=exit-code\nExecMainStatus=1\n'):
        source = (ROOT / 'nix/modules/nixos/mini-vm.nix').read_text()
        body = source.split('barkNotifyUnitFailure = pkgs.writeShellScript "bark-notify-unit-failure" \'\'\n', 1)[1].split("\n  \'\';", 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            body = re.sub(r'\$\{(?:pkgs\.[^}]+|config.systemd.package)\}/bin/(\w+)', lambda m: str(base / m[1]) if m[1] in ('curl', 'journalctl', 'systemctl', 'openssl') else shutil.which(m[1]), body)
            body = body.replace('${pkgs.cacert}', '/fixture').replace("\'\'${", '${')
            (base / 'helper').write_text(body)
            if journal is not None:
                (base / 'journal.txt').write_text(journal)
            (base / 'props.txt').write_text(props)
            stubs = {
                'journalctl': '#!/bin/sh\n[ -f "$FIXTURE/journal.txt" ] || exit 1\ncat "$FIXTURE/journal.txt"\n',
                'systemctl': '#!/bin/sh\ncat "$FIXTURE/props.txt"\n',
                # openssl stub: record the plaintext payload instead of encrypting it.
                'openssl': '#!/bin/sh\ncat > "$FIXTURE/payload"\necho ciphertext\n',
                'curl': '#!/bin/sh\necho \'{"code":200}\'\n',
            }
            for name, text in stubs.items():
                (base / name).write_text(text)
                (base / name).chmod(0o755)
            env = dict(os.environ, FIXTURE=str(base), LC_ALL='en_US.UTF-8', BARK_DEVICE_KEY=self.DEVICE, BARK_ENCRYPT_KEY=self.KEY, BARK_ENCRYPT_IV='i' * 16)
            env.pop('BARK_PUSH_URL', None)
            result = subprocess.run(['bash', str(base / 'helper'), unit, 'title'], env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads((base / 'payload').read_text())
            for secret in (self.KEY, self.DEVICE):
                self.assertNotIn(secret, payload['body'])
                self.assertNotIn(secret, result.stdout + result.stderr)
            self.assertEqual(payload['title'], 'title')
            self.assertLessEqual(len(payload['body']), 320)
            return payload['body']

    def test_signed_url_redacted(self):
        body = self.run_helper('x.service', 'fetch https://d1.cloudfront.net/a/b?Expires=1&Signature=SIG&Key-Pair-Id=K failed: timeout\n')
        self.assertIn('https://d1.cloudfront.net/a/b?…', body)
        for leak in ('Signature', 'SIG', 'Expires', 'Key-Pair-Id'):
            self.assertNotIn(leak, body)

    def test_example_langfuse(self):
        journal = (
            'Pulling layer 99MB\n'
            'GET https://d1.cloudfront.net/layer?Expires=1&Signature=SIG&Key-Pair-Id=K: dial tcp 3.169.5.83:443: i/o timeout\n'
            "langfuse.service: Main process exited, code=exited, status=1/FAILURE\n"
            "langfuse.service: Failed with result 'exit-code'.\n"
            'langfuse.service: Consumed 1.2s CPU time, 100M memory peak.\n'
            'Failed to start langfuse.service.\n')
        body = self.run_helper('langfuse.service', journal)
        lines = body.split('\n')
        self.assertEqual(lines[0], 'langfuse.service: exit-code (exit 1)')
        self.assertIn('dial tcp 3.169.5.83:443: i/o timeout', lines[1])
        self.assertIn('https://d1.cloudfront.net/layer?…', lines[1])
        self.assertEqual(lines[-1], '詳細: journalctl -u langfuse.service -n 50')
        self.assertNotIn('関連して失敗', body)
        self.assertNotIn('Consumed', body)
        print('\n--- langfuse body ---\n' + body)

    def test_example_autoswitch_causal_hint(self):
        journal = (
            'Starting dotfiles-autoswitch.service...\n'
            'autoswitch: switching\n'
            'Running systemd-run -E LOCALE_ARCHIVE=/x -E PATH=/y /nix/store/z/bin/switch-to-configuration switch\n'
            'warning: the following units failed: langfuse.service\n'
            "langfuse.service: Failed with result 'exit-code'.\n"
            "dotfiles-autoswitch.service: Failed with result 'exit-code'.\n"
            'dotfiles-autoswitch.service: Consumed 3min CPU time, 2G memory peak, IO bytes read 1M.\n')
        body = self.run_helper('dotfiles-autoswitch.service', journal)
        lines = body.split('\n')
        self.assertEqual(lines[0], 'dotfiles-autoswitch.service: exit-code (exit 1)')
        self.assertIn('the following units failed: langfuse.service', lines[1])
        self.assertIn('関連して失敗: langfuse.service', lines)
        for noise in ('systemd-run', 'LOCALE_ARCHIVE', 'Consumed'):
            self.assertNotIn(noise, body)
        print('\n--- autoswitch body ---\n' + body)

    def test_self_failure_is_not_related(self):
        body = self.run_helper('a.service', "a.service: Failed with result 'exit-code'.\nerror: boom\n")
        self.assertNotIn('関連して失敗', body)
        self.assertIn('error: boom', body)

    def test_long_cause_truncated(self):
        body = self.run_helper('a.service', 'error: ' + 'x' * 500 + '\n')
        self.assertLessEqual(len(body), 320)
        self.assertIn('…', body)

    def test_missing_journal_fallback(self):
        self.assertEqual(self.run_helper('a.service', None), '(journal を取得できなかった)')


if __name__ == '__main__':
    unittest.main()
