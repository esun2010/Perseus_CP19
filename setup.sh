#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MAIN_DIR="$SCRIPT_DIR/main"
VENV_DIR="$SCRIPT_DIR/.venv"
VENV_PYTHON="$VENV_DIR/bin/python"

fail() {
    printf 'Dashboard setup error: %s\n' "$*" >&2
    exit 1
}

command -v python3 >/dev/null 2>&1 || fail 'python3 is required to create the project virtual environment.'

if [[ ! -x "$VENV_PYTHON" ]]; then
    printf 'Creating the project virtual environment at %s\n' "$VENV_DIR"
    python3 -m venv "$VENV_DIR" || fail 'Could not create .venv. Install the Python venv component for your distribution and run ./setup.sh again.'
fi

[[ -x "$VENV_PYTHON" ]] || fail "The virtual environment did not create its Python executable: $VENV_PYTHON"
"$VENV_PYTHON" -m pip --version >/dev/null 2>&1 || fail 'pip is unavailable in .venv. Recreate the virtual environment with Python venv support, then run ./setup.sh again.'

printf 'Installing dashboard dependencies from main/requirements.txt\n'
if ! "$VENV_PYTHON" -m pip install --disable-pip-version-check --no-cache-dir -r "$MAIN_DIR/requirements.txt"; then
    fail 'Dependency installation failed. Check the network/package index and run ./setup.sh again. The dashboard was not started.'
fi

"$VENV_PYTHON" -c 'import flask' >/dev/null 2>&1 || fail 'Flask could not be imported from .venv after installation. The dashboard was not started.'

PORT="${CYBERPATRIOT_PORT:-5000}"
[[ "$PORT" =~ ^[0-9]+$ ]] || fail "Invalid CYBERPATRIOT_PORT: $PORT"
PORT_NUMBER=$((10#$PORT))
(( PORT_NUMBER >= 1 && PORT_NUMBER <= 65535 )) || fail "Invalid CYBERPATRIOT_PORT: $PORT (expected 1–65535)"
PORT="$PORT_NUMBER"

if ! "$VENV_PYTHON" - "$PORT" <<'PY'
import socket
import sys

with socket.socket() as probe:
    if probe.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0:
        raise SystemExit(1)
PY
then
    fail "Port $PORT is already in use. A dashboard may already be running; stop it with Ctrl+C before starting another."
fi

cd "$SCRIPT_DIR"
if (( EUID == 0 )); then
    printf 'Starting the dashboard at http://127.0.0.1:%s\n' "$PORT"
    exec env CYBERPATRIOT_HOST=127.0.0.1 "CYBERPATRIOT_PORT=$PORT" "$VENV_PYTHON" "$MAIN_DIR/run_dashboard.py"
fi

command -v sudo >/dev/null 2>&1 || fail 'sudo is required to run the dashboard with permission to execute the CyberPatriot scripts.'
sudo -v || fail 'Could not obtain elevated privileges to run the dashboard. The server was not started.'
printf 'Starting the dashboard at http://127.0.0.1:%s\n' "$PORT"
exec sudo -- env CYBERPATRIOT_HOST=127.0.0.1 "CYBERPATRIOT_PORT=$PORT" "$VENV_PYTHON" "$MAIN_DIR/run_dashboard.py"
