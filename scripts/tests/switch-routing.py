"""Execute the evaluated shared switch body with rebuild/upload commands replaced by stubs."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

class Switch(unittest.TestCase):
    def test_routes_arguments_and_failure_without_upload(self):
        source = Path(os.environ['SWITCH_BODY']).read_text()
        system = os.environ['TEST_SYSTEM']
        darwin = system.endswith('darwin')
        for nixos in (False, True):
            for status in (0, 42):
                with self.subTest(nixos=nixos, status=status), tempfile.TemporaryDirectory() as temp:
                    base = Path(temp)
                    log = base / 'calls'
                    marker = base / 'NIXOS'
                    if nixos:
                        marker.touch()
                    bin = base / 'bin'
                    bin.mkdir()
                    # All absolute store executables are redirected; none runs on the host.
                    body = re.sub(r'/nix/store/[^\s"\']+/bin/([A-Za-z0-9_-]+)',
                                  lambda m: str(bin / m[1]), source)
                    body = body.replace('/etc/NIXOS', str(marker))
                    # The evaluated Darwin body probes these host paths directly. Keep this
                    # routing test hermetic: the cleanup guard has its own boundary and must
                    # never inspect the developer machine's real Homebrew installation.
                    body = body.replace('/opt/homebrew/bin/brew', str(bin / 'brew'))
                    body = body.replace('/usr/local/bin/brew', str(bin / 'brew'))
                    for command in ('darwin-rebuild','nixos-rebuild','home-manager','cachix','curl','nix'):
                        p = bin / command
                        p.write_text('#!' + os.environ['TEST_SH'] + '\n' +
                            'printf "%s\\n" "' + command + ':$*" >> "$CALL_LOG"\n' +
                            ('exit 99\n' if command in ('cachix','curl','nix') else 'exit "$STATUS"\n'))
                        p.chmod(0o755)
                    sudo = bin / 'sudo'
                    sudo.write_text('#!' + os.environ['TEST_SH'] + '\nexec "$@"\n')
                    sudo.chmod(0o755)
                    env = {'HOME':str(base),'PATH':str(bin), 'CALL_LOG':str(log), 'STATUS':str(status)}
                    result = subprocess.run([os.environ['TEST_BASH'], '-c', body + '\napply_switch "$@"',
                                             'fixture', '--option', 'fixture value'], env=env,
                                            capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, status, result.stderr)
                    expected = []
                    if darwin:
                        expected = [f'darwin-rebuild:switch --flake .#gigun-{system} --option fixture value']
                    else:
                        if nixos:
                            expected.append('nixos-rebuild:switch --flake .#mini-vm --option fixture value')
                        if not nixos or status == 0:
                            target = 'mini-vm' if nixos else system
                            expected.append(f'home-manager:switch --flake .#gigun-{target} --option fixture value')
                    self.assertEqual(log.read_text().splitlines(), expected)

if __name__ == '__main__':
    unittest.main()
