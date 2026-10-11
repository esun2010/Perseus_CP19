#!/usr/bin/env python3
"""Local Flask dashboard for the existing CyberPatriot scripts."""
from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

from flask import Flask, abort, jsonify, redirect, render_template, request, url_for

ROOT = Path(__file__).resolve().parents[1]
STATE_PATH = ROOT / ".webapp_state.json"
STATE_LOCK = threading.RLock()
RUNS: dict[str, dict[str, Any]] = {}

app = Flask(__name__, template_folder=str(ROOT / "webapp" / "templates"), static_folder=str(ROOT / "webapp" / "static"))
app.secret_key = os.environ.get("CYBERPATRIOT_FLASK_SECRET", "local-cyberpatriot-dashboard")

# Keep this order aligned with ORDER and SCRIPT_MAP in run_all.sh.
TASKS = [
    {"id": "mal", "name": "ClamAV Scan", "script": "rm_stuff/clamav.sh", "logs": ["log/clamav.txt"]},
    {"id": "ker", "name": "Kernel", "script": "misc/kernel.sh", "configs": ["/etc/sysctl.d/99-hardening.conf", "/etc/sysctl.conf", "/etc/sudoers", "/etc/polkit-1/rules.d/00-cyberpatriot-admins.rules", "/usr/local/etc/sudoers", "/usr/local/etc/polkit-1/rules.d", "/etc/rc.conf", "/etc/fstab"]},
    {"id": "log", "name": "Guest Login", "script": "misc/login.sh", "configs": ["/etc/lightdm", "/etc/gdm3", "/etc/sddm.conf", "/usr/local/etc/lightdm"]},
    {"id": "pol", "name": "Password Policy", "script": "password_management/pwd_policy.sh", "configs": ["/etc/login.defs", "/etc/security/pwquality.conf", "/etc/security/faillock.conf", "/etc/pam.d/common-auth", "/etc/pam.d/common-account", "/etc/pam.d/common-password", "/etc/pam.d/common-session", "/etc/pam.d/common-session-noninteractive", "/usr/share/pam-configs/cyberpatriot-faillock-preauth", "/usr/share/pam-configs/cyberpatriot-faillock-authfail", "/etc/pam.d/passwd", "/etc/login.conf", "/etc/login.conf.db"]},
    {"id": "usr", "name": "User Audit", "script": "user_management/user_management.sh", "logs": ["log/unauth_users(2).txt", "log/unauth_admins(2).txt"], "second": {"name": "User Cleanup", "script": "user_management/user_management_2.sh", "logs": ["log/user_management(2).txt"], "configs": ["/etc/passwd", "/etc/shadow", "/etc/group", "/etc/gshadow", "/etc/passwd-", "/etc/shadow-", "/etc/group-", "/etc/gshadow-", "/etc/master.passwd", "/etc/pwd.db", "/etc/spwd.db"]}},
    {"id": "mp3", "name": "Media Inventory", "script": "rm_stuff/rm_mp3+.sh", "logs": ["log/media_files(2).txt"], "second": {"name": "Media Cleanup", "script": "rm_stuff/rm_mp3+_2.sh", "logs": ["log/media_cleanup(2).txt"]}},
    {"id": "pkg", "name": "Bad Packages", "script": "rm_stuff/bad_pkg.sh", "edit_packages": True, "configs": ["/etc", "/usr/local/etc"]},
    {"id": "per", "name": "File Permissions", "script": "misc/file_permissions.sh", "configs": ["/etc/sudoers", "/etc/ssh/sshd_config", "/etc/crontab", "/etc/fstab", "/etc/hosts", "/etc/hostname", "/etc/master.passwd", "/etc/passwd", "/etc/group", "/etc/pwd.db", "/usr/local/etc/pam.d"], "logs": ["log/world_files.txt", "log/world_files.txt.errors"]},
    {"id": "sys", "name": "System Components", "script": "misc/system_hardening.sh", "configs": ["/etc/nsswitch.conf", "/etc/ssl/openssl.cnf", "/etc/ssl/private", "/etc/default/grub", "/boot/grub/grub.cfg", "/boot/grub2/grub.cfg", "/etc/selinux/config", "/etc/ufw", "/etc/iptables", "/etc/nftables.conf", "/etc/dhcp/dhclient.conf", "/etc/dhcp/dhclient-enter-hooks.d", "/etc/dhcp/dhclient-exit-hooks.d"]},
]

INPUT_FILES = [
    "input/auth_users.txt",
    "input/auth_admins.txt",
    "input/critical_services.txt",
    "input/distribution.txt",
]
UPDATE_ACTION = {
    "id": "updates",
    "name": "Updates and APT Reset",
    "description": "Runs the initial startup repair and package refresh/upgrade steps used by run_all.sh.",
    "configs": ["/etc/environment", "/etc/apt"],
}


def _load_state() -> dict[str, Any]:
    try:
        data = json.loads(STATE_PATH.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


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
    modified = []
    with STATE_LOCK:
        state = _load_state()
    for path in state.get("modified", {}).get(script_path, []):
        try:
            if _is_regular_view_file(path):
                modified.append(path)
        except Exception:
            continue
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


def _task_by_script(script: str) -> dict[str, Any] | None:
    for task in TASKS:
        if task["script"] == script or task.get("second", {}).get("script") == script:
            return task
    return None


def _run_update_steps(run_id: str) -> list[str]:
    env = os.environ.copy()
    env["PATH"] = "/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin"
    env["ROOT"] = str(ROOT)
    distro = "freebsd" if platform.system() == "FreeBSD" else "linux"
    if distro == "freebsd":
        steps = 'source "$ROOT/logging.sh"; init_logging; source "$ROOT/service_helpers/startup_repair.sh"; startup_repair; pkg -N >/dev/null 2>&1 || pkg bootstrap -y; pkg update; backup_package_configuration; pkg upgrade'
    else:
        steps = 'source "$ROOT/logging.sh"; init_logging; source "$ROOT/service_helpers/startup_repair.sh"; startup_repair; sudo apt update; backup_package_configuration; sudo apt upgrade'
    output_path = ROOT / "log" / "webapp-runs" / f"{run_id}.log"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("ab") as output:
        command = ["bash", "-c", "set -euo pipefail; " + steps]
        output.write(("$ " + " ".join(command) + "\n").encode())
        output.flush()
        proc = subprocess.run(command, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT, check=False)
        if proc.returncode != 0:
            raise subprocess.CalledProcessError(proc.returncode, command)
    return [str(output_path.relative_to(ROOT))]


def _execute_script(script: str, run_id: str) -> None:
    config_candidates = []
    task = _task_by_script(script)
    if task:
        if task.get("second", {}).get("script") == script:
            config_candidates = list(task["second"].get("configs", []))
        else:
            config_candidates = list(task.get("configs", []))
    script_path = ROOT / script
    command = ["bash", str(script_path)]
    if not script_path.is_file():
        _finish_run(script, run_id, 127, f"Missing script: {script}", {})
        return
    before = _snapshot(config_candidates)
    output_path = ROOT / "log" / "webapp-runs" / f"{run_id}.log"
    try:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        env = os.environ.copy()
        env["PATH"] = "/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin"
        with output_path.open("ab") as output:
            proc = subprocess.Popen(command, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            if RUNS.get(script, {}).get("run_id") == run_id:
                RUNS[script].update({"status": "Running", "message": "Running...", "exit_code": None, "pid": proc.pid, "output": str(output_path.relative_to(ROOT))})
            code = proc.wait()
        after = _snapshot(config_candidates)
        changed = [key for key, value in after.items() if value is not None and value != before.get(key)]
        if RUNS.get(script, {}).get("run_id") == run_id:
            with STATE_LOCK:
                state = _load_state()
                state.setdefault("modified", {})[script] = changed
                _save_state(state)
        message = "Ran successfully" if code == 0 else "Failed"
        _finish_run(script, run_id, code, message, {"output": str(output_path.relative_to(ROOT)), "modified": changed})
    except OSError as exc:
        _finish_run(script, run_id, 127, f"Failed to launch: {exc}", {})


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
    aggregate = [name for name in ("all_logs.txt", "all_logs(2).txt") if _is_regular_view_file(name)]
    return render_template("dashboard.html", tasks=_all_tasks(), inputs=INPUT_FILES, update=UPDATE_ACTION, update_status=update_status, update_files=update_files, aggregate=aggregate)


@app.post("/run/<path:script>")
def run_script(script: str):
    if script != "updates":
        task = _task_by_script(script)
        if task is None:
            abort(404)
    else:
        script = "__updates__"
    run_id = f"{int(time.time() * 1000)}-{os.urandom(4).hex()}"
    status_key = "__updates__" if script == "updates" else script
    RUNS[status_key] = {"status": "Running", "message": "Running...", "exit_code": None, "run_id": run_id}
    worker = threading.Thread(target=_execute_updates if script == "__updates__" else _execute_script, args=(run_id,) if script == "__updates__" else (script, run_id), daemon=True)
    worker.start()
    return jsonify({"script": script, "run_id": run_id, "status": "Running", "message": "Running..."}), 202


def _execute_updates(run_id: str) -> None:
    before = _snapshot(UPDATE_ACTION["configs"])
    output_path = ROOT / "log" / "webapp-runs" / f"{run_id}.log"
    if RUNS.get("__updates__", {}).get("run_id") == run_id:
        RUNS["__updates__"]["output"] = str(output_path.relative_to(ROOT))
    try:
        outputs = _run_update_steps(run_id)
        code, message = 0, "Ran successfully"
    except (OSError, subprocess.CalledProcessError) as exc:
        code = getattr(exc, "returncode", 127)
        outputs = [str(output_path.relative_to(ROOT))]
        message = f"Failed (exit {code})"
    after = _snapshot(UPDATE_ACTION["configs"])
    changed = [key for key, value in after.items() if value is not None and value != before.get(key)]
    if RUNS.get("__updates__", {}).get("run_id") == run_id:
        with STATE_LOCK:
            state = _load_state()
            state.setdefault("modified", {})["__updates__"] = changed
            _save_state(state)
    _finish_run("__updates__", run_id, code, message, {"output": outputs[0] if outputs else None, "modified": changed})


@app.get("/status/<path:script>")
def status(script: str):
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
    if relpath not in INPUT_FILES:
        abort(404)
    path = _resolve_repo_file(relpath)
    if not path.is_file() or path.is_symlink():
        return render_template("edit.html", relpath=relpath, filename=path.name, contents="", error="This input file is missing or is not a regular file."), 404
    try:
        contents = path.read_text(encoding="utf-8")
    except OSError as exc:
        contents = ""
        error = str(exc)
    else:
        error = None
    return render_template("edit.html", relpath=relpath, filename=path.name, contents=contents, error=error)


@app.post("/edit/<path:relpath>")
def save_input(relpath: str):
    if relpath not in INPUT_FILES:
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
        return render_template("edit.html", relpath=relpath, filename=path.name, contents=content, error=str(exc)), 500
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


if __name__ == "__main__":
    app.run(host=os.environ.get("CYBERPATRIOT_HOST", "127.0.0.1"), port=int(os.environ.get("CYBERPATRIOT_PORT", "5000")), debug=False, threaded=True)
