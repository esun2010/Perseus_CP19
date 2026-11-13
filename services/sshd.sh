#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/config/logging.sh"
source "$ROOT_DIR/service_helpers/distribution.sh"
source "$ROOT_DIR/service_helpers/permissions.sh"
[[ $EUID -eq 0 ]] || { echo 'Run this service script as root.' >&2; exit 1; }
[[ $(uname -s) == Linux ]] || { echo 'SSH setup script supports Ubuntu, Debian, and Mint.' >&2; exit 1; }
init_logging
load_distribution || exit 1
command -v apt-get >/dev/null && command -v sshd >/dev/null || { log 'FAILED required apt-get/sshd command missing'; exit 1; }
dpkg-query -W -f='${db:Status-Status}' openssh-server 2>/dev/null | grep -qx installed || {
    backup_package_configuration || exit 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server || exit 1
}
config=/etc/ssh/sshd_config
[[ -f "$config" && ! -L "$config" ]] || { log "FAILED expected regular config: $config"; exit 1; }
backup_system_paths "$config" || exit 1
saved="$SYSTEM_BACKUP_DIR/files$config"
temporary=$(mktemp /etc/ssh/.sshd_config.XXXXXX)
trap 'rm -f -- "$temporary"' EXIT
awk '!/^[[:space:]]*#?[[:space:]]*(PermitRootLogin|MaxAuthTries)[[:space:]]+/ { print }' "$config" > "$temporary"
printf '\n# CyberPatriot SSH hardening\nPermitRootLogin no\nMaxAuthTries 4\n' >> "$temporary"
chown root:root "$temporary" && chmod 600 "$temporary" && mv -f -- "$temporary" "$config" || exit 1
if ! /usr/sbin/sshd -t -f "$config"; then cp -p -- "$saved" "$config"; log 'FAILED SSH config validation; restored original'; exit 1; fi
effective=$(/usr/sbin/sshd -T -f "$config") || { cp -p -- "$saved" "$config"; exit 1; }
grep -qx 'permitrootlogin no' <<< "$effective" && grep -qx 'maxauthtries 4' <<< "$effective" || {
    cp -p -- "$saved" "$config"
    log 'FAILED effective SSH settings did not match requested hardening; restored original'
    exit 1
}
secure_service_permissions ssh || { cp -p -- "$saved" "$config"; exit 1; }
unit=$(distribution_service_unit ssh) || { cp -p -- "$saved" "$config"; exit 1; }
systemctl enable --now "$unit" || { cp -p -- "$saved" "$config"; exit 1; }
systemctl is-active --quiet "$unit" || { cp -p -- "$saved" "$config"; exit 1; }
log "CONFIGURED and enabled $unit with root login disabled and MaxAuthTries 4"
