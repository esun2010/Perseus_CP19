#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/config/logging.sh"
[[ $EUID -eq 0 ]] || { echo 'Run this helper as root.' >&2; exit 1; }
init_logging
listing=''
trap 'audit_status=$?; [[ -z "$listing" ]] || rm -f -- "$listing"; log "END exit=$audit_status"' EXIT

if [[ $(uname -s) == FreeBSD ]]; then
    for root in /etc /usr/local/etc /var/db/pkg; do
        [[ -d "$root" && ! -L "$root" ]] || continue
        listing=$(mktemp) || exit 1
        find -P "$root" -xdev \( -type f -o -type d \) -print0 > "$listing" || {
            rm -f -- "$listing"; log "FAILED scanning $root for blocking inode flags"; exit 1;
        }
        while IFS= read -r -d '' path; do
            flags=$(stat -f '%Sf' "$path") || exit 1
            [[ "$flags" == *uchg* || "$flags" == *schg* || "$flags" == *uappnd* || "$flags" == *sappnd* ]] || continue
            backup_system_paths "$path" || exit 1
            printf '%s %q\n' "$flags" "$path" >> "$SYSTEM_BACKUP_DIR/inode-flags.txt" || exit 1
            chflags nouchg,noschg,nouappnd,nosappnd "$path" || {
                log "FAILED clearing flags on $path; elevated securelevel may require single-user repair"; exit 1;
            }
            log "CLEARED blocking flags: $path (was $flags)"
        done < "$listing"
        rm -f -- "$listing"
        listing=''
    done
else
    source "$ROOT_DIR/service_helpers/startup_repair.sh"
    # These account databases must remain replaceable by user/group management
    # and package tools when they carry immutable or append-only flags.
    repair_immutable_files || exit 1
fi
