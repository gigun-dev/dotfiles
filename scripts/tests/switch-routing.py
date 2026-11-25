"""Execute the built switch app and SSH transport using only fixture commands."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


class Switch(unittest.TestCase):
    def setUp(self):
        # The app is a Nushell script; drop its store shebang and run it with TEST_NU.
        self.source = Path(os.environ['SWITCH_APP']).read_text().split('\n', 1)[1]
        self.system = os.environ['TEST_SYSTEM']
        self.darwin = self.system.endswith('darwin')
        self.transport = re.search(r'GIT_SSH_COMMAND=(/nix/store/[^\s"\\]+)', self.source)
        if self.darwin:
            self.assertIsNotNone(self.transport)

    def executable(self, path, body):
        path.write_text('#!' + os.environ['TEST_SH'] + '\n' + body)
        path.chmod(0o755)

    def test_routes_arguments_and_failure_without_upload(self):
        for nixos in (False, True):
            for status in (0, 42):
                with self.subTest(nixos=nixos, status=status), tempfile.TemporaryDirectory() as temp:
                    base = Path(temp)
                    log = base / 'calls'
                    sudo_log = base / 'sudo-args'
                    marker = base / 'NIXOS'
                    if nixos:
                        marker.touch()
                    bin = base / 'bin'
                    bin.mkdir()
                    # No store executable, native sudo/ssh, or real Homebrew runs.
                    body = re.sub(r'/nix/store/[^\s"\']+/bin/([A-Za-z0-9_-]+)',
                                  lambda m: str(bin / m[1]), self.source)
                    body = body.replace('/etc/NIXOS', str(marker))
                    body = body.replace('/opt/homebrew/bin/brew', str(bin / 'brew'))
                    body = body.replace('/usr/local/bin/brew', str(bin / 'brew'))
                    body = body.replace('/usr/bin/sudo', str(bin / 'sudo'))
                    body = body.replace('/run/current-system/brew-bundle', str(bin / 'brew-bundle'))
                    transport = bin / 'git-ssh-as-user'
                    if self.darwin:
                        body = body.replace(self.transport[1], str(transport))
                    for command in ('darwin-rebuild', 'nixos-rebuild', 'home-manager', 'cachix', 'curl', 'nix'):
                        checks = ''
                        if command == 'darwin-rebuild':
                            checks = '''[ "${GIT_SSH_COMMAND-}" = "$EXPECTED_TRANSPORT" ] || exit 91
[ "${SSH_AUTH_SOCK-}" = "$EXPECTED_SOCKET" ] || exit 92
[ "$HOME" = "$FAKE_ROOT_HOME" ] || exit 93
[ -z "${UNRELATED_SECRET-}" ] || exit 94
'''
                        self.executable(bin / command, checks +
                            'printf "%s\\n" "' + command + ':$*" >> "$CALL_LOG"\n' +
                            ('exit 99\n' if command in ('cachix', 'curl', 'nix') else 'exit "$STATUS"\n'))
                    # Homebrew runs as the invoking user, after the system switch succeeded.
                    self.executable(bin / 'brew-bundle', '''[ "$HOME" != "$FAKE_ROOT_HOME" ] || exit 95
printf '%s\\n' "brew-bundle:$*" >> "$CALL_LOG"
''')
                    self.executable(bin / 'sudo', '''printf '%s\\n' "$@" >> "$SUDO_LOG"
preserve_socket=0
transport=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --preserve-env=SSH_AUTH_SOCK) preserve_socket=1; shift ;;
    GIT_SSH_COMMAND=*) transport=${1#*=}; shift ;;
    *) break ;;
  esac
done
[ "$preserve_socket" = 1 ] || unset SSH_AUTH_SOCK
unset GIT_SSH_COMMAND UNRELATED_SECRET
if [ -n "$transport" ]; then export GIT_SSH_COMMAND="$transport"; fi
HOME=$FAKE_ROOT_HOME
export HOME
exec "$@"
''')
                    socket = str(base / 'fixture-agent.sock')
                    env = {
                        'HOME': str(base), 'PATH': str(bin), 'CALL_LOG': str(log),
                        'SUDO_LOG': str(sudo_log), 'STATUS': str(status),
                        'SSH_AUTH_SOCK': socket, 'EXPECTED_SOCKET': socket,
                        'EXPECTED_TRANSPORT': str(transport), 'FAKE_ROOT_HOME': str(base / 'root-home'),
                        'UNRELATED_SECRET': 'synthetic-do-not-preserve',
                        'GIT_SSH_COMMAND': 'synthetic-untrusted-inherited-command',
                    }
                    app = base / 'switch.nu'
                    app.write_text(body)
                    result = subprocess.run([os.environ['TEST_NU'], '--no-config-file', str(app),
                                             '--option', 'fixture value'], env=env,
                                            capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, status, result.stderr)
                    expected = []
                    if self.darwin:
                        expected = [f'darwin-rebuild:switch --flake .#gigun-{self.system} --option fixture value']
                        if status == 0:
                            expected.append('brew-bundle:')
                        self.assertEqual(sudo_log.read_text().splitlines(), [
                            '--preserve-env=SSH_AUTH_SOCK', f'GIT_SSH_COMMAND={transport}',
                            str(bin / 'darwin-rebuild'), 'switch', '--flake', f'.#gigun-{self.system}',
                            '--option', 'fixture value',
                        ])
                    else:
                        if nixos:
                            expected.append('nixos-rebuild:switch --flake .#mini-vm --option fixture value')
                        if not nixos or status == 0:
                            target = 'mini-vm' if nixos else self.system
                            expected.append(f'home-manager:switch --flake .#gigun-{target} --option fixture value')
                    self.assertEqual(log.read_text().splitlines(), expected)

    def test_git_ssh_transport_runs_native_ssh_as_the_declared_user(self):
        if not self.darwin:
            self.skipTest('Only Darwin has a privileged evaluator with user SSH transport')
        source = Path(self.transport[1]).read_text()
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            sudo = base / 'sudo'
            ssh = base / 'ssh'
            sudo_log = base / 'sudo-args'
            ssh_log = base / 'ssh-args'
            environment = base / 'ssh-environment'
            self.executable(sudo, '''printf '%s\\n' "$@" > "$SUDO_LOG"
[ "$1" = '--user=gigun' ] || exit 81
[ "$2" = '--set-home' ] || exit 82
[ "$3" = '--preserve-env=SSH_AUTH_SOCK' ] || exit 83
[ "$4" = '--' ] || exit 84
shift 4
HOME=$FAKE_USER_HOME
export HOME
exec "$@"
''')
            self.executable(ssh, '''printf '%s\\n' "$@" > "$SSH_LOG"
printf '%s\\n' "$HOME" "$SSH_AUTH_SOCK" > "$SSH_ENVIRONMENT"
''')
            wrapper = base / 'transport'
            self.executable(wrapper, source.replace('/usr/bin/sudo', str(sudo)).replace('/usr/bin/ssh', str(ssh)))
            arguments = ['-p', '443', 'git@github.com', 'fixture argument with spaces']
            socket = str(base / 'fixture-agent.sock')
            user_home = str(base / 'user-home')
            env = {
                'HOME': str(base / 'root-home'), 'PATH': str(base), 'SUDO_LOG': str(sudo_log),
                'SSH_LOG': str(ssh_log), 'SSH_ENVIRONMENT': str(environment),
                'SSH_AUTH_SOCK': socket, 'FAKE_USER_HOME': user_home,
            }
            result = subprocess.run([str(wrapper), *arguments], env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(sudo_log.read_text().splitlines(), [
                '--user=gigun', '--set-home', '--preserve-env=SSH_AUTH_SOCK', '--', str(ssh), *arguments,
            ])
            self.assertEqual(ssh_log.read_text().splitlines(), arguments)
            self.assertEqual(environment.read_text().splitlines(), [user_home, socket])


if __name__ == '__main__':
    unittest.main()
