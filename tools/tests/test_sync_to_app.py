import importlib.util
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("sync_to_app", Path(__file__).parents[1] / "sync_to_app.py")
sync_to_app = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sync_to_app)


class MirrorSyncTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="toolbox-sync-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.mirror = self.root / "app"
        self.source.mkdir()
        self.mirror.mkdir()
        subprocess.run(["git", "init", "--quiet", str(self.source)], check=True)
        subprocess.run(["git", "-C", str(self.source), "config", "core.autocrlf", "false"], check=True)
        self.backups = []

    def tearDown(self):
        # Backups contain only test-owned files in freshly allocated temp dirs.
        for backup in self.backups:
            shutil.rmtree(backup)

    def write(self, root, relative, content):
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def synchronize(self, **kwargs):
        changes, backup = sync_to_app.sync(self.source, self.mirror, **kwargs)
        if backup:
            self.backups.append(backup)
        return changes, backup

    def test_sync_includes_native_sources_docs_and_new_files_but_preserves_local_state(self):
        self.write(self.source, ".gitignore", b"build/\nlocal.properties\n")
        expected = {
            "android/app/src/main/kotlin/com/toolbox/app/MainActivity.kt": b"preload wasm\n",
            "windows/runner/main.cpp": b"native entry\r\n",
            "docs/guide.md": "开发指南".encode(),
            "LICENSE": b"MIT\n",
        }
        for relative, content in expected.items():
            self.write(self.source, relative, content)
        self.write(self.source, "build/app.exe", b"source build")
        self.write(self.source, "local.properties", b"source machine")
        self.write(self.mirror, "build/app.exe", b"mirror build")
        self.write(self.mirror, "local.properties", b"mirror machine")
        self.write(self.mirror, "personal.txt", b"user notes")
        self.write(self.mirror, ".git/config", b"mirror git")
        self.synchronize()
        for relative, content in expected.items():
            self.assertEqual((self.mirror / relative).read_bytes(), content)
        self.assertEqual((self.mirror / "build/app.exe").read_bytes(), b"mirror build")
        self.assertEqual((self.mirror / "local.properties").read_bytes(), b"mirror machine")
        self.assertEqual((self.mirror / "personal.txt").read_bytes(), b"user notes")
        self.assertEqual((self.mirror / ".git/config").read_bytes(), b"mirror git")
        self.assertEqual(self.synchronize(check=True), ([], None))

    def test_check_is_read_only_and_update_retains_recoverable_backup(self):
        self.write(self.source, "lib/main.dart", b"new")
        self.write(self.mirror, "lib/main.dart", b"old")
        changes, backup = self.synchronize(check=True)
        self.assertEqual([(item[0], item[1]) for item in changes], [("update", "lib/main.dart")])
        self.assertIsNone(backup)
        self.assertEqual((self.mirror / "lib/main.dart").read_bytes(), b"old")
        _, backup = self.synchronize()
        self.assertEqual((backup / "lib/main.dart").read_bytes(), b"old")
        self.assertEqual((self.mirror / "lib/main.dart").read_bytes(), b"new")

    def test_deleted_tracked_file_is_removed_and_backed_up(self):
        obsolete = self.write(self.source, "lib/obsolete.dart", b"old source")
        subprocess.run(["git", "-C", str(self.source), "add", "."], check=True)
        obsolete.unlink()
        self.write(self.mirror, "lib/obsolete.dart", b"mirror version")
        changes, backup = self.synchronize()
        self.assertEqual(changes[0][0], "remove")
        self.assertFalse((self.mirror / "lib/obsolete.dart").exists())
        self.assertEqual((backup / "lib/obsolete.dart").read_bytes(), b"mirror version")

    def test_overlapping_roots_and_non_repository_source_are_rejected(self):
        for destination in (self.source, self.source / "nested", self.root):
            with self.subTest(destination=destination), self.assertRaises(ValueError):
                sync_to_app.sync(self.source, destination)
        subdir = self.source / "nested"
        subdir.mkdir()
        with self.assertRaisesRegex(ValueError, "repository root"):
            sync_to_app.sync(subdir, self.mirror)

    def test_inventory_removes_file_even_after_git_index_forgets_it(self):
        self.write(self.source, "old.txt", b"old")
        subprocess.run(["git", "-C", str(self.source), "add", "."], check=True)
        self.synchronize()
        subprocess.run(["git", "-C", str(self.source), "rm", "--force", "old.txt"], check=True, capture_output=True)
        changes, backup = self.synchronize()
        self.assertEqual([(item[0], item[1]) for item in changes], [("remove", "old.txt")])
        self.assertFalse((self.mirror / "old.txt").exists())
        self.assertEqual((backup / "old.txt").read_bytes(), b"old")

    def test_invalid_repository_paths_cannot_escape_or_touch_git(self):
        for relative in ("../outside", "/absolute", ".git/config", ".GIT/config", ".git./config", "C:/absolute", "dir\\outside"):
            with self.subTest(relative=relative), self.assertRaises(ValueError):
                sync_to_app.safe_file(self.mirror, relative)

    def test_file_ancestor_collision_is_rejected_before_any_copy(self):
        self.write(self.source, "a.txt", b"new")
        self.write(self.source, "z/file.txt", b"new nested file")
        self.write(self.mirror, "z", b"user file")
        with self.assertRaisesRegex(ValueError, "Expected a directory"):
            self.synchronize()
        self.assertFalse((self.mirror / "a.txt").exists())
        self.assertEqual((self.mirror / "z").read_bytes(), b"user file")

    def test_linked_destination_is_rejected_before_any_copy(self):
        self.write(self.source, "a.txt", b"new")
        self.write(self.source, "z/file.txt", b"must stay inside")
        outside = self.root / "outside"
        outside.mkdir()
        try:
            (self.mirror / "z").symlink_to(outside, target_is_directory=True)
        except OSError:
            if os.name != "nt":
                raise
            subprocess.run(
                ["cmd", "/c", "mklink", "/J", str(self.mirror / "z"), str(outside)],
                check=True, capture_output=True,
            )
        with self.assertRaisesRegex(ValueError, "linked path"):
            self.synchronize()
        self.assertFalse((self.mirror / "a.txt").exists())
        self.assertFalse((outside / "file.txt").exists())


if __name__ == "__main__":
    unittest.main()
