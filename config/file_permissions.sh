#!/bin/bash
# Use the native implementation when invoked directly on FreeBSD.
if [[ "${BASH_SOURCE[0]}" == "$0" && $(uname -s) == FreeBSD ]]; then
    exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/platforms/FreeBSD/misc/file_permissions.sh" "$@"
fi

# Linux Permission Hardening Script
# ---------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config/logging.sh"
source "$SCRIPT_DIR/../service_helpers/permissions.sh"
source "$SCRIPT_DIR/../service_helpers/path_hardening.sh"

echo "========================================"
echo " Linux Permission Hardening"
echo "========================================"
echo

# Make sure the script is running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo:"
    echo "sudo $0"
    exit 1
fi

init_logging
mkdir -p "$SCRIPT_DIR/../log" || exit 1
secure_auth_permissions || exit 1
secure_local_login_files || exit 1
secure_vendor_units_and_trust || exit 1
secure_boot_paths || exit 1
for service in ssh apache2 vsftpd; do
    secure_service_permissions "$service" || exit 1
done

echo "[+] Configuring important file permissions..."

# Files and their desired permissions
declare -A FILE_PERMS=(
    ["/etc/sudoers"]="440"
    ["/etc/ssh/sshd_config"]="600"
    ["/etc/crontab"]="600"
    ["/etc/fstab"]="644"
    ["/etc/hosts"]="644"
    ["/etc/hostname"]="644"
)

for FILE in "${!FILE_PERMS[@]}"; do
    if [ -e "$FILE" ]; then
        audit_chmod "${FILE_PERMS[$FILE]}" "$FILE" || exit 1
    fi
done

# Sudo include files need a glob because each regular file shares one policy.
for FILE in /etc/sudoers.d/*; do
    [ -f "$FILE" ] && [ ! -L "$FILE" ] || continue
    audit_chmod 440 "$FILE" || exit 1
done

echo
echo "[+] Configuring important directories..."

# Directory permissions
declare -A DIR_PERMS=(
    ["/etc"]="755"
    ["/root"]="700"
    ["/boot"]="755"
    ["/var/log"]="755"
    ["/tmp"]="1777"
    ["/var/tmp"]="1777"
    ["/etc/cron.d"]="700"
    ["/etc/cron.daily"]="700"
    ["/etc/cron.hourly"]="700"
    ["/etc/cron.weekly"]="700"
    ["/etc/cron.monthly"]="700"
)

for DIR in "${!DIR_PERMS[@]}"; do
    if [ -d "$DIR" ]; then
        case "$DIR" in /etc/cron.d|/etc/cron.daily|/etc/cron.hourly|/etc/cron.weekly|/etc/cron.monthly) chown root:root "$DIR" || exit 1 ;; esac
        audit_chmod "${DIR_PERMS[$DIR]}" "$DIR" || exit 1
    fi
done

echo
echo "[+] Securing user home directories..."

# Set /home/<user> directories to 700
if [ -d /home ]; then
    for HOME_DIR in /home/*; do
        if [ -d "$HOME_DIR" ]; then
            audit_chmod 700 "$HOME_DIR" || exit 1
        fi
    done
fi

echo
echo "========================================"
echo " Permission hardening complete."
echo "========================================"
