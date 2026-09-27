#!/usr/bin/env bash
# FreeBSD has no APT. Preserve native pkg repository definitions.
startup_repair() {
    local root path flags listing
    for root in /etc /usr/local/etc /var/db/pkg; do
        [[ -d "$root" && ! -L "$root" ]] || continue
        listing=$(mktemp) || return 1
        find -P "$root" -xdev \( -type f -o -type d \) -print0 > "$listing" || return 1
        while IFS= read -r -d '' path; do
            flags=$(stat -f '%Sf' "$path") || return 1
            [[ "$flags" == *uchg* || "$flags" == *schg* || "$flags" == *uappnd* || "$flags" == *sappnd* ]] || continue
            backup_system_paths "$path" || return 1
            printf '%s %q\n' "$flags" "$path" >> "$SYSTEM_BACKUP_DIR/inode-flags.txt" || return 1
            chflags nouchg,noschg,nouappnd,nosappnd "$path" || {
                log "FAILED clearing flags on $path; elevated securelevel may require single-user repair"; return 1;
            }
            log "CLEARED blocking flags: $path (was $flags)"
        done < "$listing"
        rm -f "$listing"
    done
    log 'REPAIRED launcher PATH; APT repair is not applicable on FreeBSD'
    # Refresh native metadata without overwriting custom repository definitions.
    pkg update -f || { log 'FAILED native pkg repository refresh; inspect network and pkg repository configuration'; return 1; }
}
