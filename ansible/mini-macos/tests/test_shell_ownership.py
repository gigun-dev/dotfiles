"""Exercise the real bootstrap shell-link block without running installers."""
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]


class ShellOwnership(unittest.TestCase):
    def test_bootstrap_host_ownership(self):
        source = (ROOT / 'bootstrap.sh').read_text()
        setup = source[source.index('# mini の5リンク'):source.index('\nlink() {')]
        links = source[source.index('if [[ "$mini_shell_ansible" == 0 ]]; then', source.index('\nlink() {')):source.index('# global ignore')]
        block = setup + links
        block = block.replace('/usr/sbin/scutil', 'scutil')
        for system, host, expected in [('Darwin', 'mini', 1), ('Darwin', 'MBPM4Pro', 6), ('Linux', 'mini', 6)]:
            with self.subTest(system=system, host=host):
                script = f'''DOTFILES_DIR=/repo
HOME=/fixture
uname() {{ echo {system}; }}
scutil() {{ echo {host}; }}
mkdir() {{ printf '%s\\n' "$@" >&2; }}
link() {{ printf '%s\\n' "$2"; }}
''' + block
                result = subprocess.run(['bash', '-eu', '-c', script], check=True, text=True, capture_output=True)
                paths = result.stdout.splitlines()
                self.assertEqual(len(paths), expected)
                self.assertIn('/fixture/.zprofile', paths)
                if host == 'mini' and system == 'Darwin':
                    self.assertEqual(paths, ['/fixture/.zprofile'])
                    self.assertNotIn('/fixture/.config/sheldon', result.stderr)
                    self.assertNotIn('/fixture/.config/zeno', result.stderr)
