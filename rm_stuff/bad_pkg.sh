#!/usr/bin/env bash
if [[ "${BASH_SOURCE[0]}" == "$0" && $(uname -s) == FreeBSD ]]; then
    exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/platforms/FreeBSD/rm_stuff/bad_pkg.sh" "$@"
fi
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../logging.sh"
[[ $EUID -eq 0 ]] || { echo 'Run this script as root.' >&2; exit 1; }
BAD_PACKAGES=(nmap netcat netcat-openbsd netcat-traditional john hydra medusa ophcrack hashcat wireshark aircrack-ng kismet telnet rsh-server xinetd tor deluge transmission sqlmap nikto)
for pkg in "${BAD_PACKAGES[@]}"; do
    package_status=$(dpkg-query -W -f='${db:Status-Status}' -- "$pkg" 2>/dev/null) || package_status=absent
    if [[ "$package_status" == installed ]]; then
        log "REMOVING listed package: $pkg"
        apt-get purge -y -- "$pkg"
    else
        printf 'Not installed: %s\n' "$pkg"
    fi
done
