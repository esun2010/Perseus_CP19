#!/usr/bin/env bash
# Native FreeBSD permission hardening.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../service_helpers/platform.sh"
require_freebsd_root
source "$SCRIPT_DIR/../../../main/logging.sh"
source "$SCRIPT_DIR/../service_helpers/permissions.sh"
source "$SCRIPT_DIR/../service_helpers/path_hardening.sh"
init_logging
require_commands find stat realpath

secure_auth_permissions
secure_local_login_files
secure_native_startup
secure_native_trust
secure_native_boot
for service_name in sshd apache24 vsftpd; do
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

log 'Permission hardening complete'
