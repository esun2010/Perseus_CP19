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
    printf '%s %s\n' "$LOG_SCRIPT" "$message" >> "$LOG_FILE" || {
        printf 'Cannot append to audit log: %s\n' "$LOG_FILE" >&2
        exit 1
    }
}

init_logging() {
    [[ ! -L "$LOG_FILE" && ( ! -e "$LOG_FILE" || -f "$LOG_FILE" ) ]] || {
        printf 'Refusing unsafe audit log path: %s\n' "$LOG_FILE" >&2; exit 1;
    }
    touch "$LOG_FILE" || { printf 'Cannot open audit log: %s\n' "$LOG_FILE" >&2; exit 1; }
    chmod 644 "$LOG_FILE" || exit 1
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
    if [[ $(uname -s) == FreeBSD ]]; then
        backup_system_paths /etc/master.passwd /etc/passwd /etc/group /etc/pwd.db /etc/spwd.db
    else
        backup_system_paths /etc/passwd /etc/shadow /etc/group /etc/gshadow \
            /etc/subuid /etc/subgid /etc/security/opasswd
    fi
}

# Package hooks can rewrite configuration and account databases, too.
backup_package_configuration() {
    if [[ $(uname -s) == FreeBSD ]]; then backup_system_paths /etc /usr/local/etc
    else backup_system_paths /etc; fi
}

# Compare active configuration records rather than treating a diff as a setting.
# Section names and repeated directives remain distinct from unrelated settings.
# Unstructured policy lines fall back to a directive/value record.
audit_setting_changes() {
    local file="$1" before="$2" after="$3" records record
    records=$(awk -v path="$file" '
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        function save(key, value,    id) {
            id=section == "" ? key : section "/" key
            if (side == 0) {
                if (id in old) old[id]=old[id] " | " value
                else { old[id]=value; old_order[++old_count]=id }
            } else {
                if (id in new) new[id]=new[id] " | " value
                else { new[id]=value; new_order[++new_count]=id }
            }
        }
        FNR == 1 { section="" }
        {
            side=(FILENAME == ARGV[1] ? 0 : 1)
            line=trim($0)
            if (line == "" || line ~ /^(#|;|\/\/)/) next
            if (line ~ /^\[[^]]+\][ \t]*([#;].*)?$/) {
                section=line; sub(/\].*$/, "]", section); next
            }
            if (path ~ /\.rules$/) {
                # Polkit JavaScript is a policy, not a key=value file. Preserve
                # every active line under one setting, including removed rules.
                save("policy", line); next
            }
            if (path ~ /\/fstab$/ && split(line, fields, /[ \t]+/) >= 4) {
                save(fields[2] "/source", fields[1])
                save(fields[2] "/type", fields[3])
                save(fields[2] "/options", fields[4])
                save(fields[2] "/dump", fields[5])
                save(fields[2] "/pass", fields[6]); next
            }
            if (line ~ /^Defaults[ \t]+/) {
                sub(/^Defaults[ \t]+/, "", line)
                at=index(line, "=")
                if (at) save("Defaults " trim(substr(line,1,at-1)), trim(substr(line,at+1)))
                else save("Defaults " line, "enabled")
                next
            }
            at=index(line, "=")
            if (at) {
                save(trim(substr(line,1,at-1)), trim(substr(line,at+1))); next
            }
            key=line; sub(/[ \t].*$/, "", key)
            save(key, trim(substr(line,length(key)+1)))
        }
        END {
            for (i=1; i<=new_count; i++) {
                key=new_order[i]
                if (!(key in old)) print "added " path ":" key " with new value " new[key]
                else if (old[key] != new[key]) print "changed " path ":" key " from " old[key] " to " new[key]
            }
            for (i=1; i<=old_count; i++) {
                key=old_order[i]
                if (!(key in new)) print "changed " path ":" key " from " old[key] " to <unset>"
            }
        }
    ' "$before" "$after") || { log "FAILED comparing settings: $file"; return 1; }
    while IFS= read -r record; do
        [[ -z "$record" ]] || log "$record"
    done <<< "$records"
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
        changes=$(diff -u -L "$file (before)" -L "$file (after)" "$before" "$file") || diff_status=$?
        if [[ "$diff_status" == 1 ]]; then
            log "CHANGED $file (- removed/old, + added/new): $changes"
            audit_setting_changes "$file" "$before" "$file" || status=1
        elif [[ "$diff_status" != 0 ]]; then
            log "FAILED to compare $file"
            status=1
        fi
    elif [[ "$existed" == yes ]]; then
        log "DELETED file: $file"
        audit_setting_changes "$file" "$before" /dev/null || status=1
    fi
    [[ "$status" == 0 ]] || log "FAILED editing $file (exit $status)"
    return "$status"
}

audit_file_mode() {
    if [[ $(uname -s) == FreeBSD ]]; then stat -f '%Lp' "$1"
    else stat -c '%a' -- "$1"; fi
}

audit_chmod() {
    local mode="$1" path="$2" old new
    old=$(audit_file_mode "$path") || { log "FAILED reading permissions: $path"; return 1; }
    # Directory mode changes are logged; do not recursively copy their contents.
    if [[ -f "$path" && "$old" != "$mode" ]]; then
        backup_system_paths "$path" || return 1
    fi
    if chmod "$mode" -- "$path"; then
        new=$(audit_file_mode "$path") || { log "FAILED verifying permissions: $path"; return 1; }
        [[ "$old" == "$new" ]] || log "CHANGED permissions: $path: $old -> $new"
    else
        log "FAILED chmod $mode: $path (was $old)"
        return 1
    fi
}
