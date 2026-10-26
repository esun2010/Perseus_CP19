#!/usr/bin/env bash
# Consolidated non-daemon component checks and permission hardening.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../service_helpers/system_components.sh"

system_hardening_main() {
    (($# == 0)) || { echo 'This script accepts no arguments.' >&2; return 1; }
    component_init || return 1
    local component failed=0
    for component in nss openssl grub selinux dhclient; do
        log "RUN system component: $component"
        if component_main "$component"; then
            log "PASS system component: $component"
        else
            log "FAILED system component: $component"
            failed=1
        fi
    done
    return "$failed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    system_hardening_main "$@"
fi
