#!/usr/bin/env bash
# Safe regression checks: all task executions and package operations use fixtures.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/cyberpatriot-tests.XXXXXX")
trap 'rm -rf "$TEMP"' EXIT
export CP_BACKUP_ROOT="$TEMP/backups"
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

while IFS= read -r -d '' script; do bash -n "$script"; done < <(find "$ROOT" -name '*.sh' -not -path '*/.git/*' -print0)
sh -n "$ROOT/bootstrap.sh"
pass 'all shell files parse; bootstrap also parses as sh'

source "$ROOT/service_helpers/platform.sh"
(
    uname() { echo Linux; }
    if require_freebsd_root 2>/dev/null; then exit 1; fi
    uname() { echo FreeBSD; }
    id() { echo 1001; }
    if require_freebsd_root 2>/dev/null; then exit 1; fi
    id() { echo 0; }
    sysctl() { echo 1; }
    if require_freebsd_root 2>/dev/null; then exit 1; fi
    sysctl() { echo 0; }
    require_freebsd_root
) || fail 'platform guard'
pass 'platform guard rejects Linux, non-root, and jails'
(
    backup_package_configuration() { :; }
    pkg() {
        printf '%s\n' "$*" >> "$TEMP/packages"
        case "$*" in
            '-N') return 0 ;;
            'info -e bash') return 0 ;;
            'info -e apache24') [[ -f "$TEMP/installed" ]] ;;
            'install -y apache24') touch "$TEMP/installed" ;;
            *) return 1 ;;
        esac
    }
    ensure_packages bash apache24
    ensure_packages bash apache24
    if ensure_packages --force 2>/dev/null; then exit 1; fi
) || fail 'package helper'
[[ $(grep -c '^install -y apache24$' "$TEMP/packages") == 1 ]] || fail 'package reinstalled'
pass 'packages are installed only when absent and invalid names fail'

(
    source "$ROOT/../../main/logging.sh"
    LOG_FILE="$TEMP/audit.log"
    printf 'old setting\n' > "$TEMP/config"
    edit_config() { printf 'new setting\n' > "$TEMP/config"; }
    partial_failure() { printf 'partial setting\n' > "$TEMP/config"; return 7; }
    audit_file_change "$TEMP/config" edit_config >/dev/null
    audit_file_change "$TEMP/config" partial_failure >/dev/null && exit 1
    grep -q -- '-old setting' "$LOG_FILE"
    grep -q -- '+new setting' "$LOG_FILE"
    grep -q 'FAILED editing' "$LOG_FILE"
) || fail 'audit diff'
pass 'audit records successful and failed configuration edits'

python3 "$ROOT/../../tests/distribution_test.py"
pass 'shared launchers select native overrides and preserve failure/resume behavior'
printf '\n%d regression groups passed. No host hardening was run.\n' "$passed"
