#!/usr/bin/env bash
# Optional native smoke test. Writes only under a fresh temporary directory.
set -euo pipefail
[[ $(uname -s) == FreeBSD ]] || {
    echo 'SKIP: this smoke test requires native FreeBSD.'
    exit 0
}
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/cyberpatriot-native.XXXXXX")
trap 'rm -rf "$TEMP"' EXIT
source "$ROOT/service_helpers/platform.sh"
source "$ROOT/../../logging.sh"
source "$ROOT/service_helpers/permissions.sh"
LOG_FILE="$TEMP/audit.log"
export CP_BACKUP_ROOT="$TEMP/backups"
require_commands stat find awk cap_mkdb sysrc service pw sockstat pfctl
printf 'example\n' > "$TEMP/example"
chmod 666 "$TEMP/example"
[[ $(stat -f '%Lp' "$TEMP/example") == 666 ]]
secure_path "$TEMP/example" 640 "$(id -un)"
[[ $(stat -f '%Lp' "$TEMP/example") == 640 ]]
ln -s "$TEMP/example" "$TEMP/link"
secure_path "$TEMP/link" 400 "$(id -un)"
[[ $(stat -f '%Lp' "$TEMP/example") == 640 ]]
find -P "$TEMP" \( ! -fstype local -o -fstype rdonly \) -prune -o -type f -print0 > "$TEMP/files"
[[ -s "$TEMP/files" ]]
printf 'default:\\
    :passwd_format=sha512:\\
    :passwordtime=90d:\\
    :warnpassword=7d:\\
    :minpasswordlen=12:\\
    :tc=base:\nbase:\\
    :umask=022:\n' > "$TEMP/login.conf"
cap_mkdb "$TEMP/login.conf"
[[ -s "$TEMP/login.conf.db" ]]
sockstat -46l -P tcp > "$TEMP/sockets"
printf 'PASS: native stat, permissions, symlink handling, find, login database, sockstat\n'
printf 'FreeBSD version: %s\n' "$(freebsd-version -u)"
printf 'No system files, accounts, services, or firewall rules were changed.\n'
