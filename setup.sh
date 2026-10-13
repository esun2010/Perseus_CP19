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

(( EUID != 0 )) || fail 'Run ./setup.sh from the desktop user account, not from a root shell. The Flask server stays unprivileged and requests sudo only for scripts and protected file operations.'

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

PRIVILEGE_CMD=''
if command -v sudo >/dev/null 2>&1 && sudo -v; then
    PRIVILEGE_CMD=sudo
elif command -v doas >/dev/null 2>&1 && doas true; then
    PRIVILEGE_CMD=doas
elif command -v pkexec >/dev/null 2>&1; then
    PRIVILEGE_CMD=pkexec
    printf 'Dashboard setup: pkexec is available for graphical authorization prompts.\n'
elif command -v sudo >/dev/null 2>&1; then
    PRIVILEGE_CMD=sudo
    printf 'Dashboard setup: sudo authorization was not obtained; protected operations may fail until privilege access is available.\n' >&2
elif command -v doas >/dev/null 2>&1; then
    PRIVILEGE_CMD=doas
    printf 'Dashboard setup: doas authorization was not obtained; protected operations may fail until privilege access is available.\n' >&2
else
    printf 'Dashboard setup: sudo/doas is unavailable; protected dashboard operations will report permission errors.\n' >&2
fi

privilege_available() {
    if [[ "$PRIVILEGE_CMD" == pkexec ]]; then command -v pkexec >/dev/null 2>&1
    elif [[ -n "$PRIVILEGE_CMD" ]]; then command -v "$PRIVILEGE_CMD" >/dev/null 2>&1
    else return 1; fi
}
run_privileged() {
    if [[ "$PRIVILEGE_CMD" == pkexec ]]; then pkexec "$@"
    elif [[ -n "$PRIVILEGE_CMD" ]]; then "$PRIVILEGE_CMD" "$@"
    else return 1; fi
}

DISTRO=''
if [[ -r "$SCRIPT_DIR/service_helpers/distribution.sh" ]]; then
    DISTRO="$(bash -c 'source "$1"; load_distribution || exit 1; printf "%s" "$CP_DISTRO"' distribution "$SCRIPT_DIR/service_helpers/distribution.sh" 2>/dev/null || true)"
fi
if command -v meld >/dev/null 2>&1; then
    printf 'Meld is already installed: %s\n' "$(command -v meld)"
elif [[ "$DISTRO" == ubuntu || "$DISTRO" == debian || "$DISTRO" == mint ]]; then
    if ! command -v apt-get >/dev/null 2>&1; then
        printf 'Meld is unavailable: apt-get was not found. Install Meld manually if this desktop supports it.\n' >&2
    elif ! apt-cache show meld >/dev/null 2>&1; then
        printf 'Meld is unavailable from the configured APT repositories; continuing without it.\n' >&2
    elif privilege_available; then
        if run_privileged apt-get install -y meld; then printf 'Meld installation completed.\n'; else printf 'Meld installation failed; the dashboard will continue without Meld.\n' >&2; fi
    else
        if [[ "$PRIVILEGE_CMD" == doas ]]; then printf 'Meld is available through APT but could not be installed automatically. Install it with: doas apt-get install meld\n' >&2; elif [[ "$PRIVILEGE_CMD" == pkexec ]]; then printf 'Meld is available through APT but could not be installed automatically. Install it with: pkexec apt-get install meld\n' >&2; else printf 'Meld is available through APT but could not be installed automatically. Install it with: sudo apt-get install meld\n' >&2; fi
    fi
elif [[ "$DISTRO" == freebsd ]]; then
    if command -v pkg >/dev/null 2>&1 && pkg search -U -q -x '^meld-[0-9]' 2>/dev/null | grep -q .; then
        if privilege_available; then
            if run_privileged pkg install -y meld; then printf 'Meld installation completed through pkg.\n'; else printf 'Meld is listed by pkg but installation failed; continuing without it.\n' >&2; fi
        else
            if [[ "$PRIVILEGE_CMD" == doas ]]; then printf 'A Meld package is listed for this FreeBSD release. Install it with: doas pkg install meld\n' >&2; else printf 'A Meld package is listed for this FreeBSD release. Install it with: sudo pkg install meld\n' >&2; fi
        fi
    else
        printf 'No compatible Meld package was found for this FreeBSD release; the dashboard will continue without Meld.\n' >&2
    fi
else
    printf 'Could not identify a supported distribution using service_helpers/distribution.sh. Skipping Meld installation.\n' >&2
fi

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
printf 'Starting the dashboard at http://127.0.0.1:%s\n' "$PORT"
exec env CYBERPATRIOT_HOST=127.0.0.1 "CYBERPATRIOT_PORT=$PORT" "$VENV_PYTHON" "$MAIN_DIR/run_dashboard.py"
