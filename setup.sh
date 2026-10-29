#!/usr/bin/env bash
set -Eeuo pipefail

SKIP_SYSTEM_SETUP=0
while getopts ':a' option; do
    case "$option" in
        a) SKIP_SYSTEM_SETUP=1 ;;
        *) printf 'Usage: %s [-a]\n  -a  Skip system package refresh and Python prerequisite installation.\n' "$0" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
(( $# == 0 )) || { printf 'Usage: %s [-a]\n' "$0" >&2; exit 2; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MAIN_DIR="$SCRIPT_DIR/main"
VENV_DIR="$SCRIPT_DIR/.venv"
VENV_PYTHON="$VENV_DIR/bin/python"

fail() {
    printf 'Dashboard setup error: %s\n' "$*" >&2
    exit 1
}

DISTRO=''
if [[ -r "$SCRIPT_DIR/service_helpers/distribution.sh" ]]; then
    DISTRO="$(bash -c 'source "$1"; load_distribution || exit 1; printf "%s" "$CP_DISTRO"' distribution "$SCRIPT_DIR/service_helpers/distribution.sh" 2>/dev/null)" || fail 'Could not detect a supported distribution from input/distribution.txt.'
fi

PRIVILEGE_CMD=''
if (( EUID == 0 )); then
    PRIVILEGE_CMD=''
elif command -v sudo >/dev/null 2>&1; then
    PRIVILEGE_CMD=sudo
elif command -v doas >/dev/null 2>&1; then
    PRIVILEGE_CMD=doas
fi
run_system() {
    if (( EUID == 0 )); then "$@"
    elif [[ -n "$PRIVILEGE_CMD" ]]; then "$PRIVILEGE_CMD" "$@"
    else fail 'System package setup requires root, sudo, or doas.'; fi
}

if (( ! SKIP_SYSTEM_SETUP )); then
    case "$DISTRO" in
        ubuntu|debian|mint)
            command -v apt-get >/dev/null 2>&1 || fail 'apt-get is required for this distribution.'
            printf 'Refreshing APT package metadata.\n'
            run_system apt-get update || fail 'APT metadata refresh failed.'
            printf 'Installing Python prerequisites.\n'
            run_system env DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv python3-pip || fail 'Python prerequisite installation failed.'
            ;;
        freebsd)
            command -v pkg >/dev/null 2>&1 || fail 'pkg is required for FreeBSD setup.'
            run_system pkg -N >/dev/null 2>&1 || run_system pkg bootstrap -y || fail 'Could not initialize pkg.'
            run_system pkg update || fail 'pkg metadata refresh failed.'
            run_system pkg install -y python3 py311-pip || fail 'Python prerequisite installation failed.'
            ;;
        *) fail 'Could not identify a supported distribution.' ;;
    esac
else
    printf 'Skipping system package refresh and Python prerequisite installation (-a).\n'
fi

command -v python3 >/dev/null 2>&1 || fail 'python3 is required to create the project virtual environment.'

if [[ ! -x "$VENV_PYTHON" ]]; then
    printf 'Creating the project virtual environment at %s\n' "$VENV_DIR"
    python3 -m venv "$VENV_DIR" || fail 'Could not create .venv. Install the Python venv component for your distribution and run ./setup.sh again.'
fi

[[ -x "$VENV_PYTHON" ]] || fail "The virtual environment did not create its Python executable: $VENV_PYTHON"
"$VENV_PYTHON" -m pip --version >/dev/null 2>&1 || fail 'pip is unavailable in .venv. Recreate the virtual environment with Python venv support, then run ./setup.sh again.'

printf 'Installing dashboard dependencies from main/requirements.txt\n'
if ! "$VENV_PYTHON" -m pip install --disable-pip-version-check --no-cache-dir --progress-bar off -q -r "$MAIN_DIR/requirements.txt"; then
    fail 'Dependency installation failed. Check the network/package index and run ./setup.sh again. The dashboard was not started.'
fi

"$VENV_PYTHON" -c 'import flask' >/dev/null 2>&1 || fail 'Flask could not be imported from .venv after installation. The dashboard was not started.'

PRIVILEGE_CMD=''
if (( EUID == 0 )); then
    PRIVILEGE_CMD=''
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    PRIVILEGE_CMD=sudo
elif command -v doas >/dev/null 2>&1 && doas -n true 2>/dev/null; then
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
    if (( EUID == 0 )); then "$@"
    elif [[ "$PRIVILEGE_CMD" == pkexec ]]; then pkexec "$@"
    elif [[ -n "$PRIVILEGE_CMD" ]]; then "$PRIVILEGE_CMD" "$@"
    else return 1; fi
}

configure_passwordless_sudo() {
    (( EUID == 0 )) || return 0
    command -v sudo >/dev/null 2>&1 || return 0
    local target_user="${SUDO_USER:-root}" sudoers_dir=/etc/sudoers.d rule tmp
    if [[ "$DISTRO" == freebsd ]]; then
        sudoers_dir=/usr/local/etc/sudoers.d
        [[ -e /usr/local/etc/sudoers.d ]] || sudoers_dir=/usr/local/etc
    fi
    [[ "$target_user" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*[$]?$ ]] || fail 'Cannot safely determine the account for the sudoers rule.'
    command -v visudo >/dev/null 2>&1 || fail 'visudo is required to safely configure passwordless sudo.'
    [[ -d "$sudoers_dir" && ! -L "$sudoers_dir" ]] || fail "The sudoers directory is unavailable: $sudoers_dir"
    if [[ "$DISTRO" == freebsd && "$sudoers_dir" == /usr/local/etc ]]; then
        rule="$sudoers_dir/90-cyberpatriot-nopasswd"
    else
        rule="$sudoers_dir/90-cyberpatriot-nopasswd"
    fi
    [[ ! -L "$rule" ]] || fail "Refusing to replace a symbolic link at $rule"
    tmp=$(mktemp "$sudoers_dir/.cyberpatriot-nopasswd.XXXXXX") || fail 'Could not prepare the sudoers rule.'
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$target_user" > "$tmp"
    chmod 0440 "$tmp" || { rm -f "$tmp"; fail 'Could not set safe permissions on the sudoers rule.'; }
    if ! visudo -cf "$tmp"; then rm -f "$tmp"; fail 'Generated sudoers rule did not validate; existing policy was left unchanged.'; fi
    mv -f -- "$tmp" "$rule" || { rm -f "$tmp"; fail 'Could not install the sudoers rule.'; }
    visudo -c || fail 'Sudoers validation failed after installing the CyberPatriot rule.'
    printf 'Configured passwordless sudo for %s.\n' "$target_user"
}

configure_passwordless_sudo
if command -v meld >/dev/null 2>&1; then
    printf 'Meld is already installed: %s\n' "$(command -v meld)"
elif [[ "$DISTRO" == ubuntu || "$DISTRO" == debian || "$DISTRO" == mint ]]; then
    if ! command -v apt-get >/dev/null 2>&1; then
        printf 'Meld is unavailable: apt-get was not found. Install Meld manually if this desktop supports it.\n' >&2
    elif ! apt-cache show meld >/dev/null 2>&1; then
        printf 'Meld is unavailable from the configured APT repositories; continuing without it.\n' >&2
    elif (( EUID == 0 )) || privilege_available; then
        if run_privileged apt-get install -y meld; then printf 'Meld installation completed.\n'; else printf 'Meld installation failed; the dashboard will continue without Meld.\n' >&2; fi
    else
        if [[ "$PRIVILEGE_CMD" == doas ]]; then printf 'Meld is available through APT but could not be installed automatically. Install it with: doas apt-get install meld\n' >&2; elif [[ "$PRIVILEGE_CMD" == pkexec ]]; then printf 'Meld is available through APT but could not be installed automatically. Install it with: pkexec apt-get install meld\n' >&2; else printf 'Meld is available through APT but could not be installed automatically. Install it with: sudo apt-get install meld\n' >&2; fi
    fi
elif [[ "$DISTRO" == freebsd ]]; then
    if command -v pkg >/dev/null 2>&1 && pkg search -U -q -x '^meld-[0-9]' 2>/dev/null | grep -q .; then
        if (( EUID == 0 )) || privilege_available; then
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
if (( EUID == 0 )); then
    DASHBOARD_USER="${SUDO_USER:-}"
    if [[ -n "$DASHBOARD_USER" ]] && id "$DASHBOARD_USER" >/dev/null 2>&1; then
        exec su -m "$DASHBOARD_USER" -c "exec env CYBERPATRIOT_HOST=127.0.0.1 CYBERPATRIOT_PORT=$PORT $VENV_PYTHON $MAIN_DIR/run_dashboard.py"
    fi
    fail 'When setup.sh is run as root, set SUDO_USER to the desktop account so the dashboard can stay unprivileged.'
fi
exec env CYBERPATRIOT_HOST=127.0.0.1 "CYBERPATRIOT_PORT=$PORT" "$VENV_PYTHON" "$MAIN_DIR/run_dashboard.py"
