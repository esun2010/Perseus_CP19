#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/config/logging.sh"
source "$ROOT_DIR/service_helpers/distribution.sh"
source "$ROOT_DIR/service_helpers/permissions.sh"
source "$ROOT_DIR/platforms/FreeBSD/service_helpers/platform.sh"
source "$ROOT_DIR/platforms/FreeBSD/service_helpers/permissions.sh"
source "$ROOT_DIR/platforms/FreeBSD/service_helpers/managed_platform.sh"

load_distribution || exit 1

if [[ "$CP_DISTRO" == freebsd ]]; then
    require_freebsd_root || exit 1
    init_logging
    require_commands sysrc service pfctl || exit 1

    # PF is part of the FreeBSD base system, so no package installation is needed.
    if [[ ! -e /etc/pf.conf ]]; then
        log 'FAILED expected FreeBSD PF configuration /etc/pf.conf is missing; refusing to create an empty firewall policy.'
        exit 1
    fi
    [[ -f /etc/pf.conf && ! -L /etc/pf.conf ]] || {
        log 'FAILED /etc/pf.conf must be a regular, non-symlink file.'; exit 1;
    }

    secure_path /etc/pf.conf 600 root wheel || exit 1

    pfctl -nf /etc/pf.conf || { log 'FAILED validating PF configuration'; exit 1; }
    audit_file_change /etc/rc.conf sysrc pf_enable=YES || { log 'FAILED enabling PF at startup'; exit 1; }
    service pf onestart || { log 'FAILED starting PF'; exit 1; }
    [[ $(sysrc -n pf_enable 2>/dev/null) == YES ]] || { log 'FAILED verifying PF startup enablement'; exit 1; }
    service pf status || { log 'FAILED verifying PF status'; exit 1; }
    log 'Enabled the native PF firewall and configured it to start at boot.'
    exit 0
fi

[[ $EUID -eq 0 ]] || { echo 'Run this service script as root.' >&2; exit 1; }
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
