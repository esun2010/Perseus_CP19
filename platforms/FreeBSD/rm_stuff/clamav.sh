#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../service_helpers/platform.sh"
require_freebsd_root
if ! command -v clamscan >/dev/null 2>&1; then echo 'ClamAV is not installed.' >&2; exit 1; fi
REPORT="$SCRIPT_DIR/../../../log/clamav.txt"
mkdir -p "$(dirname "$REPORT")"
printf 'ClamAV scan: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" | tee "$REPORT"
clamscan --recursive --infected --exclude-dir='^/(proc|sys|dev)(/|$)' / 2>&1 | tee -a "$REPORT"
