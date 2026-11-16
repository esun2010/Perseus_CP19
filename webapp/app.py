#!/usr/bin/env python3
"""Local Flask dashboard for the existing CyberPatriot scripts."""
from __future__ import annotations

import hashlib
import glob
import json
import os
import pwd
import re
import shutil
import subprocess
import sys
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any

from flask import Flask, abort, jsonify, redirect, render_template, request, url_for

ROOT = Path(__file__).resolve().parents[1]
STATE_PATH = ROOT / "main" / ".webapp_state.json"
BACKUP_ROOT = Path(os.environ.get("CYBERPATRIOT_WEB_BACKUP_DIR", Path.home() / ".local/share/cyberpatriot/config-backups")).expanduser()
HELPER_PATH = ROOT / "main" / "dashboard_file_ops.py"
STATE_LOCK = threading.RLock()
RUNS: dict[str, dict[str, Any]] = {}
COMPARE_LOCKS: dict[str, threading.Lock] = {}
PASSWORD_POLICY_PAM_FILES = (
    "/etc/pam.d/common-auth",
    "/etc/pam.d/common-account",
    "/etc/pam.d/common-password",
)

app = Flask(__name__, template_folder=str(ROOT / "webapp" / "templates"), static_folder=str(ROOT / "webapp" / "static"))
app.secret_key = os.environ.get("CYBERPATRIOT_FLASK_SECRET", "local-cyberpatriot-dashboard")

# Dashboard order follows the requested task flow.
TASKS = [
    {"id": "usr", "name": "User Management", "script": "user_management/user_management.sh", "logs": ["log/unauth_users(2).txt", "log/unauth_admins(2).txt", "log/uid_zero_users.txt"], "edit_lists": [("Edit Authorized Accounts", "input/authorized_accounts.txt")], "second": {"name": "User Cleanup", "script": "user_management/user_management_2.sh", "logs": ["log/user_management(2).txt"]}},
    {"id": "mp3", "name": "Media Inventory", "script": "rm_stuff/rm_mp3+.sh", "logs": ["log/media_files(2).txt"], "second": {"name": "Media Cleanup", "script": "rm_stuff/rm_mp3+_2.sh", "logs": ["log/media_cleanup(2).txt"]}},
    {"id": "ker", "name": "Kernel Hardening", "script": "config/kernel.sh", "configs": ["/etc/sysctl.d/99-hardening.conf", "/etc/sysctl.conf", "/etc/sudoers", "/etc/polkit-1/rules.d/00-cyberpatriot-admins.rules", "/usr/local/etc/sudoers", "/usr/local/etc/polkit-1/rules.d", "/etc/rc.conf", "/etc/fstab"]},
    {"id": "sys", "name": "System Components", "script": "config/system_hardening.sh", "configs": ["/etc/nsswitch.conf", "/etc/ssl/openssl.cnf", "/etc/ssl/private", "/etc/ssl/certs", "/etc/ssl/untrusted", "/etc/default/grub", "/boot/grub/grub.cfg", "/boot/grub2/grub.cfg", "/boot/loader.conf", "/boot/loader.conf.local", "/boot/loader.rc", "/boot/loader.conf.d", "/boot/loader/entries", "/etc/selinux/config", "/etc/dhcp/dhclient.conf", "/etc/dhcp/dhclient-enter-hooks.d", "/etc/dhcp/dhclient-exit-hooks.d", "/etc/sysctl.conf", "/etc/rc.conf", "/etc/rc.conf.local", "/etc/fstab", "/etc/hosts", "/usr/lib/systemd/system", "/usr/share/ca-certificates", "/usr/share/certs", "/etc/pki", "/usr/local/share/ca-certificates", "/usr/local/share/certs", "/usr/local/etc/ssl/certs", "/etc/rc.d", "/usr/local/etc/rc.d", "/etc/rc.conf.d", "/usr/local/etc/rc.conf.d"]},
    {"id": "pol", "name": "Password Policy", "script": "password_management/pwd_policy.sh", "configs": ["/etc/login.defs", "/etc/security/pwquality.conf", "/etc/security/faillock.conf", "/etc/pam.d/common-auth", "/etc/pam.d/common-account", "/etc/pam.d/common-password", "/etc/pam.d/common-session", "/etc/pam.d/common-session-noninteractive", "/usr/share/pam-configs/cyberpatriot-faillock-preauth", "/usr/share/pam-configs/cyberpatriot-faillock-authfail", "/etc/pam.d/passwd", "/etc/login.conf", "/etc/login.conf.db", "/etc/apt", "/var/lib/pam", "/etc/shadow"]},
    {"id": "log", "name": "Guest Login", "script": "config/login.sh", "configs": ["/etc/lightdm", "/etc/gdm3", "/etc/sddm.conf", "/usr/local/etc/lightdm", "/etc/passwd", "/etc/shadow", "/etc/group", "/etc/gshadow", "/etc/passwd-", "/etc/shadow-", "/etc/group-", "/etc/gshadow-", "/etc/master.passwd", "/etc/pwd.db", "/etc/spwd.db"]},
    {"id": "per", "name": "File Permissions", "script": "config/file_permissions.sh", "configs": ["/etc", "/usr/local/etc", "/usr/lib/systemd/system", "/usr/share/ca-certificates", "/usr/share/certs", "/etc/pki", "/usr/local/share/ca-certificates", "/usr/local/share/certs", "/lib/security", "/lib64/security", "/usr/lib/security", "/usr/lib64/security", "/boot/grub/grub.cfg", "/boot/grub2/grub.cfg", "/boot/efi/EFI/ubuntu/grub.cfg", "/boot/efi/EFI/centos/grub.cfg", "/boot/efi/EFI/redhat/grub.cfg", "/boot/loader/entries", "/etc/rc.d", "/usr/local/etc/rc.d", "/etc/rc.conf.d", "/usr/local/etc/rc.conf.d"]},
    {"id": "updates-auto", "name": "Daily Update Checks", "script": "config/automatic_updates.sh", "configs": ["/etc/apt/apt.conf.d/20auto-upgrades"]},
    {"id": "cpkg", "name": "Package Comparison", "script": "compare/compare_pkgs.sh", "logs": ["log/pkgs_log.txt"]},
    {"id": "csvc", "name": "Service Comparison", "script": "compare/compare_services.sh", "logs": ["log/services_log.txt"]},
    {"id": "pkg", "name": "Bad Packages", "script": "rm_stuff/bad_pkg.sh", "edit_packages": True, "configs": ["/etc", "/usr/local/etc"]},
    {"id": "mal", "name": "Malware and Security Scan", "script": "rm_stuff/malware_scan.sh", "logs": ["log/clamav.txt", "log/lynis.txt"]},
]

SERVICES = [
    {"id": "ufw", "name": "UFW Firewall", "script": "services/ufw.sh", "configs": ["/etc/ufw", "/etc/default/ufw"]},
    {"id": "apache2", "name": "Apache2 Setup", "script": "services/apache2.sh", "configs": ["/etc/apache2"]},
    {"id": "sshd", "name": "OpenSSH Server Setup", "script": "services/sshd.sh", "configs": ["/etc/ssh"]},
]

AUTO_RUN_EXCLUDED_SCRIPTS = {
    "rm_stuff/bad_pkg.sh",
    "user_management/user_management.sh",
    "rm_stuff/rm_mp3+.sh",
    "rm_stuff/malware_scan.sh",
}
AUTO_RUN_SCRIPTS = [task["script"] for task in TASKS if task["script"] not in AUTO_RUN_EXCLUDED_SCRIPTS]

INPUT_FILES = [
    "input/distribution.txt",
    "compare/pkgs/safe_pkgs.txt",
    "compare/services/safe_services.txt",
]
EDITABLE_INPUT_FILES = INPUT_FILES + ["input/authorized_accounts.txt"]
INPUT_EDITOR_DETAILS = {
    "input/authorized_accounts.txt": ("Authorized Accounts", "Use the Authorized Administrators and Authorized Users headings. Put each administrator username on one line followed by an indented password: value line. Passwords are validated as input but existing scripts use only the usernames."),
    "compare/pkgs/safe_pkgs.txt": ("Trusted Package Reference", "Add one package name per line. Keep distribution-specific names; comparison results do not determine whether a package is safe."),
    "compare/services/safe_services.txt": ("Trusted Service Reference", "Add one service name and expected boot state per line, such as ssh.service enabled. Allowed states are enabled and disabled."),
}

UPDATE_ACTION = {
    "id": "updates",
    "name": "Updates and APT Reset",
    "description": "Runs the initial startup repair and package refresh/upgrade steps used by main/run_all.sh.",
    "configs": ["/etc/environment", "/etc/apt"],
}

@app.post("/distribution")
def set_distribution():
    selection = request.form.get("distribution", "")
    if selection not in {"auto", "ubuntu", "debian", "mint", "freebsd"}:
        abort(400)
    path = ROOT / "input" / "distribution.txt"
    path.write_text("# Choose auto to detect, or choose the matching installed distribution.\n" + selection + "\n", encoding="utf-8")
    return redirect(url_for("dashboard"))


def _load_state() -> dict[str, Any]:
    try:
        data = json.loads(STATE_PATH.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _distribution() -> str:
    command = ["bash", "-c", 'source "$1"; load_distribution || exit 2; printf "%s" "$CP_DISTRO"', "distribution", str(ROOT / "service_helpers" / "distribution.sh")]
    try:
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=False)
        return result.stdout.strip() if result.returncode == 0 else "unsupported"
    except OSError:
        return "unsupported"


def _privilege_prefix() -> list[str]:
    for manager in ("sudo", "doas"):
        executable = shutil.which(manager)
        if not executable:
            continue
        try:
            available = subprocess.run([executable, "-n", "true"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            if available.returncode == 0:
                return [executable, "-n"]
        except OSError:
            continue
    graphical_privilege = shutil.which("pkexec")
    if graphical_privilege and (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        return [graphical_privilege]
    return []


def _helper(*args: str) -> dict[str, Any]:
    try:
        BACKUP_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(BACKUP_ROOT, 0o700)
        command = [*_privilege_prefix(), sys.executable, str(HELPER_PATH), "--backup-root", str(BACKUP_ROOT), "--uid", str(os.getuid()), "--gid", str(os.getgid()), *args]
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=False)
    except OSError as exc:
        return {"error": str(exc)}
    try:
        data = json.loads(result.stdout or "{}")
    except ValueError:
        data = {"error": result.stderr.strip() or "File operation returned invalid output."}
    if result.returncode and not data.get("error"):
        data["error"] = result.stderr.strip() or "Privileged file operation failed; check sudo access and file permissions."
    return data


def _create_backup(paths: list[str], run_id: str, script: str) -> dict[str, Any]:
    response = _helper("backup", "--run-id", run_id, "--script", script, *paths)
    return response.get("backup", response)


def _inspect_backup(backup_id: str) -> list[dict[str, Any]]:
    response = _helper("inspect", "--id", backup_id)
    if isinstance(response, list):
        return response
    return [{"path": "", "status": "error", "error": response.get("error", "Inspection failed")}]


def _save_state(state: dict[str, Any]) -> None:
    temporary = STATE_PATH.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, indent=2, sort_keys=True), encoding="utf-8")
    os.chmod(temporary, 0o600)
    temporary.replace(STATE_PATH)


def _status(script_id: str) -> dict[str, Any]:
    with STATE_LOCK:
        saved = _load_state().get("runs", {}).get(script_id)
    current = RUNS.get(script_id)
    if current and current.get("status") == "Running":
        return dict(current)
    if saved:
        return dict(saved)
    return {"status": "Ready", "exit_code": None, "message": "Ready", "run_id": None}


def _resolve_repo_file(relpath: str) -> Path:
    supplied = Path(relpath)
    if supplied.is_absolute():
        with STATE_LOCK:
            state = _load_state()
        known = {item for paths in state.get("modified", {}).values() for item in paths}
        known.update(PASSWORD_POLICY_PAM_FILES)
        if str(supplied) not in known:
            abort(404)
        return supplied
    candidate = (ROOT / supplied).resolve(strict=False)
    try:
        candidate.relative_to(ROOT)
    except ValueError:
        abort(404)
    return candidate


def _is_regular_view_file(relpath: str) -> bool:
    try:
        candidate = _resolve_repo_file(relpath)
        return candidate.is_file() and not candidate.is_symlink()
    except Exception:
        return False


def _write_error_log(run_id: str, output_path: Path, stderr_path: Path | None, exit_code: int) -> str:
    """Write a separate, error-only record for a failed run."""
    error_path = ROOT / "log" / "webapp-runs" / f"{run_id}-errors.log"
    error_path.parent.mkdir(parents=True, exist_ok=True)
    pattern = re.compile(r"\b(failed|failure|error|critical|traceback|exception)\b", re.IGNORECASE)
    with error_path.open("w", encoding="utf-8", errors="replace") as errors:
        if stderr_path and stderr_path.is_file():
            with stderr_path.open("r", encoding="utf-8", errors="replace") as stderr:
                for line in stderr:
                    if line.strip():
                        errors.write(line)
        if output_path.is_file():
            with output_path.open("r", encoding="utf-8", errors="replace") as output:
                for line in output:
                    if pattern.search(line):
                        errors.write(line)
        errors.flush()
        if error_path.stat().st_size == 0:
            errors.write(f"Script exited with status {exit_code}.\n")
    return str(error_path.relative_to(ROOT))


def _file_signature(path: Path) -> str | None:
    try:
        if path.is_symlink():
            return "link:" + os.readlink(path)
        if path.is_file() and not path.is_symlink():
            digest = hashlib.sha256()
            stat = path.stat()
            digest.update(f"{stat.st_mode}:{stat.st_uid}:{stat.st_gid}".encode())
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            return digest.hexdigest()
        if path.is_dir() and not path.is_symlink():
            entries = []
            for item in sorted(path.rglob("*")):
                if item.is_symlink():
                    entries.append((str(item.relative_to(path)), "link", os.readlink(item)))
                elif item.is_file():
                    entries.append((str(item.relative_to(path)), _file_signature(item)))
                elif item.is_dir():
                    stat = item.stat()
                    entries.append((str(item.relative_to(path)), f"dir:{stat.st_mode}:{stat.st_uid}:{stat.st_gid}"))
            return hashlib.sha256(json.dumps(entries, sort_keys=True).encode()).hexdigest()
    except OSError:
        return None
    return None


def _snapshot(paths: list[str]) -> dict[str, str | None]:
    snapshot = {}
    for raw in paths:
        path = Path(raw)
        if path.is_dir() and not path.is_symlink():
            try:
                for child in path.rglob("*"):
                    if child.is_symlink() or child.is_file():
                        snapshot[str(child)] = _file_signature(child)
            except OSError:
                continue
        elif path.is_file() or path.is_symlink():
            snapshot[raw] = _file_signature(path)
    return snapshot


def _modified_configurations(script: dict[str, Any]) -> list[str]:
    with STATE_LOCK:
        state = _load_state()
    runs = state.get("modified", {}).get(script["script"], [])
    result = []
    for raw in runs:
        if raw not in result:
            result.append(raw)
    return result


def _files_for_script(script_path: str) -> dict[str, list[str]]:
    task = _task_by_script(script_path)
    logs: list[str] = []
    if task:
        if task["script"] == script_path:
            logs = list(task.get("logs", []))
        elif task.get("second", {}).get("script") == script_path:
            logs = list(task["second"].get("logs", []))
    logs = [path for path in logs if _is_regular_view_file(path)]
    output = _status(script_path).get("output")
    if output and _is_regular_view_file(output):
        logs.append(output)
    run_status = _status(script_path)
    error_output = run_status.get("error_output")
    if run_status.get("status") == "Failed" and error_output and _is_regular_view_file(error_output):
        logs.append(error_output)
    modified = []
    with STATE_LOCK:
        state = _load_state()
    for path in state.get("modified", {}).get(script_path, []):
        try:
            if _is_regular_view_file(path):
                modified.append(path)
        except Exception:
            continue
    if script_path == "password_management/pwd_policy.sh":
        for path in PASSWORD_POLICY_PAM_FILES:
            if path not in modified and _is_regular_view_file(path):
                modified.append(path)
    return {"logs": logs, "configs": modified}


def _all_tasks() -> list[dict[str, Any]]:
    result = []
    for task in TASKS:
        item = dict(task)
        item["status"] = _status(item["script"])
        item["files"] = _files_for_script(item["script"])
        item["log_files"] = item["files"]["logs"]
        item["config_files"] = item["files"]["configs"]
        if item.get("second"):
            item["second"] = dict(item["second"], status=_status(item["second"]["script"]))
            item["second_files"] = _files_for_script(item["second"]["script"])
        result.append(item)
    return result


def _all_services() -> list[dict[str, Any]]:
    result = []
    for service in SERVICES:
        item = dict(service)
        item["status"] = _status(item["script"])
        item["files"] = _files_for_script(item["script"])
        item["log_files"] = item["files"]["logs"]
        item["config_files"] = item["files"]["configs"]
        result.append(item)
    return result


def _finding_items(path: Path) -> list[str]:
    try:
        if not path.is_file() or path.is_symlink():
            return []
        return list(dict.fromkeys(
            match.group(1) for line in path.read_text(encoding="utf-8").splitlines()
            if (match := re.fullmatch(r"\[(?:extra|enabled|active|disabled|inactive)\] ([A-Za-z0-9][A-Za-z0-9_.+@:-]*)", line))
        ))
    except OSError:
        return []


def _inventory_items(path: Path) -> set[str]:
    try:
        if not path.is_file() or path.is_symlink():
            return set()
        return {line.split()[0] for line in path.read_text(encoding="utf-8").splitlines() if line.split()}
    except OSError:
        return set()


def _comparison_actions() -> dict[str, list[str]]:
    return {
        "packages": _finding_items(ROOT / "log" / "pkgs_log.txt"),
        "services": _finding_items(ROOT / "log" / "services_log.txt"),
    }


def _task_by_script(script: str) -> dict[str, Any] | None:
    for task in TASKS:
        if task["script"] == script or task.get("second", {}).get("script") == script:
            return task
    return None


def _service_by_script(script: str) -> dict[str, Any] | None:
    return next((service for service in SERVICES if service["script"] == script), None)


def _config_candidates(script: str, task: dict[str, Any] | None) -> list[str]:
    if not task:
        service = _service_by_script(script)
        if not service:
            return []
        candidates = list(service.get("configs", []))
    elif task.get("second", {}).get("script") == script:
        candidates = list(task["second"].get("configs", []))
    else:
        candidates = list(task.get("configs", []))
    if script == "config/file_permissions.sh":
        distro = _distribution()
        login_files = [".bash_profile", ".bashrc", ".bash_login", ".profile", ".zshrc", ".bash_history", ".cshrc", ".login", ".history"]
        try:
            users = pwd.getpwall()
        except OSError:
            users = []
        for user in users:
            if distro == "freebsd":
                if not (1000 <= user.pw_uid < 65534) or user.pw_shell.endswith(("/nologin", "/false")):
                    continue
                if not (user.pw_dir.startswith("/home/") or user.pw_dir.startswith("/usr/home/")):
                    continue
            elif user.pw_uid != 0 and not user.pw_shell.endswith(("/bash", "/zsh", "/sh", "/dash", "/ksh", "/fish", "/csh", "/tcsh")):
                continue
            home = Path(user.pw_dir)
            if not home.is_dir() or home.is_symlink():
                continue
            for name in login_files:
                path = home / name
                if path.exists() and not path.is_symlink(): candidates.append(str(path))
            ssh = home / ".ssh"
            if ssh.is_dir() and not ssh.is_symlink():
                candidates.append(str(ssh))
                for name in ("authorized_keys", "config", "id_rsa", "id_ed25519"):
                    path = ssh / name
                    if path.exists() and not path.is_symlink(): candidates.append(str(path))
        for pattern in ("/usr/lib/*-linux-gnu/security", "/lib/*-linux-gnu/security"):
            candidates.extend(glob.glob(pattern))
    # Directory snapshots cover their descendants, so avoid duplicating those
    # trees as separate backups while keeping standalone files explicit.
    ordered = sorted(set(candidates), key=lambda item: (len(Path(item).parts), item))
    roots: list[Path] = []
    result: list[str] = []
    for raw in ordered:
        path = Path(raw)
        if any(path != parent and parent in path.parents for parent in roots):
            continue
        result.append(raw)
        if path.is_dir() and not path.is_symlink(): roots.append(path)
    return result


def _run_update_steps(run_id: str, stderr_path: Path) -> list[str]:
    env = os.environ.copy()
    env["PATH"] = "/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin"
    env["ROOT"] = str(ROOT)
    distro = _distribution()
    if distro == "freebsd":
        steps = 'source "$ROOT/main/logging.sh"; init_logging; source "$ROOT/service_helpers/startup_repair.sh"; startup_repair; pkg -N >/dev/null 2>&1 || pkg bootstrap -y; pkg update; backup_package_configuration; pkg upgrade'
    elif distro in ("ubuntu", "debian", "mint"):
        steps = 'source "$ROOT/main/logging.sh"; init_logging; source "$ROOT/service_helpers/startup_repair.sh"; startup_repair; apt-get update; backup_package_configuration; apt-get upgrade'
    else:
        raise RuntimeError("The existing distribution detector could not identify a supported system; update action was not run.")
    output_path = ROOT / "log" / "webapp-runs" / f"{run_id}.log"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("ab") as output, stderr_path.open("wb") as errors:
        command = ["bash", "-c", "set -euo pipefail; " + steps]
        output.write(("$ " + " ".join(command) + "\n").encode())
        output.flush()
        privilege = _privilege_prefix()
        if not privilege:
            raise RuntimeError("Configure sudo or doas, or launch from a graphical Linux session with pkexec available; Flask remains unprivileged.")
        proc = subprocess.run([*privilege, *command], cwd=ROOT, env=env, stdout=output, stderr=errors, check=False)
        if proc.returncode != 0:
            raise subprocess.CalledProcessError(proc.returncode, command)
    if stderr_path.is_file():
        with output_path.open("ab") as output, stderr_path.open("rb") as errors:
            shutil.copyfileobj(errors, output)
    return [str(output_path.relative_to(ROOT))]


def _execute_script(script: str, run_id: str) -> None:
    if script in {"compare/compare_pkgs.sh", "compare/compare_services.sh"}:
        lock = COMPARE_LOCKS.setdefault(script, threading.Lock())
        with lock:
            _execute_script_impl(script, run_id)
        return
    _execute_script_impl(script, run_id)


def _execute_script_impl(script: str, run_id: str) -> None:
    task = _task_by_script(script)
    service = _service_by_script(script)
    config_candidates = _config_candidates(script, task)
    script_path = ROOT / script
    if not script_path.is_file():
        _finish_run(script, run_id, 127, f"Missing script: {script}", {})
        return
    privilege = _privilege_prefix()
    if not privilege:
        _finish_run(script, run_id, 1, "Configure sudo or doas, or use a graphical Linux session with pkexec available; the Flask server stays unprivileged.", {})
        return
    script_args = task.get("args", []) if task and task.get("script") == script else task.get("second", {}).get("args", []) if task else service.get("args", []) if service else []
    command = [*privilege, "bash", str(script_path), *(str(ROOT / value) if not Path(value).is_absolute() else value for value in script_args)]
    output_path = ROOT / "log" / "webapp-runs" / f"{run_id}.log"
    stderr_path = output_path.with_name(f"{run_id}-stderr.tmp")
    try:
        backup = _create_backup(config_candidates, run_id, script) if config_candidates else {"id": None}
        if backup.get("error"):
            _finish_run(script, run_id, 1, f"Backup failed; script was not run: {backup['error']}", {"backup_error": backup["error"]})
            return
        output_path.parent.mkdir(parents=True, exist_ok=True)
        env = os.environ.copy()
        env["PATH"] = "/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin"
        with output_path.open("ab") as output, stderr_path.open("wb") as errors:
            proc = subprocess.Popen(command, cwd=ROOT, env=env, stdout=output, stderr=errors, start_new_session=True)
            if RUNS.get(script, {}).get("run_id") == run_id:
                RUNS[script].update({"status": "Running", "message": "Running...", "exit_code": None, "pid": proc.pid, "output": str(output_path.relative_to(ROOT))})
            code = proc.wait()
        error_output = _write_error_log(run_id, output_path, stderr_path, code) if code != 0 else None
        if stderr_path.is_file():
            with output_path.open("ab") as output, stderr_path.open("rb") as errors:
                shutil.copyfileobj(errors, output)
        stderr_path.unlink(missing_ok=True)
        changes = _inspect_backup(backup["id"]) if backup.get("id") else []
        changed = [entry["path"] for entry in changes if entry["status"] in ("changed", "created", "deleted")]
        if RUNS.get(script, {}).get("run_id") == run_id:
            with STATE_LOCK:
                state = _load_state()
                state.setdefault("modified", {})[script] = changed
                _save_state(state)
        message = "Ran successfully" if code == 0 else "Failed"
        _finish_run(script, run_id, code, message, {"output": str(output_path.relative_to(ROOT)), "error_output": error_output, "modified": changed, "backup_id": backup["id"], "changes": changes})
    except OSError as exc:
        error_output = _write_error_log(run_id, output_path, stderr_path if stderr_path.exists() else None, 127) if output_path.exists() else None
        if error_output:
            with (ROOT / error_output).open("a", encoding="utf-8") as errors:
                errors.write(f"Failed to launch: {exc}\n")
        stderr_path.unlink(missing_ok=True)
        _finish_run(script, run_id, 127, f"Failed to launch: {exc}", {"error_output": error_output})


def _finish_run(script: str, run_id: str, code: int, message: str, extra: dict[str, Any]) -> None:
    result = {"status": "Ran" if code == 0 else "Failed", "message": message, "exit_code": code, "run_id": run_id, **extra}
    if RUNS.get(script, {}).get("run_id") != run_id:
        return
    with STATE_LOCK:
        state = _load_state()
        state.setdefault("runs", {})[script] = result
        _save_state(state)
    RUNS[script] = result


@app.get("/")
def dashboard():
    update_status = _status("__updates__")
    update_files = _files_for_updates()
    aggregate = [name for name in ("main/all_logs.txt", "main/all_logs(2).txt") if _is_regular_view_file(name)]
    distribution_file = ROOT / "input" / "distribution.txt"
    selected_distribution = "auto"
    try:
        selected_distribution = next((line.strip() for line in distribution_file.read_text(encoding="utf-8").splitlines() if line.strip() and not line.lstrip().startswith("#")), "auto")
    except OSError:
        pass
    return render_template("dashboard.html", tasks=_all_tasks(), services=_all_services(), inputs=INPUT_FILES, update=UPDATE_ACTION, update_status=update_status, update_files=update_files, aggregate=aggregate, selected_distribution=selected_distribution, update_review=url_for("review_run", backup_id=update_status["backup_id"]) if update_status.get("backup_id") else None, comparison_actions=_comparison_actions())


@app.post("/run/<path:script>")
def run_script(script: str):
    if script != "updates":
        task = _task_by_script(script)
        service = _service_by_script(script)
        if task is None and service is None:
            abort(404)
    else:
        script = "__updates__"
    run_id = f"{int(time.time() * 1000)}-{os.urandom(4).hex()}"
    status_key = "__updates__" if script == "updates" else script
    RUNS[status_key] = {"status": "Running", "message": "Running...", "exit_code": None, "run_id": run_id}
    worker = threading.Thread(target=_execute_updates if script == "__updates__" else _execute_script, args=(run_id,) if script == "__updates__" else (script, run_id), daemon=True)
    worker.start()
    return jsonify({"script": script, "run_id": run_id, "status": "Running", "message": "Running..."}), 202


@app.post("/auto-run")
def auto_run():
    run_id = f"{int(time.time() * 1000)}-{os.urandom(4).hex()}"
    worker = threading.Thread(target=_execute_auto_run, args=(run_id,), daemon=True)
    worker.start()
    return jsonify({"run_id": run_id, "status": "Running", "message": "Auto-run started."}), 202


def _execute_auto_run(run_id: str) -> None:
    output_path = ROOT / "log" / "webapp-runs" / f"auto-{run_id}.log"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    script_run_ids = {script: f"{run_id}-{index}" for index, script in enumerate(AUTO_RUN_SCRIPTS, start=1)}
    for script, script_run_id in script_run_ids.items():
        RUNS[script] = {"status": "Running", "message": "Running from Auto-run...", "exit_code": None, "run_id": script_run_id}
    if RUNS.get("__auto_run__", {}).get("run_id") == run_id:
        RUNS["__auto_run__"]["output"] = str(output_path.relative_to(ROOT))
    results = []
    with output_path.open("ab") as output:
        print("Starting eligible scripts concurrently:", file=output, flush=True)
        for script in AUTO_RUN_SCRIPTS:
            print(f"===== {script} =====", file=output, flush=True)
        start_gate = threading.Barrier(len(AUTO_RUN_SCRIPTS)) if AUTO_RUN_SCRIPTS else None

        def run_together(script: str) -> None:
            if start_gate is not None:
                start_gate.wait()
            _execute_script(script, script_run_ids[script])

        with ThreadPoolExecutor(max_workers=max(1, len(AUTO_RUN_SCRIPTS))) as executor:
            futures = {
                executor.submit(run_together, script): script
                for script in AUTO_RUN_SCRIPTS
            }
            for future in as_completed(futures):
                script = futures[future]
                try:
                    future.result()
                except Exception as exc:
                    _finish_run(script, script_run_ids[script], 1, f"Failed during Auto-run: {exc}", {})
                result = _status(script)
                results.append({"script": script, "status": result["status"], "message": result.get("message", "")})
                print(f"===== {result['status']}: {script}: {result.get('message', '')} =====", file=output, flush=True)
    failed = [item for item in results if item["status"] != "Ran"]
    _finish_run("__auto_run__", run_id, 1 if failed else 0, f"Auto-run complete: {len(failed)} failed out of {len(results)} scripts.", {"output": str(output_path.relative_to(ROOT)), "results": results})


def _execute_updates(run_id: str) -> None:
    backup = _create_backup(UPDATE_ACTION["configs"], run_id, "Updates and APT Reset")
    if backup.get("error"):
        _finish_run("__updates__", run_id, 1, f"Backup failed; update was not run: {backup['error']}", {"backup_error": backup["error"]})
        return
    output_path = ROOT / "log" / "webapp-runs" / f"{run_id}.log"
    stderr_path = output_path.with_name(f"{run_id}-stderr.tmp")
    if RUNS.get("__updates__", {}).get("run_id") == run_id:
        RUNS["__updates__"]["output"] = str(output_path.relative_to(ROOT))
    try:
        outputs = _run_update_steps(run_id, stderr_path)
        code, message = 0, "Ran successfully"
    except (OSError, RuntimeError, subprocess.CalledProcessError) as exc:
        code = getattr(exc, "returncode", 127)
        outputs = [str(output_path.relative_to(ROOT))]
        message = f"Failed (exit {code})"
    error_output = _write_error_log(run_id, output_path, stderr_path if stderr_path.exists() else None, code) if code != 0 else None
    if stderr_path.is_file():
        with output_path.open("ab") as output, stderr_path.open("rb") as errors:
            shutil.copyfileobj(errors, output)
    stderr_path.unlink(missing_ok=True)
    changes = _inspect_backup(backup["id"])
    changed = [entry["path"] for entry in changes if entry["status"] in ("changed", "created", "deleted")]
    if RUNS.get("__updates__", {}).get("run_id") == run_id:
        with STATE_LOCK:
            state = _load_state()
            state.setdefault("modified", {})["__updates__"] = changed
            _save_state(state)
    _finish_run("__updates__", run_id, code, message, {"output": outputs[0] if outputs else None, "error_output": error_output, "modified": changed, "backup_id": backup["id"], "changes": changes})


@app.get("/status/<path:script>")
def status(script: str):
    if script == "auto-run":
        data = _status("__auto_run__")
        logs = []
        if data.get("output") and _is_regular_view_file(data["output"]):
            logs.append(data["output"])
        if data.get("status") == "Failed":
            for result in data.get("results", []):
                run = _status(result.get("script", ""))
                error_output = run.get("error_output")
                if run.get("status") == "Failed" and error_output and _is_regular_view_file(error_output):
                    logs.append(error_output)
        data["files"] = {"logs": logs, "configs": []}
        return jsonify(data)
    if script == "updates":
        script = "__updates__"
        data = _status(script)
        data["files"] = _files_for_updates()
        return jsonify(data)
    data = _status(script)
    data["files"] = _files_for_script(script)
    return jsonify(data)


def _files_for_updates() -> dict[str, list[str]]:
    status_data = _status("__updates__")
    logs = []
    if status_data.get("output") and _is_regular_view_file(status_data["output"]):
        logs.append(status_data["output"])
    error_output = status_data.get("error_output")
    if status_data.get("status") == "Failed" and error_output and _is_regular_view_file(error_output):
        logs.append(error_output)
    configs = []
    for path in status_data.get("modified", []):
        try:
            if _is_regular_view_file(path):
                configs.append(path)
        except Exception:
            continue
    return {"logs": logs, "configs": configs}


@app.get("/edit/<path:relpath>")
def edit_input(relpath: str):
    if relpath not in EDITABLE_INPUT_FILES:
        abort(404)
    path = _resolve_repo_file(relpath)
    if not path.is_file() or path.is_symlink():
        return _render_input_editor(relpath, path.name, "", "This input file is missing or is not a regular file."), 404
    try:
        contents = path.read_text(encoding="utf-8")
    except OSError as exc:
        contents = ""
        error = str(exc)
    else:
        error = None
    return _render_input_editor(relpath, path.name, contents, error)


def _render_input_editor(relpath: str, filename: str, contents: str, error: str | None, status_code: int = 200):
    page_title, instructions = INPUT_EDITOR_DETAILS.get(relpath, ("Edit Input File", "Edit the original input file used by the scripts."))
    return render_template(
        "edit.html", relpath=relpath, filename=filename, contents=contents,
        page_title=page_title, instructions=instructions, error=error,
    ), status_code


@app.post("/edit/<path:relpath>")
def save_input(relpath: str):
    if relpath not in EDITABLE_INPUT_FILES:
        abort(404)
    path = _resolve_repo_file(relpath)
    if not path.is_file() or path.is_symlink():
        abort(404)
    content = request.form.get("contents", "")
    try:
        previous = path.read_bytes()
        content = content.replace("\r\n", "\n").replace("\r", "\n")
        newline = "\r\n" if b"\r\n" in previous else "\r" if b"\r" in previous and b"\n" not in previous else "\n"
        if newline != "\n":
            content = content.replace("\n", newline)
        path.write_text(content, encoding="utf-8", newline="")
    except OSError as exc:
        return _render_input_editor(relpath, path.name, content, str(exc), 500)
    return redirect(url_for("edit_input", relpath=relpath, saved="1"))


@app.get("/edit-packages")
def edit_packages():
    path = ROOT / "rm_stuff" / "bad_pkg.sh"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        return render_template("packages.html", packages=[], error=str(exc)), 500
    match = re.search(r"^BAD_PACKAGES=\(([^)]*)\)$", text, re.MULTILINE)
    if not match:
        return render_template("packages.html", packages=[], error="Could not locate BAD_PACKAGES in rm_stuff/bad_pkg.sh."), 500
    packages = match.group(1).split()
    return render_template("packages.html", packages=packages, error=None)


@app.post("/edit-packages")
def save_packages():
    path = ROOT / "rm_stuff" / "bad_pkg.sh"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        return render_template("packages.html", packages=[], error=str(exc)), 500
    match = re.search(r"^BAD_PACKAGES=\(([^)]*)\)$", text, re.MULTILINE)
    if not match:
        abort(500)
    packages = [line.strip() for line in request.form.get("packages", "").splitlines() if line.strip()]
    if any(not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9+_.-]*", package) for package in packages):
        return render_template("packages.html", packages=packages, error="Use one package name per line; letters, digits, +, _, . and - are allowed."), 400
    replacement = "BAD_PACKAGES=(" + " ".join(packages) + ")"
    updated = text[:match.start()] + replacement + text[match.end():]
    temporary = path.with_suffix(".sh.tmp")
    try:
        temporary.write_text(updated, encoding="utf-8")
        os.chmod(temporary, path.stat().st_mode & 0o777)
        temporary.replace(path)
    except OSError as exc:
        temporary.unlink(missing_ok=True)
        return render_template("packages.html", packages=packages, error=str(exc)), 500
    return redirect(url_for("edit_packages", saved="1"))


@app.get("/view")
def view_file():
    relpath = request.args.get("path", "")
    try:
        path = _resolve_repo_file(relpath)
    except Exception:
        candidate = Path(relpath)
        filepath = str(candidate if candidate.is_absolute() else ROOT / candidate)
        return render_template("viewer.html", filename=candidate.name or "File", filepath=filepath, content="", error="This path cannot be read from the dashboard."), 404
    if not path.is_file() or path.is_symlink():
        return render_template("viewer.html", filename=path.name, filepath=str(path), content="", error="File does not exist or is not a regular file."), 404
    try:
        content = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        return render_template("viewer.html", filename=path.name, filepath=str(path), content="", error=str(exc)), 404
    return render_template("viewer.html", filename=path.name, filepath=str(path), content=content, error=None)


@app.get("/api/dashboard")
def dashboard_data():
    return jsonify({"tasks": _all_tasks()})


def _catalog() -> list[dict[str, Any]]:
    try:
        data = json.loads((BACKUP_ROOT / "catalog.json").read_text(encoding="utf-8"))
        return list(reversed(data.get("backups", [])))
    except (OSError, ValueError):
        return []


def _meld_available() -> str | None:
    path = shutil.which("meld")
    return path if path and os.access(path, os.X_OK) else None


def _launch_meld(left: Path, right: Path, directory: bool = False) -> str | None:
    meld = _meld_available()
    if not meld:
        return "Meld is not installed or is not executable. Run ./setup.sh or install Meld for this operating system."
    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        return "Meld could not open: no graphical desktop session is available to the Flask process (DISPLAY/WAYLAND_DISPLAY is missing)."
    if not left.exists() or not right.exists():
        return "Both comparison paths must exist."
    if left.is_symlink() or right.is_symlink():
        return "Symbolic-link comparison inputs are not supported."
    if directory:
        if not left.is_dir() or not right.is_dir(): return "Directory comparison requires two existing directories."
        if not os.access(left, os.R_OK | os.X_OK) or not os.access(right, os.R_OK | os.X_OK): return "A selected directory is not readable."
    else:
        if not left.is_file() or not right.is_file(): return "File comparison requires two existing regular files."
        if not os.access(left, os.R_OK) or not os.access(right, os.R_OK): return "A selected file is not readable."
    try:
        subprocess.Popen([meld, str(left), str(right)], cwd=ROOT, env=os.environ.copy(), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError as exc:
        return f"Could not launch Meld: {exc}"
    return None


def _comparison_page(message: str | None = None, *, code: int = 200):
    return render_template("meld.html", message=message, backups=_catalog(), distribution=_distribution(), meld_installed=bool(_meld_available())), code


@app.get("/meld")
def meld_dashboard():
    return _comparison_page()


def _submitted_path(name: str) -> Path:
    raw = request.form.get(name, "").strip()
    if not raw:
        raise ValueError(f"Choose a path for {name}.")
    path = Path(raw)
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("Paths must be absolute and must not contain parent traversal.")
    if path.is_symlink():
        raise ValueError("Symbolic-link paths are not supported.")
    try:
        path = path.resolve(strict=True)
    except OSError as exc:
        raise ValueError(f"Path does not exist or cannot be resolved: {raw} ({exc})") from None
    return path


@app.post("/meld/compare")
def compare_paths():
    try:
        left, right = _submitted_path("left"), _submitted_path("right")
        kind = request.form.get("kind")
        if kind not in ("files", "directories"): raise ValueError("Choose files or directories.")
        error = _launch_meld(left, right, kind == "directories")
        return _comparison_page(error or "Meld comparison launched.", code=400 if error else 200)
    except ValueError as exc:
        return _comparison_page(str(exc), code=400)


@app.post("/meld/backup")
def create_manual_backup():
    try:
        path = _submitted_path("path")
        if path.is_symlink() or not (path.is_file() or path.is_dir()): raise ValueError("Choose an existing regular file or directory.")
        run_id = f"manual-{int(time.time())}-{uuid.uuid4().hex[:8]}"
        result = _create_backup([str(path)], run_id, "Manual backup")
        if result.get("error"): return _comparison_page(f"Backup failed: {result['error']}", code=500)
        return _comparison_page(f"Backup created: {result['id']} for {path}")
    except ValueError as exc:
        return _comparison_page(str(exc), code=400)


@app.get("/meld/review/<backup_id>")
def review_run(backup_id: str):
    results = _inspect_backup(backup_id)
    if len(results) == 1 and results[0].get("status") == "error": return _comparison_page(results[0].get("error"), code=404)
    record = next((item for item in _catalog() if item["id"] == backup_id), None)
    if record is None:
        return _comparison_page("Backup record is unavailable.", code=404)
    return render_template("backup_review.html", record=record, results=results, message=None)


@app.post("/meld/compare-backup")
def compare_backup():
    backup_id, raw_path = request.form.get("backup_id", ""), request.form.get("path", "")
    result = _helper("stage", "--id", backup_id, "--path", raw_path)
    if result.get("error"): return _comparison_page(f"Could not stage comparison: {result['error']}", code=400)
    error = _launch_meld(Path(result["before"]), Path(result["current"]), bool(result.get("directory")))
    if error: return _comparison_page(error, code=400)
    return _comparison_page(f"Meld comparison launched for {raw_path}.")


@app.post("/meld/restore")
def restore_backup():
    backup_id, raw_path = request.form.get("backup_id", ""), request.form.get("path", "")
    if request.form.get("confirm") != "yes": return _comparison_page("Confirm that restoration will replace the current file contents.", code=400)
    record = next((item for item in _catalog() if item["id"] == backup_id), None)
    if not record or not any(entry["path"] == raw_path and entry["existed"] for entry in record.get("entries", [])):
        return _comparison_page("The selected backup does not contain an original version of that path.", code=404)
    current_backup = _create_backup([raw_path], f"restore-{uuid.uuid4().hex[:8]}", "Pre-restore current version")
    if current_backup.get("error"): return _comparison_page(f"Restore cancelled because the current version could not be backed up: {current_backup['error']}", code=500)
    result = _helper("restore", "--id", backup_id, "--path", raw_path)
    if result.get("error"): return _comparison_page(f"Restore failed: {result['error']}; current version backup: {current_backup['id']}", code=500)
    return _comparison_page(f"Restored {raw_path}. Previous current version backup: {current_backup['id']}.")


if __name__ == "__main__":
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        raise SystemExit("Do not run the Flask dashboard as root. Start it with ./setup.sh from your desktop user account.")
    app.run(host=os.environ.get("CYBERPATRIOT_HOST", "127.0.0.1"), port=int(os.environ.get("CYBERPATRIOT_PORT", "5000")), debug=False, threaded=True)
