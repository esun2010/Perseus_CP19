#!/usr/bin/env python3
"""Verify comparison tasks use the dashboard's existing script runner."""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from webapp import app as dashboard  # noqa: E402


class CompareDashboardTest(unittest.TestCase):
    def test_tasks_are_listed_once_with_reference_then_inventory_arguments(self):
        package_tasks = [task for task in dashboard.TASKS if task["script"] == "compare/compare_pkgs.sh"]
        service_tasks = [task for task in dashboard.TASKS if task["script"] == "compare/compare_services.sh"]
        self.assertEqual(len(package_tasks), 1)
        self.assertEqual(len(service_tasks), 1)
        self.assertEqual(package_tasks[0]["args"], ["compare/pkgs/safe_pkgs.txt", "compare/pkgs/unsafe_pkgs.txt"])
        self.assertEqual(service_tasks[0]["args"], ["compare/services/safe_services.txt", "compare/services/unsafe_services.txt"])
        self.assertFalse(any("suspicious_services" in task["script"] for task in dashboard.TASKS))

    def test_runner_passes_task_arguments_as_separate_subprocess_arguments(self):
        script = "compare/compare_pkgs.sh"
        with tempfile.TemporaryDirectory(prefix="cp-compare-dashboard-") as temp:
            root = Path(temp)
            (root / "compare/pkgs").mkdir(parents=True)
            (root / "compare/compare_pkgs.sh").write_text("#!/bin/bash\n")
            (root / "main").mkdir()
            recorded = {}

            class Process:
                pid = 1234
                def wait(self):
                    return 0

            def popen(command, **kwargs):
                recorded["command"] = command
                return Process()

            old_run = dashboard.RUNS.get(script)
            dashboard.RUNS[script] = {"status": "Running", "run_id": "test-run"}
            self.addCleanup(lambda: dashboard.RUNS.pop(script, None) if old_run is None else dashboard.RUNS.__setitem__(script, old_run))
            with patch.object(dashboard, "ROOT", root), patch.object(dashboard, "STATE_PATH", root / "main/state.json"), patch.object(dashboard, "_privilege_prefix", return_value=["sudo", "-n"]), patch.object(dashboard.subprocess, "Popen", side_effect=popen):
                dashboard._execute_script(script, "test-run")

            self.assertEqual(recorded["command"], [
                "sudo", "-n", "bash", str(root / "compare/compare_pkgs.sh"),
                str(root / "compare/pkgs/safe_pkgs.txt"),
                str(root / "compare/pkgs/unsafe_pkgs.txt"),
            ])
            self.assertEqual(dashboard.RUNS[script]["status"], "Ran")

    def test_dashboard_renders_comparison_script_sections(self):
        response = dashboard.app.test_client().get("/")
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"Package Comparison", response.data)
        self.assertIn(b"Service Comparison", response.data)
        self.assertNotIn(b"Suspicious Services", response.data)


if __name__ == "__main__":
    unittest.main()
