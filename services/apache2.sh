#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/config/logging.sh"
source "$ROOT_DIR/service_helpers/distribution.sh"
source "$ROOT_DIR/service_helpers/permissions.sh"
[[ $EUID -eq 0 ]] || { echo 'Run this service script as root.' >&2; exit 1; }
[[ $(uname -s) == Linux ]] || { echo 'Apache setup script supports Ubuntu, Debian, and Mint.' >&2; exit 1; }
init_logging
load_distribution || exit 1
command -v apt-get >/dev/null && command -v apache2ctl >/dev/null || { log 'FAILED required apt-get/apache2ctl command missing'; exit 1; }
dpkg-query -W -f='${db:Status-Status}' apache2 2>/dev/null | grep -qx installed || {
    backup_package_configuration || exit 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y apache2 || exit 1
}
config=/etc/apache2/conf-available/cyberpatriot-security.conf
backup_system_paths /etc/apache2 || exit 1
install -o root -g root -m 0644 /dev/null "$config"
cat > "$config" <<'APACHE'
# CyberPatriot Apache information disclosure hardening
ServerTokens Prod
ServerSignature Off
TraceEnable Off
APACHE
if ! a2enconf cyberpatriot-security >/dev/null || ! apache2ctl configtest; then
    log 'FAILED Apache config validation; restore /etc/apache2 from the saved backup'
    exit 1
fi
secure_service_permissions apache2 || exit 1
systemctl enable --now apache2 || exit 1
systemctl is-active --quiet apache2 || { log 'FAILED apache2 did not become active'; exit 1; }
log 'CONFIGURED Apache disclosure settings and enabled apache2'
