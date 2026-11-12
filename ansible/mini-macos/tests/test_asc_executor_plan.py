import importlib.util
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('asc_executor_plan', Path(__file__).resolve().parents[1] / 'scripts/asc_executor_plan.py')
plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plan)


class ExecutorPlan(unittest.TestCase):
    def repo(self, root):
        repo = root / 'repo'
        repo.mkdir()
        subprocess.run(['git', 'init', '-q', str(repo)], check=True)
        (repo / 'scripts').mkdir()
        for name in plan.FILES:
            (repo / 'scripts' / name).write_text('# fixture ' + name + '\n')
        subprocess.run(['git', '-C', str(repo), 'add', *['scripts/' + name for name in plan.FILES]], check=True)
        subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'], check=True)
        return repo, plan.git(repo, 'rev-parse', 'HEAD').decode().strip()

    def test_committed_candidate_and_existing_output_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo, sha = self.repo(root)
            output = root / 'candidate'
            manifest = plan.generate(repo, sha, output)
            self.assertEqual(manifest['sourceRevision'], sha)
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            self.assertEqual((output / 'manifest.json').stat().st_mode & 0o777, 0o600)
            self.assertEqual((output / plan.FILES[0]).read_bytes(), plan.git(repo, 'show', sha + ':scripts/' + plan.FILES[0]))
            self.assertEqual(manifest['files'][0]['sha256'], hashlib.sha256((output / plan.FILES[0]).read_bytes()).hexdigest())
            before = (output / 'manifest.json').read_bytes()
            with self.assertRaises(FileExistsError):
                plan.generate(repo, sha, output)
            self.assertEqual((output / 'manifest.json').read_bytes(), before)

    def test_dirty_source_and_short_revision_fail_before_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo, sha = self.repo(root)
            output = root / 'candidate'
            with self.assertRaises(ValueError):
                plan.generate(repo, sha[:12], output)
            (repo / 'scripts' / plan.FILES[0]).write_text('# unreviewed\n')
            with self.assertRaisesRegex(ValueError, 'uncommitted'):
                plan.generate(repo, sha, output)
            self.assertFalse(output.exists())

    def test_check_mode_validates_without_creating_candidate(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo, sha = self.repo(root)
            output = root / 'candidate'
            subprocess.run(['python3', str(Path(plan.__file__)), '--source', str(repo), '--revision', sha,
                            '--output', str(output), '--check'], check=True)
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
