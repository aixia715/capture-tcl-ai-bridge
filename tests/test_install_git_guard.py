"""Git preflight checks using real repositories and the real installer."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == "nt" and shutil.which("git"), "Windows and Git required")
class InstallGitGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        shutil.copyfile(ROOT / "install.ps1", self.source / "install.ps1")
        self.git("init")
        self.git("add", ".")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "commit", "-m", "baseline")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.source), *args],
                              check=True, capture_output=True)

    def install(self, *args):
        env = dict(os.environ, LOCALAPPDATA=str(self.root / "local"))
        result = subprocess.run([
            shutil.which("powershell") or shutil.which("pwsh"),
            "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", str(self.source / "install.ps1"),
            "-PythonTarget", str(self.root / "target"), *args,
        ], cwd=ROOT, env=env, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "target").exists())
        self.assertFalse((self.root / "local").exists())
        return result.stdout + result.stderr

    def test_clean_checkout_reaches_runtime_preflight(self):
        self.assertIn("bundled runtime is missing", self.install())

    def test_unstaged_change_blocks_even_force(self):
        with (self.source / "install.ps1").open("a") as stream:
            stream.write("\n# local edit\n")
        self.assertIn("Git working tree is dirty", self.install("-ForceOverwriteModified"))

    def test_staged_change_blocks(self):
        (self.source / "new.txt").write_text("staged")
        self.git("add", "new.txt")
        self.assertIn("Git working tree is dirty", self.install())

    def test_untracked_change_blocks(self):
        (self.source / "new.txt").write_text("untracked")
        self.assertIn("Git working tree is dirty", self.install())

    def test_ignored_file_does_not_block(self):
        (self.source / ".git" / "info" / "exclude").write_text("ignored.txt\n")
        (self.source / "ignored.txt").write_text("ignored")
        self.assertIn("bundled runtime is missing", self.install())

    def test_broken_git_metadata_fails_closed(self):
        (self.source / ".git").rename(self.root / "saved-git")
        (self.source / ".git").write_text("gitdir: missing\n")
        self.assertIn("Could not verify Git status", self.install())

    def test_release_without_git_reaches_runtime_preflight(self):
        (self.source / ".git").rename(self.root / "saved-git")
        self.assertIn("bundled runtime is missing", self.install())

    def test_worktree_git_file_detects_dirty_state(self):
        worktree = self.root / "worktree"
        self.git("worktree", "add", "--detach", str(worktree))
        self.source = worktree
        (self.source / "new.txt").write_text("untracked")
        self.assertIn("Git working tree is dirty", self.install())


if __name__ == "__main__":
    unittest.main()
