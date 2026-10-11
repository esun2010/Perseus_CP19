#!/usr/bin/env bash
# Native FreeBSD permissions, with a report of remaining world-writable paths.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../service_helpers/platform.sh"
require_freebsd_root
source "$SCRIPT_DIR/../../../main/logging.sh"
source "$SCRIPT_DIR/../service_helpers/permissions.sh"
source "$SCRIPT_DIR/../service_helpers/path_hardening.sh"
init_logging
require_commands find stat realpath
OUTPUT_FILE="$(cd "$SCRIPT_DIR/../../.." && pwd)/log/world_files.txt"
[[ ! -L "$SCRIPT_DIR/../../../log" && ! -L "$OUTPUT_FILE" && ! -L "$OUTPUT_FILE.errors" ]] || {
    log 'FAILED: report paths must not be symbolic links'; exit 1;
}
mkdir -p "$SCRIPT_DIR/../../../log"

secure_auth_permissions
secure_local_login_files
secure_native_startup
secure_native_trust
secure_native_boot
for service_name in sshd apache24 vsftpd pf; do
    secure_service_permissions "$service_name"
done
for file in /etc/crontab /etc/fstab /etc/hosts /etc/rc.conf /etc/rc.conf.local /etc/sysctl.conf; do
    secure_path "$file" 644
done
for directory in /etc /usr/local/etc /boot /var/log; do
    secure_path "$directory" 755
done
secure_path /root 700
for directory in /tmp /var/tmp; do
    [[ -d "$directory" && ! -L "$directory" ]] || continue
    chown root:wheel "$directory"
    audit_chmod 1777 "$directory"
done

# FreeBSD commonly uses /usr/home, with /home as a symlink. Select actual
# local human accounts instead of recursively changing every home-like path.
while IFS=: read -r username _ uid _ _ home shell; do
    [[ "$uid" =~ ^[0-9]+$ ]] && ((uid >= 1000 && uid < 65534)) || continue
    [[ "$shell" != */nologin && "$shell" != */false ]] || continue
    [[ "$home" == /home/* || "$home" == /usr/home/* ]] || continue
    [[ -d "$home" && ! -L "$home" ]] || continue
    resolved=$(realpath "$home")
    case "$resolved" in /home/*|/usr/home/*) ;; *) log "SKIPPED unexpected home target: $home"; continue ;; esac
    audit_chmod 700 "$home"
done < /etc/passwd

write_world_report() {
    local status=0
    {
        printf 'FreeBSD world-writable path report\nGenerated: %s\n\n' "$(date)"
        printf 'Mounted local filesystems; devfs, procfs, network mounts, and /compat excluded.\n'
        printf 'Sticky temporary directories are expected and require review, not deletion.\n\n'
    } > "$OUTPUT_FILE" || return 1
    # -fstype local includes separately mounted UFS/ZFS datasets, unlike -xdev.
    # FreeBSD find never follows symbolic links unless -H or -L is supplied.
    find / \( ! -fstype local -o -path /dev -o -path /proc -o -path /compat -o -name .zfs \) -prune -o \
        \( -type f -o -type d \) -perm -0002 -print >> "$OUTPUT_FILE" 2> "$OUTPUT_FILE.errors" || status=1
    chmod 644 "$OUTPUT_FILE" "$OUTPUT_FILE.errors" || return 1
    if ((status)); then
        log "WARNING: world-writable scan incomplete; inspect $OUTPUT_FILE.errors"
    fi
    return "$status"
}
audit_file_change "$OUTPUT_FILE" write_world_report
log "Permission hardening complete; review $OUTPUT_FILE"
