#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ $EUID -ne 0 ]]; then echo 'Run this scan as root.' >&2; exit 1; fi
if ! command -v clamscan >/dev/null 2>&1; then echo 'ClamAV is not installed. Select mal in run_all.sh to install it.' >&2; exit 1; fi
LOG_DIR="$SCRIPT_DIR/../log"
REPORT="$LOG_DIR/clamav.txt"
mkdir -p "$LOG_DIR"
printf 'ClamAV scan: %s\n' "$(date -u '+%FT%TZ')" | tee "$REPORT"
clamscan --recursive --infected --exclude-dir='^/(proc|sys|dev|run)(/|$)' / 2>&1 | tee -a "$REPORT"
