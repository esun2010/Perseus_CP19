#!/usr/bin/env bash
# First pass records paths and identities; second pass acts only on that inventory.
SECOND_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SECOND_ROOT/service_helpers/second_pass_accounts.sh"

media_signature() {
    if [[ "$ACCOUNT_PLATFORM" == linux ]]; then stat -c '%d:%i:%s:%Y:%Z' -- "$1"
    else stat -f '%d:%i:%z:%m:%c' "$1"; fi
}

media_review() {
    local report="$SECOND_ROOT/log/media_files(2).txt" inventory path signature
    prepare_review_logs "$report" || return 1
    inventory=$(mktemp) || return 1
    local target=${MEDIA_ROOT:-/}
    target=$(realpath "$target") || return 1
    [[ -d "$target" ]] || return 1
    # Include local /home partitions, but exclude remote/pseudo filesystems,
    # backups and conventional external mount directories.
    local -a excluded_fs
    if [[ "$ACCOUNT_PLATFORM" == freebsd ]]; then excluded_fs=('!' -fstype local -o -fstype rdonly -o -fstype devfs -o -fstype procfs -o -fstype linprocfs -o -fstype linsysfs -o -fstype fdescfs)
    else excluded_fs=(-fstype nfs -o -fstype nfs4 -o -fstype cifs -o -fstype fuse.sshfs); fi
    if ! find -P "$target" \
        \( "${excluded_fs[@]}" -o -path /media -o -path /mnt -o -path /proc -o -path /sys -o -path /dev -o -path /run \
           -o -path /var/backups -o -path "${CP_BACKUP_ROOT:-/var/backups/cyberpatriot}" -o -path /var/db/cyberpatriot -o -name .zfs \) -prune -o \
        -type f \( -iname '*.mp3' -o -iname '*.mov' -o -iname '*.mp4' \) -print0 > "$inventory"; then
        rm -f "$inventory"; log 'FAILED media inventory; previous review log retained'; return 1
    fi
    local temp
    temp=$(mktemp "$report.XXXXXX") || return 1
    printf '# First-pass media inventory for run_all_2.sh. NO FILES DELETED.\n# Format: device:inode:size:mtime:ctime<TAB>absolute path\n# Remove entire lines for required files before running the second pass.\n' > "$temp"
    while IFS= read -r -d '' path; do
        # A plain editable line format cannot safely represent embedded newlines.
        if [[ "$path" == *$'\n'* || "$path" == *$'\r'* ]]; then
            printf '# MANUAL REVIEW unusual filename: %q\n' "$path" >> "$temp"; continue
        fi
        signature=$(media_signature "$path") || { rm -f "$inventory" "$temp"; return 1; }
        printf '%s\t%s\n' "$signature" "$path" >> "$temp"
    done < "$inventory"
    chmod 600 "$temp" && mv "$temp" "$report" || return 1
    rm -f "$inventory"
    log "AUDIT ONLY: media inventory written to $report; no media deleted"
}

media_cleanup() {
    local report="$SECOND_ROOT/log/media_files(2).txt" line signature path current resolved status=0
    [[ -f "$report" && ! -L "$report" ]] || { log 'FAILED: run the first-pass media inventory first'; return 1; }
    local -a paths=() signatures=()
    # Validate the entire review file before deleting any media.
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" && "$line" != \#* ]] || continue
        [[ "$line" == *$'\t'* ]] || return 1
        signature=${line%%$'\t'*}; path=${line#*$'\t'}
        [[ "$signature" =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+:[0-9]+$ && "$path" == /* && "$path" != *$'\r'* ]] || return 1
        case "$path" in /proc/*|/sys/*|/dev/*|/run/*|/var/backups/*|/var/db/cyberpatriot/*) log "FAILED protected media path: $path"; return 1;; esac
        [[ "$path" != "${CP_BACKUP_ROOT:-/var/backups/cyberpatriot}/"* ]] || { log 'FAILED media is inside the backup directory'; return 1; }
        case "${path,,}" in *.mp3|*.mov|*.mp4) ;; *) return 1;; esac
        if [[ ! -e "$path" && ! -L "$path" ]]; then log "ALREADY ABSENT: $path"; continue; fi
        resolved=$(realpath "$path") || return 1
        [[ "$resolved" == "$path" && ! -L "$path" && -f "$path" ]] || { log "FAILED changed/linked path: $path"; return 1; }
        current=$(media_signature "$path") || return 1
        [[ "$current" == "$signature" ]] || { log "FAILED media changed since inventory: $path; rerun the first pass"; return 1; }
        paths+=("$path"); signatures+=("$signature")
    done < "$report"
    local i
    for ((i=0; i<${#paths[@]}; i++)); do
        path=${paths[i]}
        # Recheck immediately before the backup/removal as well.
        [[ ! -L "$path" && "$(realpath "$path")" == "$path" && "$(media_signature "$path")" == "${signatures[i]}" ]] || return 1
        backup_system_paths "$path" || return 1
        if rm -- "$path"; then log "DELETED reviewed media: $path; backup=$SYSTEM_BACKUP_DIR"
        else log "FAILED deleting media: $path"; status=1; fi
    done
    return "$status"
}
