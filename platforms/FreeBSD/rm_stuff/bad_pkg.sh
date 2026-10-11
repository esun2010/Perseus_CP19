#!/usr/bin/env bash
# Review and remove explicitly selected FreeBSD packages.
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../service_helpers/platform.sh"
source "$SCRIPT_DIR/../../../main/logging.sh"


main() {
    require_freebsd_root
    require_commands pkg grep
    init_logging
    local -a candidates=(nmap netcat john hydra medusa ophcrack hashcat wireshark aircrack-ng kismet tor deluge transmission-cli transmission-daemon sqlmap nikto)
    local package listing
    listing=$(pkg query -a '%n') || return 1
    for package in "${candidates[@]}"; do
        if grep -Fxq -- "$package" <<< "$listing"; then
            log "REMOVING listed package: $package"
            pkg delete -y "$package" || return 1
        else
            printf 'Not installed: %s\n' "$package"
        fi
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
