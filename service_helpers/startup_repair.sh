#!/usr/bin/env bash
# Native implementations live under platforms; policy and callers stay shared.
if [[ $(uname -s) == FreeBSD ]]; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/platforms/FreeBSD/service_helpers/startup_repair.sh"
    return $?
fi
# Sourced by the launcher only after root checks and logging initialization.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/distribution.sh"
repair_immutable_files() {
    local root path flags listing
    command -v lsattr >/dev/null && command -v chattr >/dev/null || {
        log 'FAILED: lsattr/chattr required for initial immutable-file repair'; return 1;
    }
    for root in /etc /usr/local/etc /usr/share/pam-configs \
                /var/lib/dpkg /var/lib/apt /var/cache/apt /var/lib/pam; do
        [[ -d "$root" && ! -L "$root" ]] || continue
        listing=$(mktemp) || return 1
        find -P "$root" -xdev \( -type f -o -type d \) -print0 > "$listing" || { rm -f "$listing"; return 1; }
        while IFS= read -r -d '' path; do
            # Some filesystems do not implement Linux inode flags.
            flags=$(lsattr -d -- "$path" 2>/dev/null) || continue
            flags=${flags%% *}
            [[ "$flags" == *i* || "$flags" == *a* ]] || continue
            backup_system_paths "$path" || { rm -f "$listing"; return 1; }
            printf '%s %q\n' "$flags" "$path" >> "$SYSTEM_BACKUP_DIR/inode-flags.txt" || return 1
            chattr -ia -- "$path" || { rm -f "$listing"; return 1; }
            log "CLEARED blocking immutable/append-only flags: $path (was $flags)"
        done < "$listing"
        rm -f "$listing"
    done
}

repair_persistent_path() {
    local file=/etc/environment temp
    [[ ! -L "$file" ]] || { log 'FAILED: /etc/environment is a symlink'; return 1; }
    backup_system_paths "$file" || return 1
    temp=$(mktemp) || return 1
    if [[ -f "$file" ]]; then
        awk '!/^[[:space:]]*(export[[:space:]]+)?PATH[[:space:]]*=/' "$file" > "$temp" || return 1
    fi
    printf 'PATH="%s"\n' "$PATH" >> "$temp" || return 1
    cat "$temp" > "$file" || return 1
    chmod 644 "$file" || return 1
    rm -f "$temp"
    log 'REPAIRED launcher PATH and default login PATH in /etc/environment'
}

repair_apt_repositories() {
    local output work file saved timestamp
    load_distribution || return 1
    [[ "$CP_DISTRO" != freebsd ]] || { log "FAILED: use native FreeBSD startup repair"; return 1; }
    local -a originals=() disabled=()
    command -v apt-get >/dev/null || { log 'FAILED: APT is unavailable'; return 1; }
    output=$(mktemp) || return 1
    if LC_ALL=C apt-get -o APT::Update::Error-Mode=any update > "$output" 2>&1; then
        local targets
        targets=$(apt-get indextargets --format '$(IDENTIFIER)') || { rm -f "$output"; return 1; }
        if [[ -n "$targets" ]]; then rm -f "$output"; log 'VERIFIED existing APT repositories'; return 0; fi
        printf 'No active package sources configured\n' > "$output"
    fi
    # A connection/lock/disk failure is not evidence that sources need replacing.
    if ! grep -Eq 'No active package sources|Malformed|Conflicting values|does not have a Release file|no longer has a Release file|NO_PUBKEY|EXPKEYSIG|BADSIG|is not signed|Type .* is not known' "$output"; then
        cat "$output" >&2; rm -f "$output"
        log 'FAILED APT update: resolve network, clock, lock or storage error; sources preserved'; return 1
    fi
    rm -f "$output"
    work=$(mktemp -d) || return 1
    chmod 755 "$work" || return 1
    mkdir -p "$work/lists/partial" "$work/empty" || return 1
    write_distribution_sources > "$work/repaired.sources" || {
        rm -rf "$work"; log 'FAILED generating trusted distribution sources'; return 1;
    }
    # Validate signature-checked replacement sources before touching live sources.
    if ! apt-get -o APT::Update::Error-Mode=any \
        -o "Dir::Etc::sourcelist=$work/repaired.sources" \
        -o "Dir::Etc::sourceparts=$work/empty" \
        -o "Dir::State::lists=$work/lists" update; then
        rm -rf "$work"; log 'FAILED validating official sources; existing sources preserved (EOL releases need manual recovery)'; return 1
    fi
    [[ ! -L /etc/apt/sources.list.d ]] || return 1
    backup_system_paths /etc/apt || return 1
    saved="$SYSTEM_BACKUP_DIR/files/etc/apt"
    timestamp=$(date +%s)-$$
    for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [[ -e "$file" ]] || continue
        [[ -f "$file" && ! -L "$file" ]] || { log "FAILED: unsafe APT source path $file"; return 1; }
        originals+=("$file"); disabled+=("$file.disabled-cp-$timestamp")
    done
    local i status=0
    for ((i=0; i<${#originals[@]}; i++)); do
        mv -- "${originals[i]}" "${disabled[i]}" || { status=1; break; }
    done
    if ((status == 0)); then
        mkdir -p /etc/apt/sources.list.d &&
            cp "$work/repaired.sources" /etc/apt/sources.list.d/cyberpatriot-repaired.sources || status=1
    fi
    rm -rf "$work"
    if ((status == 0)); then apt-get -o APT::Update::Error-Mode=any update || status=1; fi
    if ((status)); then
        # Only remove the generated path if an original there was moved or absent.
        if [[ -e "/etc/apt/sources.list.d/cyberpatriot-repaired.sources.disabled-cp-$timestamp" || ! -e "$saved/sources.list.d/cyberpatriot-repaired.sources" ]]; then
            rm -f /etc/apt/sources.list.d/cyberpatriot-repaired.sources || return 1
        fi
        for ((i=0; i<${#originals[@]}; i++)); do
            [[ ! -e "${disabled[i]}" ]] || mv -- "${disabled[i]}" "${originals[i]}" || return 1
        done
        log 'FAILED APT source installation/verification; original sources restored'; return 1
    fi
    log "REPAIRED APT with signed official $CP_DISTRO sources; previous sources retained as .disabled-cp-$timestamp and in $saved. Review third-party sources before restoring."
}

startup_repair() {
    load_distribution || return 1
    [[ "$CP_DISTRO" != freebsd ]] || { log "FAILED: use native FreeBSD startup repair"; return 1; }
    repair_immutable_files || return 1
    repair_persistent_path || return 1
    repair_apt_repositories || return 1
}
