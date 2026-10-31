#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/config/logging.sh"
source "$ROOT_DIR/service_helpers/distribution.sh"
source "$ROOT_DIR/service_helpers/permissions.sh"

[[ $EUID -eq 0 ]] || { echo 'Run this service script as root.' >&2; exit 1; }
load_distribution || exit 1
[[ "$CP_DISTRO" != freebsd ]] || { echo 'UFW is not available on FreeBSD; use the native firewall configuration.' >&2; exit 1; }
init_logging

if ! command -v ufw >/dev/null 2>&1; then
    apt-get update -qq || { log 'FAILED refreshing APT before UFW installation'; exit 1; }
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw || { log 'FAILED installing UFW'; exit 1; }
fi

chown -R root:root /etc/ufw || { log 'FAILED setting UFW configuration ownership'; exit 1; }
chown root:root /etc/default/ufw || { log 'FAILED setting default UFW configuration ownership'; exit 1; }
secure_tree /etc/ufw 640 750 || exit 1
secure_path /etc/default/ufw 640 || exit 1

systemctl enable ufw || { log 'FAILED enabling UFW at startup'; exit 1; }
ufw --force enable || { log 'FAILED enabling UFW'; exit 1; }
systemctl is-enabled --quiet ufw || { log 'FAILED verifying UFW startup enablement'; exit 1; }
ufw status verbose || exit 1
log 'Enabled UFW and configured it to start at boot; inspect firewall rules before relying on them.'
