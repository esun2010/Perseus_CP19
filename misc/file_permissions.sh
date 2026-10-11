#!/bin/bash
# Use the native implementation when invoked directly on FreeBSD.
if [[ "${BASH_SOURCE[0]}" == "$0" && $(uname -s) == FreeBSD ]]; then
    exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/platforms/FreeBSD/misc/file_permissions.sh" "$@"
fi

# Linux Permission Hardening Script
# ---------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FILE="$(cd "$SCRIPT_DIR/.." && pwd)/log/world_files.txt"
source "$SCRIPT_DIR/../main/logging.sh"
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
for service in ssh apache2 vsftpd ufw; do
    secure_service_permissions "$service" || exit 1
done

echo "[+] Configuring important file permissions..."

# Files and their desired permissions
declare -A FILE_PERMS=(
    ["/etc/sudoers"]="440"
    ["/etc/ssh/sshd_config"]="600"
    ["/etc/crontab"]="644"
    ["/etc/fstab"]="644"
    ["/etc/hosts"]="644"
    ["/etc/hostname"]="644"
)

for FILE in "${!FILE_PERMS[@]}"; do
    if [ -e "$FILE" ]; then
        audit_chmod "${FILE_PERMS[$FILE]}" "$FILE" || exit 1
    fi
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
)

for DIR in "${!DIR_PERMS[@]}"; do
    if [ -d "$DIR" ]; then
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
echo "[+] Searching for world-writable files and directories..."
echo "    This may take a while."

# Start the output file
write_world_report() {
{
    echo "Linux World-Writable File/Directory Report"
    echo "Generated: $(date)"
    echo
    echo "========================================"
    echo "WORLD-WRITABLE FILES"
    echo "========================================"
    echo
} > "$OUTPUT_FILE"

# Find world-writable regular files
find / \
    \( -path /proc -o -path '/proc/*' -o -path '*/CyberPatriot_Linux_2026' -o -path '*/CyberPatriot_Linux_2026/*' \) -prune -o \
    -type f \
    -perm -0002 \
    -print 2>/dev/null >> "$OUTPUT_FILE"

{
    echo
    echo "========================================"
    echo "WORLD-WRITABLE DIRECTORIES"
    echo "========================================"
    echo
} >> "$OUTPUT_FILE"

# Find world-writable directories
find / \
    \( -path /proc -o -path '/proc/*' -o -path '*/CyberPatriot_Linux_2026' -o -path '*/CyberPatriot_Linux_2026/*' \) -prune -o \
    -type d \
    -perm -0002 \
    -print 2>/dev/null >> "$OUTPUT_FILE"
}

audit_file_change "$OUTPUT_FILE" write_world_report || exit 1

echo
echo "[+] Report saved to:"
echo "    $OUTPUT_FILE"

echo
echo "========================================"
echo " Permission hardening complete."
echo "========================================"
