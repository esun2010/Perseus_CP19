#!/usr/bin/env bash
# Use the native implementation when invoked directly on FreeBSD.
if [[ "${BASH_SOURCE[0]}" == "$0" && $(uname -s) == FreeBSD ]]; then
    exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/platforms/FreeBSD/password_management/pwd_policy.sh" "$@"
fi
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config/logging.sh"
source "$SCRIPT_DIR/../service_helpers/permissions.sh"
[[ $EUID == 0 ]] || { echo 'Run this script as root.' >&2; exit 1; }
init_logging
command -v pam-auth-update >/dev/null || { log 'FAILED: this password policy requires Debian/Ubuntu pam-auth-update'; exit 1; }
for directory in /etc/pam.d /usr/share/pam-configs /var/lib/pam; do
    [[ -d "$directory" && ! -L "$directory" ]] || {
        log "FAILED: expected regular configuration directory: $directory"; exit 1;
    }
done
for file in /etc/pam.d/common-auth /etc/pam.d/common-account /etc/pam.d/common-password; do
    [[ -f "$file" && ! -L "$file" ]] || {
        log "FAILED: missing or redirected PAM stack: $file"; exit 1;
    }
done
[[ ! -L /etc/security && ( ! -e /etc/security || -d /etc/security ) ]] || {
    log 'FAILED: unexpected /etc/security layout'; exit 1;
}
for file in /etc/login.defs /etc/security/pwquality.conf /etc/security/faillock.conf \
            /etc/pam.d/common-* /usr/share/pam-configs/cyberpatriot-faillock-preauth \
            /usr/share/pam-configs/cyberpatriot-faillock-authfail; do
    [[ ! -L "$file" && ( ! -e "$file" || -f "$file" ) ]] || {
        log "FAILED: expected regular configuration file: $file"; exit 1;
    }
done

# Keep a complete snapshot before package hooks or pam-auth-update alter PAM.
backup_system_paths /etc/pam.d /etc/login.defs /etc/security /var/lib/pam \
    /usr/share/pam-configs/cyberpatriot-faillock-preauth \
    /usr/share/pam-configs/cyberpatriot-faillock-authfail
backup=$SYSTEM_BACKUP_DIR
log "Password/PAM configuration backup: $backup"
[[ -d /etc/security ]] || install -d -m 755 /etc/security
# Preserve custom stacks: never pass --force to pam-auth-update.
if ! dpkg-query -W -f='${Status}' libpam-pwquality 2>/dev/null | grep -qx 'install ok installed'; then
    apt-get update
    backup_package_configuration
    apt-get install -y libpam-pwquality
fi
[[ -f /usr/share/pam-configs/pwquality ]] || { log 'FAILED: packaged pwquality PAM profile is missing'; exit 1; }
module_found=0
for file in /lib/security/pam_faillock.so /lib64/security/pam_faillock.so \
            /usr/lib/security/pam_faillock.so /usr/lib64/security/pam_faillock.so \
            /lib/*-linux-gnu/security/pam_faillock.so /usr/lib/*-linux-gnu/security/pam_faillock.so; do
    [[ ! -r "$file" ]] || module_found=1
done
[[ "$module_found" == 1 ]] || {
    log 'FAILED: pam_faillock is missing; install the distribution libpam-modules package'; exit 1;
}

set_policy_value() {
    local file="$1" key="$2" value="$3" separator="$4"
    (umask 022; touch "$file") || return 1
    sed -i "/^[[:space:]]*${key}\([[:space:]=]\|$\)/d" "$file" || return 1
    if [[ -s "$file" && -n "$(tail -c 1 "$file")" ]]; then
        printf '\n' >> "$file" || return 1
    fi
    printf '%s%s%s\n' "$key" "$separator" "$value" >> "$file"
}
configure_login_defaults() {
    local setting encryption=SHA512
    # Retain a supported stronger existing default; never fall back to DES.
    if [[ -f /etc/login.defs ]] && awk '$1 == "ENCRYPT_METHOD" { value=$2 } END { exit(value != "YESCRYPT") }' /etc/login.defs; then
        encryption=YESCRYPT
    fi
    for setting in PASS_MAX_DAYS:90 PASS_MIN_DAYS:1 PASS_WARN_AGE:7 \
        UID_MIN:1000 UID_MAX:60000 SYS_UID_MIN:100 SYS_UID_MAX:999 \
        GID_MIN:1000 GID_MAX:60000 SYS_GID_MIN:100 SYS_GID_MAX:999 \
        UMASK:027 HOME_MODE:0750 LOGIN_RETRIES:5 LOGIN_TIMEOUT:60 \
        "ENCRYPT_METHOD:$encryption"; do
        set_policy_value /etc/login.defs "${setting%%:*}" "${setting#*:}" ' ' || return 1
    done
}
audit_file_change /etc/login.defs configure_login_defaults
configure_pwquality() {
    local setting
    for setting in minlen:12 dcredit:-1 ucredit:-1 lcredit:-1 ocredit:-1 \
        difok:4 maxrepeat:3 dictcheck:1 usercheck:1 enforcing:1; do
        set_policy_value /etc/security/pwquality.conf "${setting%%:*}" "${setting#*:}" ' = ' || return 1
    done
}
audit_file_change /etc/security/pwquality.conf configure_pwquality
configure_faillock() {
    local setting
    for setting in deny:5 fail_interval:900 unlock_time:900; do
        set_policy_value /etc/security/faillock.conf "${setting%%:*}" "${setting#*:}" ' = ' || return 1
    done
    # Avoid exposing account existence or double-locking directory-service users.
    for setting in silent local_users_only; do
        set_policy_value /etc/security/faillock.conf "$setting" '' '' || return 1
    done
}
audit_file_change /etc/security/faillock.conf configure_faillock
for file in /etc/login.defs /etc/security/pwquality.conf /etc/security/faillock.conf; do
    secure_path "$file" 644 root root
done

# Let pam-auth-update calculate success jumps around the failure-recording module.
for profile in cyberpatriot-faillock-preauth cyberpatriot-faillock-authfail; do
    audit_file_change "/usr/share/pam-configs/$profile" \
        install -m 644 "$SCRIPT_DIR/pam-configs/$profile" "/usr/share/pam-configs/$profile"
done
backup_system_paths /etc/pam.d /var/lib/pam
pam_backup=$SYSTEM_BACKUP_DIR
if ! pam-auth-update --enable pwquality cyberpatriot-faillock-preauth cyberpatriot-faillock-authfail ||
   ! awk -f "$SCRIPT_DIR/check_pam_policy.awk" /etc/pam.d/common-auth /etc/pam.d/common-account /etc/pam.d/common-password; then
    # A refused or partial update must not leave newly generated login stacks active.
    for file in "$pam_backup/files/etc/pam.d"/common-*; do
        [[ ! -f "$file" ]] || cp -p "$file" "/etc/pam.d/${file##*/}"
    done
    if [[ -d "$pam_backup/files/var/lib/pam" ]]; then
        cp -a "$pam_backup/files/var/lib/pam/." /var/lib/pam/
    fi
    for profile in cyberpatriot-faillock-preauth cyberpatriot-faillock-authfail; do
        file="/usr/share/pam-configs/$profile"
        if [[ -f "$backup/files$file" ]]; then
            cp -p "$backup/files$file" "$file"
        else
            rm -f -- "$file"
        fi
    done
    log "FAILED: PAM policy could not be verified; previous stacks restored from $pam_backup; review custom PAM modules/options"
    exit 1
fi
for file in /etc/pam.d/common-*; do
    [[ -f "$file" ]] || continue
    previous="$backup/files/etc/pam.d/${file##*/}"
    if [[ -f "$previous" ]]; then
        changes=$(diff -u "$previous" "$file") || status=$?
        [[ ${status:-0} -le 1 ]] || exit 1
        [[ -z "$changes" ]] || log "CHANGED PAM stack $file: $changes"
    else
        log "CREATED PAM stack: $file"
    fi
    status=0
done
secure_auth_permissions
log 'Configured login.defs, pwquality.conf and faillock.conf, creating missing files'
log 'Password quality enabled: minimum 12 characters with upper/lowercase, digit and special character; existing account aging unchanged'
log 'Local-account lockout enabled: 5 failures in 900 seconds, unlocked after 900 seconds; existing root-lockout policy retained'
log 'Protected existing PAM modules, PAM/security configuration and authentication logs'
