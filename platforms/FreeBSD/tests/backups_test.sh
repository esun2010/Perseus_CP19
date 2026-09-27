#!/usr/bin/env bash
# Fixture-only checks; never edits host policy, accounts, packages or services.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/cyberpatriot-backup-tests.XXXXXX")
trap 'rm -rf "$TEMP"' EXIT
export CP_BACKUP_ROOT="$TEMP/backups"
source "$ROOT/service_helpers/service_common.sh"
LOG_FILE="$TEMP/audit.log"
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
mode() {
    if [[ $(uname -s) == FreeBSD ]]; then command stat -f '%Lp' "$1"
    else command stat -c '%a' "$1"; fi
}
# Exercise the FreeBSD helper on Linux without changing its production stat calls.
if [[ $(uname -s) != FreeBSD ]] && grep -q "stat -f '%Lp'" "$ROOT/../../logging.sh"; then
    stat() {
        if [[ "$1" == -f ]]; then
            case "$2" in
                %Lp) shift 2; command stat -c '%a' "$@" ;;
                %Su) shift 2; command stat -c '%U' "$@" ;;
                *) return 1 ;;
            esac
        else command stat "$@"; fi
    }
fi

file="$TEMP/policy with spaces"
printf 'original\n' > "$file"
chmod 640 "$file"
touch -t 202001020304 "$file"
cp -p "$file" "$TEMP/reference"
edit_file() {
    [[ -f "$SYSTEM_BACKUP_DIR/COMPLETE" ]] || return 91
    cmp "$SYSTEM_BACKUP_DIR/files$file" "$file" || return 92
    printf '%s\n' "$1" > "$file"
}
audit_file_change "$file" edit_file first >/dev/null
first=$SYSTEM_BACKUP_DIR
cmp "$first/files$file" "$TEMP/reference"
[[ $(mode "$first/files$file") == 640 ]] || fail 'original mode lost'
[[ "$first/files$file" -ot "$file" ]] || fail 'original timestamp lost'
[[ -O "$first/files$file" ]] || fail 'ownership lost'
[[ $(mode "$CP_BACKUP_ROOT") == 700 && $(mode "$first") == 700 ]] || fail 'backup not private'
audit_file_change "$file" edit_file second >/dev/null
second=$SYSTEM_BACKUP_DIR
[[ "$first" != "$second" && $(cat "$second/files$file") == first ]] || fail 'rerun reused old backup'
cmp "$first/files$file" "$TEMP/reference"
pass 'backup precedes edits, retains metadata, remains private, and survives reruns'

partial_failure() { printf 'partial\n' > "$file"; return 7; }
status=0
audit_file_change "$file" partial_failure >/dev/null || status=$?
[[ "$status" == 7 && $(cat "$SYSTEM_BACKUP_DIR/files$file") == second ]] || fail 'failed edit lost backup or exit status'
grep -q 'FAILED editing' "$LOG_FILE"
pass 'partial edit failures keep their pre-change copy and error status'

backup_config "$file" >/dev/null
saved=$CONFIG_BACKUP
printf 'broken\n' > "$file"
restore_config "$file" "$saved" >/dev/null
[[ $(cat "$file") == partial && $(cat "$SYSTEM_BACKUP_DIR/files$file") == broken ]] || fail 'restore or backup before restore'
pass 'service rollback restores the saved content and backs up the replaced version'

new_file="$TEMP/new-policy"
create_file() { printf 'new\n' > "$new_file"; }
audit_file_change "$new_file" create_file >/dev/null
grep -q '^ABSENT ' "$SYSTEM_BACKUP_DIR/manifest.txt"
[[ ! -e "$SYSTEM_BACKUP_DIR/files$new_file" ]] || fail 'fabricated original for absent file'
audit_file_change "$new_file" rm "$new_file" >/dev/null
[[ $(cat "$SYSTEM_BACKUP_DIR/files$new_file") == new && ! -e "$new_file" ]] || fail 'deletion not backed up'
pass 'creation records absence and deletion retains the original'

(
    cp() { return 1; }
    if audit_file_change "$file" edit_file forbidden >/dev/null; then exit 1; fi
    [[ $(cat "$file") == partial && -z "$SYSTEM_BACKUP_DIR" ]]
    if audit_chmod 400 "$file" >/dev/null; then exit 1; fi
    [[ $(mode "$file") == 640 ]]
    if backup_config "$file" >/dev/null; then exit 1; fi
    [[ -z "$CONFIG_BACKUP" ]]
) || fail 'failed copy allowed mutation or exposed stale backup pointer'
(
    mktemp() { return 1; }
    if audit_file_change "$file" edit_file forbidden >/dev/null; then exit 1; fi
    [[ $(cat "$file") == partial ]]
) || fail 'failed backup creation allowed mutation'
pass 'copy and allocation failures block content and permission changes'

audit_chmod 400 "$file" >/dev/null
[[ $(mode "$file") == 400 && $(mode "$SYSTEM_BACKUP_DIR/files$file") == 640 ]] || fail 'permission backup'
before=$SYSTEM_BACKUP_DIR
audit_chmod 400 "$file" >/dev/null
[[ "$SYSTEM_BACKUP_DIR" == "$before" ]] || fail 'unchanged mode created backup'
chmod 640 "$file"
(
    # Trigger the ownership-change branch without requiring root/chown privileges.
    stat() { printf 'someone-else\n'; }
    cp() { return 1; }
    chown() { touch "$TEMP/chown-called"; }
    if secure_path "$file" 600 root >/dev/null; then exit 1; fi
    [[ ! -e "$TEMP/chown-called" ]]
) || fail 'ownership changed after backup failure'
pass 'permission backups preserve old modes; failed ownership backup blocks chown'

mkdir -p "$TEMP/tree/nested"
printf 'key material\n' > "$TEMP/tree/nested/key"
ln -s nested/key "$TEMP/tree/key-link"
backup_system_paths "$TEMP/tree" >/dev/null
cmp "$TEMP/tree/nested/key" "$SYSTEM_BACKUP_DIR/files$TEMP/tree/nested/key"
[[ -L "$SYSTEM_BACKUP_DIR/files$TEMP/tree/key-link" ]] || fail 'tree symlink not preserved'
ln -s "$file" "$TEMP/linked-policy"
if audit_file_change "$TEMP/linked-policy" edit_file forbidden >/dev/null; then fail 'linked edit accepted'; fi
ln -s "$CP_BACKUP_ROOT" "$TEMP/linked-backups"
if CP_BACKUP_ROOT="$TEMP/linked-backups" audit_file_change "$file" edit_file forbidden >/dev/null; then fail 'linked backup directory accepted'; fi
if CP_BACKUP_ROOT="$TEMP/missing/../backups" audit_file_change "$file" edit_file forbidden >/dev/null; then fail 'parent traversal accepted'; fi
mkfifo "$TEMP/fifo"
if backup_system_paths "$TEMP/fifo" >/dev/null; then fail 'special file accepted'; fi
[[ $(cat "$file") == partial ]] || fail 'rejected source was edited'
pass 'directory snapshots keep links; unsafe paths and special files block edits'

(
    backup_package_configuration() { return 1; }
    apt-get() { touch "$TEMP/package-mutation"; }
    pkg() {
        case "$1" in
            -N) return 0 ;;
            info) return 1 ;;
            *) touch "$TEMP/package-mutation" ;;
        esac
    }
    if install_packages example >/dev/null; then exit 1; fi
    [[ ! -e "$TEMP/package-mutation" ]]
) || fail 'package operation ran after configuration backup failure'
pass 'package operations stop before hooks can run when configuration backup fails'

if declare -F set_rc_value >/dev/null; then
    rc="$TEMP/rc.conf"
    rc_local="$TEMP/custom-rc.conf"
    printf 'sshd_enable=NO\n' > "$rc"
    printf 'local setting\n' > "$rc_local"
    sysrc() {
        if [[ "$1" == -l ]]; then printf '%s %s\n' "$rc" "$rc_local"; return; fi
        [[ -f "$SYSTEM_BACKUP_DIR/COMPLETE" ]] || return 1
        cmp "$rc" "$SYSTEM_BACKUP_DIR/files$rc" || return 1
        cmp "$rc_local" "$SYSTEM_BACKUP_DIR/files$rc_local" || return 1
        printf '%s\n' "$1" > "$rc"
    }
    set_rc_value sshd_enable=YES >/dev/null
    [[ $(cat "$SYSTEM_BACKUP_DIR/files$rc") == sshd_enable=NO ]] || fail 'startup preimage'
    (
        cp() { return 1; }
        if set_rc_value sshd_enable=NO >/dev/null; then exit 1; fi
        [[ $(cat "$rc") == sshd_enable=YES ]]
    ) || fail 'startup setting changed after backup failure'
    pass 'FreeBSD startup edits back up every sysrc-selected file before mutation'
fi

printf '\n%d backup regression groups passed. No host configuration was changed.\n' "$passed"
