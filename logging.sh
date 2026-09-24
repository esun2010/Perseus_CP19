#!/bin/bash
# Shared append-only audit log, located beside this helper regardless of cwd.
LOG_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/all_logs.txt"
LOG_SCRIPT="$(basename "$0")"

log() {
    local message="$*"
    printf '[+] %s\n' "$message"
    # Escape backslashes and control characters while keeping prose readable.
    message=${message//\\/\\\\}
    message=${message//$'\n'/\\n}
    message=${message//$'\r'/\\r}
    message=${message//$'\t'/\\t}
    printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$LOG_SCRIPT" "$message" >> "$LOG_FILE" || {
        printf 'Cannot append to audit log: %s\n' "$LOG_FILE" >&2
        exit 1
    }
}

init_logging() {
    touch "$LOG_FILE" || { printf 'Cannot open audit log: %s\n' "$LOG_FILE" >&2; exit 1; }
    log "START"
    trap 'audit_status=$?; log "END exit=$audit_status"' EXIT
}

# Run a file-editing function and record the actual diff, even on partial failure.
audit_file_change() {
    local file="$1" before changes status=0 existed=no diff_status=0
    shift
    before=$(mktemp) || return 1
    if [[ -e "$file" ]]; then
        existed=yes
        cp -- "$file" "$before" || { rm -f -- "$before"; return 1; }
    fi
    "$@" || status=$?
    if [[ -e "$file" ]]; then
        [[ "$existed" == yes ]] || log "CREATED file: $file"
        changes=$(diff -u --label "$file (before)" --label "$file (after)" "$before" "$file") || diff_status=$?
        if [[ "$diff_status" == 1 ]]; then
            log "CHANGED $file (- removed/old, + added/new): $changes"
        elif [[ "$diff_status" != 0 ]]; then
            log "FAILED to compare $file"
            status=1
        fi
    elif [[ "$existed" == yes ]]; then
        log "DELETED file: $file"
    fi
    rm -f -- "$before"
    [[ "$status" == 0 ]] || log "FAILED editing $file (exit $status)"
    return "$status"
}

audit_chmod() {
    local mode="$1" path="$2" old new
    old=$(stat -c '%a' -- "$path") || { log "FAILED reading permissions: $path"; return 1; }
    if chmod "$mode" -- "$path"; then
        new=$(stat -c '%a' -- "$path") || { log "FAILED verifying permissions: $path"; return 1; }
        [[ "$old" == "$new" ]] || log "CHANGED permissions: $path: $old -> $new"
    else
        log "FAILED chmod $mode: $path (was $old)"
        return 1
    fi
}
