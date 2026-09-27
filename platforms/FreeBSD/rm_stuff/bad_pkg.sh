#!/usr/bin/env bash
# Review and remove explicitly selected FreeBSD packages.
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../service_helpers/platform.sh"
source "$SCRIPT_DIR/../service_helpers/critical_services.sh"
source "$SCRIPT_DIR/../logging.sh"

source "$SCRIPT_DIR/../service_helpers/managed_platform.sh"

protected_package() {
    local family
    if family=$(package_family "$1") && critical_service "$family"; then return 0; fi
    case "$1" in
        pkg|pkg-devel|bash|sudo|sudo-*|doas|nano|FreeBSD-*) return 0 ;;
        openssh* ) critical_service ssh && return 0 ;;
        apache*|mod_* ) critical_service apache2 && return 0 ;;
        vsftpd* ) critical_service vsftpd && return 0 ;;
    esac
    return 1
}

main() {
    require_freebsd_root
    require_commands pkg mktemp
    load_critical_services "$SCRIPT_DIR/../input/critical_services.txt"
    init_logging
    # FreeBSD base nc/telnet are not third-party packages and cannot be deleted here.
    local -a candidates=(nmap netcat john hydra medusa ophcrack hashcat wireshark
        aircrack-ng kismet tor deluge transmission-cli transmission-daemon sqlmap nikto)
    local -a selected=()
    local -A installed=() seen=()
    local listing package line choice editor list_file reverse_dependencies
    listing=$(pkg query -a '%n') || return 1
    while IFS= read -r package; do
        [[ -z "$package" ]] || installed["$package"]=1
    done <<< "$listing"
    printf 'Packages to review against the scenario README:\n'
    printf '  %s\n' "${candidates[@]}"
    read -r -p 'Edit this list before reviewing installed matches? [y/N] ' choice || return 1
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        editor=${EDITOR:-vi}
        require_commands "$editor"
        list_file=$(mktemp -t cyberpatriot-packages)
        printf '%s\n' "${candidates[@]}" > "$list_file"
        if ! "$editor" "$list_file"; then rm -f "$list_file"; return 1; fi
        mapfile -t candidates < "$list_file"
        rm -f "$list_file"
    fi
    for line in "${candidates[@]}"; do
        line=${line//$'\r'/}
        line=${line%%#*}
        package="${line#"${line%%[![:space:]]*}"}"
        package="${package%"${package##*[![:space:]]}"}"
        [[ -n "$package" ]] || continue
        [[ "$package" =~ ^[A-Za-z0-9][A-Za-z0-9_+.-]*$ ]] || {
            printf 'Invalid exact package name: %q\n' "$package" >&2; return 1;
        }
        [[ -z "${seen[$package]:-}" ]] || continue
        seen["$package"]=1
        if [[ -z "${installed[$package]:-}" ]]; then printf 'Not installed: %s\n' "$package"; continue; fi
        if protected_package "$package"; then log "PRESERVED protected package: $package"; continue; fi
        reverse_dependencies=$(pkg query -C '%rn' "$package") || return 1
        if [[ -n "$reverse_dependencies" ]]; then
            log "PRESERVED package required by installed software: $package ($reverse_dependencies)"
            continue
        fi
        selected+=("$package")
    done
    if ((${#selected[@]} == 0)); then log 'No eligible installed packages selected.'; return 0; fi
    printf '\nFinal removal list (exact installed names):\n'
    printf '  %s\n' "${selected[@]}"
    pkg delete -Cn "${selected[@]}" || return 1
    read -r -p 'Remove these packages? Type REMOVE to confirm: ' choice || return 1
    if [[ "$choice" != REMOVE ]]; then log 'Package removal cancelled.'; return 1; fi
    # Do not force, recurse, or autoremove: dependent/required software stays installed.
    for package in "${selected[@]}"; do
        reverse_dependencies=$(pkg query -C '%rn' "$package") || return 1
        [[ -z "$reverse_dependencies" ]] || { log "Dependency appeared; refusing removal: $package"; return 1; }
        log "REMOVING package: $package"
        backup_package_configuration || return 1
        pkg delete -Cy "$package" || return 1
        log "REMOVED package: $package"
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
