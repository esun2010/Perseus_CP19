#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ $EUID -ne 0 ]]; then echo 'Run this scan as root.' >&2; exit 1; fi
if ! command -v clamscan >/dev/null 2>&1; then
    if [[ $(uname -s) == FreeBSD ]]; then
        source "$SCRIPT_DIR/../platforms/FreeBSD/service_helpers/platform.sh"
        require_freebsd_root || exit 1
        ensure_packages clamav || { echo 'Could not install ClamAV.' >&2; exit 1; }
    else
        source "$SCRIPT_DIR/../service_helpers/distribution.sh"
        load_distribution || { echo 'Could not identify a supported distribution.' >&2; exit 1; }
        [[ "$CP_DISTRO" == ubuntu || "$CP_DISTRO" == debian || "$CP_DISTRO" == mint ]] || { echo "ClamAV autoinstall is unsupported on $CP_DISTRO." >&2; exit 1; }
        command -v apt-get >/dev/null 2>&1 || { echo 'apt-get is required to install ClamAV.' >&2; exit 1; }
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq clamav
    fi
fi
LOG_DIR="$SCRIPT_DIR/../log"
REPORT="$LOG_DIR/clamav.txt"
mkdir -p "$LOG_DIR"
printf 'ClamAV scan: %s\n' "$(date -u '+%FT%TZ')" | tee "$REPORT"
clamscan --recursive --infected --exclude-dir='^/(proc|sys|dev|run)(/|$)' / 2>&1 | tee -a "$REPORT"
