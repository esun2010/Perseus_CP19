#!/usr/bin/env python3
"""Dashboard Meld/backup checks use temporary paths and mocked subprocesses."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("dashboard_file_ops", ROOT / "main/dashboard_file_ops.py")
ops = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ops)

sys.path.insert(0, str(ROOT))
from webapp import app as webapp_module


class BackupHelperTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cp-dashboard-backups-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.backups = self.root / "private-backups"
        self.backups.mkdir(mode=0o700)
        self.source = self.root / "etc" / "sample.conf"
        self.source.parent.mkdir()
        self.source.write_text("before\n")
        self.args = lambda **kw: type("Args", (), {"backup_root": str(self.backups), "uid": os.getuid(), "gid": os.getgid(), **kw})()

    def test_backup_before_edit_and_inspection_statuses(self):
        first = ops.backup(self.args(run_id="run-a", script="sample.sh", paths=[str(self.source)]))
        self.source.write_text("after\n")
        new_file = self.source.parent / "created.conf"
        deleted = self.source.parent / "deleted.conf"
        deleted.write_text("saved\n")
        second = ops.backup(self.args(run_id="run-b", script="sample.sh", paths=[str(new_file), str(deleted)]))
        new_file.write_text("now exists\n")
        deleted.unlink()
        self.assertEqual([item["status"] for item in ops.inspect(self.args(id=first["id"]))], ["changed"])
        statuses = [item["status"] for item in ops.inspect(self.args(id=second["id"]))]
        self.assertEqual(statuses, ["created", "deleted"])
        self.assertNotEqual(first["id"], second["id"])

    def test_backup_failure_does_not_produce_catalog_record(self):
        with mock.patch.object(ops.shutil, "copy2", side_effect=PermissionError("denied")):
            with self.assertRaises(PermissionError):
                ops.backup(self.args(run_id="run-fail", script="sample.sh", paths=[str(self.source)]))
        self.assertFalse((self.backups / "catalog.json").exists())

    def test_stage_and_restore_preserve_original_contents(self):
        backup = ops.backup(self.args(run_id="run-restore", script="sample.sh", paths=[str(self.source)]))
        self.source.write_text("modified\n")
        staged = ops.stage(self.args(id=backup["id"], path=str(self.source)))
        self.assertEqual(Path(staged["before"]).read_text(), "before\n")
        self.assertEqual(Path(staged["current"]).read_text(), "modified\n")
        result = ops.restore(self.args(id=backup["id"], path=str(self.source)))
        self.assertEqual(result["restored"], str(self.source))
        self.assertEqual(self.source.read_text(), "before\n")

    def test_repeated_backups_of_one_file_have_distinct_snapshots(self):
        first = ops.backup(self.args(run_id="same-run", script="sample.sh", paths=[str(self.source)]))
        self.source.write_text("second version\n")
        second = ops.backup(self.args(run_id="same-run", script="sample.sh", paths=[str(self.source)]))
        self.assertNotEqual(first["id"], second["id"])
        self.assertEqual(len(ops.read_catalog(self.backups)["backups"]), 2)
        self.assertEqual(Path(first["snapshot"], "files", str(self.source).lstrip("/")).read_text(), "before\n")
        self.assertEqual(Path(second["snapshot"], "files", str(self.source).lstrip("/")).read_text(), "second version\n")

    def test_symlink_sources_are_rejected(self):
        link = self.root / "link"
        link.symlink_to(self.source)
        with self.assertRaises(ValueError):
            ops.backup(self.args(run_id="run-link", script="sample.sh", paths=[str(link)]))


class MeldRouteTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cp-dashboard-meld-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.left = self.root / "left"
        self.right = self.root / "right"
        self.left.write_text("left")
        self.right.write_text("right")
        self.client = webapp_module.app.test_client()

    def test_missing_meld_and_graphical_session_messages(self):
        with mock.patch.object(webapp_module, "_meld_available", return_value=None):
            self.assertIn("not installed", webapp_module._launch_meld(self.left, self.right))
        with mock.patch.object(webapp_module, "_meld_available", return_value="/usr/bin/meld"), mock.patch.dict(os.environ, {"DISPLAY": "", "WAYLAND_DISPLAY": ""}):
            self.assertIn("no graphical desktop", webapp_module._launch_meld(self.left, self.right))

    def test_dashboard_and_meld_routes_render(self):
        for page in ("/", "/meld"):
            response = self.client.get(page)
            self.assertEqual(response.status_code, 200)

    def test_file_and_directory_comparisons_launch_as_argument_arrays(self):
        with mock.patch.object(webapp_module, "_meld_available", return_value="/usr/bin/meld"), mock.patch.dict(os.environ, {"DISPLAY": ":1"}), mock.patch.object(webapp_module.subprocess, "Popen") as popen:
            self.assertIsNone(webapp_module._launch_meld(self.left, self.right))
            popen.assert_called_once()
            self.assertEqual(popen.call_args.args[0], ["/usr/bin/meld", str(self.left), str(self.right)])
            popen.reset_mock()
            self.assertIsNone(webapp_module._launch_meld(self.root, self.root, directory=True))
            self.assertEqual(popen.call_args.args[0][1:], [str(self.root), str(self.root)])

    def test_meld_launch_failure_and_invalid_paths(self):
        with mock.patch.object(webapp_module, "_meld_available", return_value="/usr/bin/meld"), mock.patch.dict(os.environ, {"DISPLAY": ":1"}), mock.patch.object(webapp_module.subprocess, "Popen", side_effect=OSError("no display")):
            self.assertIn("Could not launch Meld", webapp_module._launch_meld(self.left, self.right))
        response = self.client.post("/meld/compare", data={"left": str(self.left), "right": str(self.root), "kind": "files"})
        self.assertEqual(response.status_code, 400)
        response = self.client.post("/meld/compare", data={"left": "/missing/file", "right": str(self.right), "kind": "files"})
        self.assertEqual(response.status_code, 400)

    def test_distribution_detection_uses_existing_helper_results(self):
        for distro in ("ubuntu", "debian", "mint", "freebsd"):
            completed = type("Completed", (), {"stdout": distro, "returncode": 0})()
            with mock.patch.object(webapp_module.subprocess, "run", return_value=completed) as run:
                self.assertEqual(webapp_module._distribution(), distro)
                self.assertIn("service_helpers/distribution.sh", run.call_args.args[0][-1])

    def test_script_backup_failure_prevents_launch(self):
        run_id = "test-backup-failure"
        webapp_module.RUNS["main/kernel.sh"] = {"status": "Running", "run_id": run_id}
        with mock.patch.object(webapp_module, "_privilege_prefix", return_value=["sudo", "-n"]), mock.patch.object(webapp_module, "_create_backup", return_value={"error": "permission denied"}) as backup, mock.patch.object(webapp_module, "_finish_run") as finish, mock.patch.object(webapp_module.subprocess, "Popen") as popen:
            webapp_module._execute_script("main/kernel.sh", run_id)
        backup.assert_called_once()
        popen.assert_not_called()
        finish.assert_called_once()
        self.assertIn("Backup failed", finish.call_args.args[3])

    def test_script_launch_follows_successful_backup(self):
        run_id = "test-run-success"
        webapp_module.RUNS["main/kernel.sh"] = {"status": "Running", "run_id": run_id}
        process = type("Process", (), {"pid": 45, "wait": lambda self: 0})()
        with mock.patch.object(webapp_module, "_privilege_prefix", return_value=["sudo", "-n"]), mock.patch.object(webapp_module, "_create_backup", return_value={"id": "backup-test"}) as backup, mock.patch.object(webapp_module, "_inspect_backup", return_value=[]) as inspect, mock.patch.object(webapp_module.subprocess, "Popen", return_value=process) as popen, mock.patch.object(webapp_module, "_finish_run") as finish:
            webapp_module._execute_script("main/kernel.sh", run_id)
        backup.assert_called_once()
        self.assertEqual(popen.call_args.args[0][:3], ["sudo", "-n", "bash"])
        inspect.assert_called_once_with("backup-test")
        finish.assert_called_once()

    def test_run_statuses_are_persisted_as_success_or_failure(self):
        with mock.patch.object(webapp_module, "_save_state"):
            webapp_module.RUNS["test-status"] = {"run_id": "ok"}
            webapp_module._finish_run("test-status", "ok", 0, "Ran successfully", {})
            self.assertEqual(webapp_module.RUNS["test-status"]["status"], "Ran")
            webapp_module.RUNS["test-status"] = {"run_id": "bad"}
            webapp_module._finish_run("test-status", "bad", 9, "Failed (exit 9)", {})
            self.assertEqual(webapp_module.RUNS["test-status"]["status"], "Failed")

    def test_privileged_helper_permission_error_is_returned(self):
        completed = type("Completed", (), {"stdout": "", "stderr": "sudo: a password is required", "returncode": 1})()
        with mock.patch.object(webapp_module, "BACKUP_ROOT", self.root / "app-backups"), mock.patch.object(webapp_module.subprocess, "run", return_value=completed):
            result = webapp_module._helper("backup", "--run-id", "x", "--script", "sample")
        self.assertIn("sudo: a password is required", result["error"])

    def test_manual_backup_reports_permission_failure(self):
        with mock.patch.object(webapp_module, "_submitted_path", return_value=self.left), mock.patch.object(webapp_module, "_create_backup", return_value={"error": "permission denied"}):
            response = self.client.post("/meld/backup", data={"path": str(self.left)})
        self.assertEqual(response.status_code, 500)
        self.assertIn(b"Backup failed", response.data)

    def test_restore_requires_confirmation_and_backs_up_current_version(self):
        backup_record = {"id": "b1", "entries": [{"path": str(self.left), "existed": True}]}
        with mock.patch.object(webapp_module, "_catalog", return_value=[backup_record]), mock.patch.object(webapp_module, "_create_backup") as backup, mock.patch.object(webapp_module, "_helper") as helper:
            response = self.client.post("/meld/restore", data={"backup_id": "b1", "path": str(self.left)})
            self.assertEqual(response.status_code, 400)
            backup.assert_not_called()
            helper.assert_not_called()
            backup.return_value = {"id": "pre-restore"}
            helper.return_value = {"restored": str(self.left)}
            response = self.client.post("/meld/restore", data={"backup_id": "b1", "path": str(self.left), "confirm": "yes"})
        self.assertEqual(response.status_code, 200)
        backup.assert_called_once()
        helper.assert_called_once()
        self.assertIn(b"Restored", response.data)


if __name__ == "__main__":
    unittest.main(verbosity=2)
