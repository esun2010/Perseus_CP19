#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../logging.sh"
source "$SCRIPT_DIR/../service_helpers/permissions.sh"
[[ $EUID == 0 ]] || { echo 'Run this script as root.' >&2; exit 1; }
init_logging
command -v pam-auth-update >/dev/null || { log 'FAILED: this password policy requires Debian/Ubuntu pam-auth-update'; exit 1; }
[[ -d /etc/pam.d && -d /etc/security && -f /etc/login.defs ]] || {
    log 'FAILED: missing PAM/security configuration directories'; exit 1;
}

# Keep a complete snapshot before package hooks or pam-auth-update alter PAM.
backup=$(mktemp -d /var/backups/cyberpatriot-password-policy.XXXXXX)
chmod 700 "$backup"
cp -a /etc/pam.d "$backup/pam.d"
cp -p /etc/login.defs "$backup/login.defs"
if [[ -e /etc/security/pwquality.conf ]]; then
    cp -p /etc/security/pwquality.conf "$backup/pwquality.conf"
fi
log "Password/PAM configuration backup: $backup"
# Preserve custom stacks: never pass --force to pam-auth-update.
if ! dpkg-query -W -f='${Status}' libpam-pwquality 2>/dev/null | grep -qx 'install ok installed'; then
    apt-get update
    backup_package_configuration
    apt-get install -y libpam-pwquality
fi
[[ -f /usr/share/pam-configs/pwquality ]] || { log 'FAILED: packaged pwquality PAM profile is missing'; exit 1; }

set_policy_value() {
    local file="$1" key="$2" value="$3" separator="$4"
    sed -i "/^[[:space:]]*${key}\([[:space:]=]\|$\)/d" "$file" || return 1
    printf '%s%s%s\n' "$key" "$separator" "$value" >> "$file"
}
for setting in PASS_MAX_DAYS:90 PASS_MIN_DAYS:1 PASS_WARN_AGE:7; do
    audit_file_change /etc/login.defs set_policy_value /etc/login.defs "${setting%%:*}" "${setting#*:}" ' '
done
configure_pwquality() {
    touch /etc/security/pwquality.conf || return 1
    local setting
    for setting in minlen:12 dcredit:0 ucredit:0 lcredit:0 ocredit:0 enforcing:1; do
        set_policy_value /etc/security/pwquality.conf "${setting%%:*}" "${setting#*:}" ' = ' || return 1
    done
}
audit_file_change /etc/security/pwquality.conf configure_pwquality
backup_system_paths /etc/pam.d /var/lib/pam
if ! pam-auth-update --enable pwquality; then
    log "FAILED enabling password-quality profile; review PAM and restore from $backup if needed"
    exit 1
fi
# Verify the generated stack actually requires the module, rather than assuming success.
if ! grep -Eq '^[[:space:]]*password[[:space:]]+(requisite|required)[[:space:]]+([^[:space:]]*/)?pam_pwquality\.so([[:space:]]|$)' /etc/pam.d/common-password; then
    log "FAILED: custom common-password did not enable required pam_pwquality; review using backup $backup"
    exit 1
fi
for file in /etc/pam.d/common-*; do
    [[ -f "$file" ]] || continue
    previous="$backup/pam.d/${file##*/}"
    if [[ -f "$previous" ]]; then
        changes=$(diff -u "$previous" "$file") || status=$?
        [[ ${status:-0} -le 1 ]] || exit 1
        [[ -z "$changes" ]] || log "CHANGED PAM stack $file: $changes"
    else
        log "CREATED PAM stack: $file"
    fi
    status=0
done
secure_path /etc/login.defs 644
secure_auth_permissions
log 'Password quality enabled: minimum 12 characters, no length credits; existing account aging unchanged'
log 'PAM module arguments can override pwquality.conf; review custom module options'
log 'Protected existing PAM modules, PAM/security configuration, and authentication logs; absent paths were not created'
