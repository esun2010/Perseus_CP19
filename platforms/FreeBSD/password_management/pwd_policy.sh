#!/usr/bin/env bash
# Native FreeBSD passwd PAM policy and default login-class password aging.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../service_helpers/platform.sh"
require_freebsd_root
source "$SCRIPT_DIR/../../../main/logging.sh"
source "$SCRIPT_DIR/../service_helpers/permissions.sh"
init_logging
require_commands cap_mkdb awk install
[[ -d /etc/pam.d && ! -L /etc/pam.d && -f /etc/pam.d/system && ! -L /etc/pam.d/system ]] || {
    log 'FAILED: FreeBSD PAM service directory or system policy is missing'; exit 1;
}
for file in /etc/pam.d/passwd /etc/login.conf; do
    [[ -f "$file" && ! -L "$file" ]] || { log "FAILED: unexpected configuration layout: $file"; exit 1; }
done
[[ ! -L /etc/login.conf.db && ! -L /etc/pam.d ]] || { log 'FAILED: unexpected authentication configuration symlink'; exit 1; }
[[ -r /usr/lib/pam_passwdqc.so && -r /usr/lib/pam_unix.so ]] || {
    log 'FAILED: FreeBSD base PAM modules are missing'; exit 1;
}
mkdir -p /var/backups
backup=$(mktemp -d /var/backups/cyberpatriot-password-policy.XXXXXX)
cp -p /etc/pam.d/passwd "$backup/passwd.pam"
cp -p /etc/login.conf "$backup/login.conf"
had_database=0
if [[ -e /etc/login.conf.db ]]; then
    cp -p /etc/login.conf.db "$backup/login.conf.db"
    had_database=1
fi
log "Password/PAM policy backup: $backup"

# Validate and compile both candidates before touching active authentication.
if ! awk -f "$SCRIPT_DIR/passwd_policy.awk" /etc/pam.d/passwd > "$backup/new-passwd.pam"; then
    log 'FAILED: custom passwd PAM stack needs review; only one local pam_unix password module is supported'
    exit 1
fi
if ! awk -f "$SCRIPT_DIR/login_defaults.awk" /etc/login.conf > "$backup/new-login.conf"; then
    log 'FAILED: login.conf must have exactly one well-formed default class; active policies unchanged'
    exit 1
fi
cap_mkdb "$backup/new-login.conf"
[[ -s "$backup/new-login.conf.db" ]] || { log 'FAILED: login-class database was not generated'; exit 1; }

install_policy() {
    local source_file="$1" target="$2" temporary
    backup_system_paths "$target" || return 1
    temporary=$(mktemp "${target}.XXXXXX") || return 1
    if install -o root -g wheel -m 644 "$source_file" "$temporary" && mv -f "$temporary" "$target"; then
        return 0
    fi
    rm -f "$temporary"
    return 1
}
policy_changed=0
rollback_policy() {
    local status=$?
    trap - EXIT
    if ((status != 0 && policy_changed)); then
        log "FAILED applying password policy; restoring from $backup"
        install_policy "$backup/passwd.pam" /etc/pam.d/passwd || log 'CRITICAL: restore the passwd PAM file manually'
        install_policy "$backup/login.conf" /etc/login.conf || log 'CRITICAL: restore login.conf manually'
        for service_file in login sshd sudo su passwd other; do
            if [[ -f "$service_backup/$service_file" ]]; then
                install_policy "$service_backup/$service_file" "/etc/pam.d/$service_file" || log "CRITICAL: restore /etc/pam.d/$service_file manually"
            elif [[ -f "$service_backup/$service_file.absent" ]]; then
                backup_system_paths "/etc/pam.d/$service_file" && rm -f "/etc/pam.d/$service_file" || log "CRITICAL: remove generated /etc/pam.d/$service_file manually"
            fi
        done
        if ((had_database)); then
            install_policy "$backup/login.conf.db" /etc/login.conf.db || log 'CRITICAL: restore login.conf.db manually'
        else
            backup_system_paths /etc/login.conf.db && rm -f /etc/login.conf.db || log 'CRITICAL: remove the generated login.conf.db manually'
        fi
    fi
    log "END exit=$status"
    exit "$status"
}
trap rollback_policy EXIT
policy_changed=1
service_backup="$backup/service-files"
mkdir -m 700 "$service_backup"
# FreeBSD OpenPAM uses the shared `system` stack instead of Debian's
# common-auth/account/session stacks. Preserve service-specific rules and add
# a shared-stack include for any stack that does not already include it.
configure_pam_service() {
    local service="$1" file="/etc/pam.d/$1" temporary prefix group
    [[ ! -L "$file" && ( ! -e "$file" || -f "$file" ) ]] || {
        log "FAILED: expected regular PAM service file: $file"; return 1;
    }
    if [[ -f "$file" ]]; then cp -p "$file" "$service_backup/$service" || return 1
    else : > "$service_backup/$service.absent"; fi
    backup_system_paths "$file" || return 1
    temporary=$(mktemp "${file}.XXXXXX") || return 1
    prefix=$(mktemp "${file}.prefix.XXXXXX") || { rm -f "$temporary"; return 1; }
    if [[ -f "$file" ]]; then cp -p "$file" "$temporary" || { rm -f "$temporary"; return 1; }
    else chmod 644 "$temporary" || { rm -f "$temporary"; return 1; }; fi
    for group in auth account session; do
        if ! grep -Eq "^[[:space:]]*$group[[:space:]]+include[[:space:]]+system([[:space:]]|$)" "$temporary"; then
            printf '%s include system\n' "$group" >> "$prefix" || { rm -f "$temporary" "$prefix"; return 1; }
        fi
    done
    if [[ "$service" != passwd ]] && ! grep -Eq '^[[:space:]]*password[[:space:]]+include[[:space:]]+passwd([[:space:]]|$)' "$temporary"; then
        printf 'password include passwd\n' >> "$prefix" || { rm -f "$temporary" "$prefix"; return 1; }
    fi
    cat "$temporary" >> "$prefix" || { rm -f "$temporary" "$prefix"; return 1; }
    install -o root -g wheel -m 644 "$prefix" "$file" || { rm -f "$temporary" "$prefix"; return 1; }
    rm -f "$temporary" "$prefix"
}
for service_file in login sshd sudo su passwd other; do
    audit_file_change "/etc/pam.d/$service_file" configure_pam_service "$service_file" || exit 1
done

audit_file_change /etc/pam.d/passwd install_policy "$backup/new-passwd.pam" /etc/pam.d/passwd
audit_file_change /etc/login.conf install_policy "$backup/new-login.conf" /etc/login.conf
install_policy "$backup/new-login.conf.db" /etc/login.conf.db
log 'Rebuilt /etc/login.conf.db using cap_mkdb'
secure_auth_permissions
secure_path /etc/login.conf 644
secure_path /etc/login.conf.db 644
policy_changed=0
log 'passwd now enforces 12-character minimum and strength checks for all users, including root'
log 'All login classes: 90-day password lifetime and 7-day warning; applies to existing and new accounts'
log 'Existing password hashes and other PAM service-specific rules are retained'
log 'FreeBSD has no direct login.conf equivalent for PASS_MIN_DAYS; no ineffective option was written'
