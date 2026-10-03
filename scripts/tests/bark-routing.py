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
                        body = re.sub(r'\$\{(?:pkgs\.[^}]+|config.systemd.package)\}/bin/(\w+)', lambda m: str(base / m[1]) if m[1] in ('curl', 'journalctl') else shutil.which(m[1]), body)
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


if __name__ == '__main__':
    unittest.main()
