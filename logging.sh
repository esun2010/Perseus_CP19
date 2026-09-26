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

# Persistent pre-change snapshots. Keep copies outside configuration directories
# so services cannot accidentally load them as additional configuration.
# Override only for an isolated test or another private backup destination.
backup_system_paths() {
    local root="${CP_BACKUP_ROOT:-/var/backups/cyberpatriot}" snapshot path parent target
    SYSTEM_BACKUP_DIR=
    [[ "$root" == /* && "$root" != / && "$root" != *//* && "$root" != */ && "$root/" != *'/../'* && "$root/" != *'/./'* ]] || {
        log "FAILED invalid backup directory: $root"; return 1;
    }
    # Refuse linked ancestors: chmod/copies must never escape the backup tree.
    parent="$root"
    while [[ -n "$parent" ]]; do
        [[ ! -L "$parent" ]] || { log "FAILED symbolic link in backup directory: $parent"; return 1; }
        parent=${parent%/*}
    done
    (umask 077; mkdir -p "$root") || { log "FAILED creating backup directory: $root"; return 1; }
    [[ -d "$root" && -O "$root" ]] && chmod 700 "$root" || {
        log "FAILED securing backup directory: $root"; return 1;
    }
    snapshot=$(mktemp -d "$root/$(date -u '+%Y%m%dT%H%M%SZ').XXXXXX") || {
        log "FAILED creating system backup"; return 1;
    }
    # Copy original modes/owners inside private parents; even a permissive
    # original password/key file remains inaccessible to other users here.
    chmod 700 "$snapshot" || return 1
    for path in "$@"; do
        [[ "$path" == /* && "$path" != / && "$path" != *//* && "$path" != */ && "$path/" != *'/../'* && "$path/" != *'/./'* && "$root" != "$path" && "$root" != "$path/"* ]] || {
            log "FAILED unsafe backup source: $path"; return 1;
        }
        [[ ! -L "$path" ]] || { log "FAILED symbolic-link backup source: $path; resolve it before editing"; return 1; }
        if [[ -e "$path" ]]; then
            [[ -f "$path" || -d "$path" ]] || { log "FAILED unsupported backup source: $path"; return 1; }
            target="$snapshot/files$path"
            if ! (umask 077; mkdir -p "${target%/*}") || ! cp -pPR "$path" "$target"; then
                log "FAILED backing up $path; change cancelled (incomplete snapshot: $snapshot)"
                return 1
            fi
            printf 'SAVED %q\n' "$path" >> "$snapshot/manifest.txt" || return 1
        else
            # A missing file has no bytes to save. Record this so restoration
            # can distinguish a newly created file from a pre-existing one.
            printf 'ABSENT %q\n' "$path" >> "$snapshot/manifest.txt" || return 1
        fi
    done
    touch "$snapshot/COMPLETE" || return 1
    SYSTEM_BACKUP_DIR="$snapshot"
    log "BACKUP complete: $snapshot (original paths under files/; see manifest.txt)"
}

# Native account tools rewrite these files without going through the diff logger.
backup_account_databases() {
    backup_system_paths /etc/passwd /etc/shadow /etc/group /etc/gshadow \
        /etc/subuid /etc/subgid /etc/security/opasswd
}

# Package hooks can rewrite configuration and account databases, too.
backup_package_configuration() {
    backup_system_paths /etc
}

# Run a file-editing function and record the actual diff, even on partial failure.
audit_file_change() {
    local file="$1" before changes status=0 existed=no diff_status=0
    shift
    backup_system_paths "$file" || return 1
    if [[ -e "$file" ]]; then
        existed=yes
        before="$SYSTEM_BACKUP_DIR/files$file"
    else
        before="$SYSTEM_BACKUP_DIR/empty-before"
        (umask 077; : > "$before") || return 1
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
    [[ "$status" == 0 ]] || log "FAILED editing $file (exit $status)"
    return "$status"
}

audit_chmod() {
    local mode="$1" path="$2" old new
    old=$(stat -c '%a' -- "$path") || { log "FAILED reading permissions: $path"; return 1; }
    # Directory mode changes are logged; do not recursively copy their contents.
    if [[ -f "$path" && "$old" != "$mode" ]]; then
        backup_system_paths "$path" || return 1
    fi
    if chmod "$mode" -- "$path"; then
        new=$(stat -c '%a' -- "$path") || { log "FAILED verifying permissions: $path"; return 1; }
        [[ "$old" == "$new" ]] || log "CHANGED permissions: $path: $old -> $new"
    else
        log "FAILED chmod $mode: $path (was $old)"
        return 1
    fi
}
