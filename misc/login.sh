#!/bin/bash
# Use the native implementation when invoked directly on FreeBSD.
if [[ "${BASH_SOURCE[0]}" == "$0" && $(uname -s) == FreeBSD ]]; then
    exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/platforms/FreeBSD/misc/login.sh" "$@"
fi
# Lock the optional guest account and configure the selected display manager.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../logging.sh"
[[ $(id -u) == 0 ]] || { echo 'Run as root.' >&2; exit 1; }
source "$SCRIPT_DIR/../service_helpers/distribution.sh"
source "$SCRIPT_DIR/../service_helpers/login_manager.sh"
load_distribution || exit 1
[[ "$CP_DISTRO" != freebsd ]] || { echo "Use platforms/FreeBSD/misc/login.sh on FreeBSD." >&2; exit 1; }
init_logging
if id guest >/dev/null 2>&1; then
    backup_account_databases
    usermod -L guest
    backup_account_databases
    usermod -s /usr/sbin/nologin guest
    log 'Locked local guest account and disabled its login shell; files retained'
fi
# Debian-family display-manager selection is authoritative when available.
manager=
if [[ -s /etc/X11/default-display-manager ]]; then
    IFS= read -r manager < /etc/X11/default-display-manager
    manager=${manager##*/}
else
    # Headless hosts skip configuration. Do not choose arbitrarily among managers.
    installed=()
    for candidate in lightdm gdm3 sddm; do
        status=$(dpkg-query -W -f='${db:Status-Status}' "$candidate" 2>/dev/null) || status=absent
        [[ "$status" != installed ]] || installed+=("$candidate")
    done
    if ((${#installed[@]} > 1)); then
        log 'FAILED: multiple display managers installed without a default selection'; exit 1
    fi
    manager=${installed[0]:-}
fi
LIGHTDM_DIR=/etc/lightdm/lightdm.conf.d
LIGHTDM_CONF="$LIGHTDM_DIR/99-cyberpatriot-guest.conf"
if [[ "$manager" == lightdm ]]; then
    [[ ! -L /etc/lightdm && ! -L "$LIGHTDM_DIR" && ! -L "$LIGHTDM_CONF" ]] || {
        log 'FAILED: unexpected symbolic link in LightDM configuration'; exit 1;
    }
    install -d -o root -g root -m 755 "$LIGHTDM_DIR"
    mkdir -p /var/backups
    backup=$(mktemp -d /var/backups/cyberpatriot-lightdm.XXXXXX)
    # The main file and seat-specific groups can override a wildcard fragment.
    # Validate and save every local file before rewriting existing guest grants.
    lightdm_files=(/etc/lightdm/lightdm.conf "$LIGHTDM_DIR"/*.conf)
    for file in "${lightdm_files[@]}"; do
        [[ -e "$file" || -L "$file" ]] || continue
        [[ -f "$file" && ! -L "$file" ]] || {
            log "FAILED: unexpected LightDM configuration type: $file"; exit 1;
        }
        if [[ "$file" == /etc/lightdm/lightdm.conf ]]; then
            cp -p "$file" "$backup/main-lightdm.conf"
        else
            cp -p "$file" "$backup/fragment-${file##*/}"
        fi
    done
    log "LightDM configuration backups: $backup"
    disable_existing_guest_grants() {
        local file="$1" temporary
        temporary=$(mktemp "${file}.XXXXXX") || return 1
        if awk '
            /^[[:space:]]*(allow-guest|autologin-guest)[[:space:]]*=/ {
                sub(/=.*/, "=false")
            }
            { print }
        ' "$file" > "$temporary" && chown root:root "$temporary" &&
            chmod 644 "$temporary" && mv -f "$temporary" "$file"; then return 0; fi
        rm -f "$temporary"
        return 1
    }
    for file in "${lightdm_files[@]}"; do
        [[ -f "$file" ]] || continue
        audit_file_change "$file" disable_existing_guest_grants "$file"
    done
    write_lightdm_guest_policy() {
        local temporary
        temporary=$(mktemp "$LIGHTDM_DIR/.guest.XXXXXX") || return 1
        printf '[Seat:*]\nallow-guest=false\nautologin-guest=false\n' > "$temporary" &&
            chown root:root "$temporary" && chmod 644 "$temporary" &&
            mv -f "$temporary" "$LIGHTDM_CONF" && return 0
        rm -f "$temporary"
        return 1
    }
    audit_file_change "$LIGHTDM_CONF" write_lightdm_guest_policy
    log 'Disabled LightDM guest sessions; saved configuration; active desktop retained'
    log 'Disabled existing local seat-specific guest overrides; review any named-user autologin separately'
elif [[ -n "$manager" ]]; then
    configure_other_login_manager "$manager"
else
    log 'No supported display manager installed; graphical-login configuration skipped'
fi
log 'Guest-login hardening complete'
