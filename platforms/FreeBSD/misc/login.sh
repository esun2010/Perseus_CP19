#!/usr/bin/env bash
# Disable the local guest account and optional LightDM guest sessions.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../service_helpers/platform.sh"
require_freebsd_root
source "$SCRIPT_DIR/../../../main/logging.sh"
init_logging
require_commands pw awk

if pw usershow -n guest >/dev/null 2>&1; then
    if ! awk -F: '$1 == "guest" && index($2, "*LOCKED*") == 1 { locked=1 } END { exit !locked }' /etc/master.passwd; then
        backup_account_databases
        pw lock guest
    fi
    backup_account_databases
    pw usermod -n guest -s /usr/sbin/nologin
    log 'Disabled local guest account using pw lock and the nologin shell; files retained'
else
    log 'No local guest account exists'
fi

LIGHTDM_DIR=/usr/local/etc/lightdm/lightdm.conf.d
LIGHTDM_CONF="$LIGHTDM_DIR/99-cyberpatriot-guest.conf"
if package_installed lightdm; then
    [[ ! -L /usr/local/etc/lightdm && ! -L "$LIGHTDM_DIR" && ! -L "$LIGHTDM_CONF" ]] || {
        log 'FAILED: unexpected symbolic link in LightDM configuration'; exit 1;
    }
    install -d -o root -g wheel -m 755 "$LIGHTDM_DIR"
    mkdir -p /var/backups
    backup=$(mktemp -d /var/backups/cyberpatriot-lightdm.XXXXXX)
    # The main file and seat-specific groups can override a wildcard fragment.
    # Validate and save every local file before rewriting existing guest grants.
    lightdm_files=(/usr/local/etc/lightdm/lightdm.conf "$LIGHTDM_DIR"/*.conf)
    for file in "${lightdm_files[@]}"; do
        [[ -e "$file" || -L "$file" ]] || continue
        [[ -f "$file" && ! -L "$file" ]] || {
            log "FAILED: unexpected LightDM configuration type: $file"; exit 1;
        }
        if [[ "$file" == /usr/local/etc/lightdm/lightdm.conf ]]; then
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
        ' "$file" > "$temporary" && chown root:wheel "$temporary" &&
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
            chown root:wheel "$temporary" && chmod 644 "$temporary" &&
            mv -f "$temporary" "$LIGHTDM_CONF" && return 0
        rm -f "$temporary"
        return 1
    }
    audit_file_change "$LIGHTDM_CONF" write_lightdm_guest_policy
    log 'Disabled LightDM guest sessions; saved configuration; active desktop retained'
    log 'Disabled existing local seat-specific guest overrides; review any named-user autologin separately'
else
    log 'LightDM is not installed; graphical-login configuration skipped'
fi
log 'Guest-login hardening complete'
