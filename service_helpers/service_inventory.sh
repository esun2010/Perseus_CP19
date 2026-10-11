#!/usr/bin/env bash
# Read-only installed package and service inventory used by the optional audit.
MANAGED_PLATFORM=linux
if [[ $(uname -s) == FreeBSD ]]; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/platforms/FreeBSD/service_helpers/service_inventory.sh"
    return $?
fi
installed_server_packages() {
    local listing
    listing=$(dpkg-query -W -f='${Package}\t${db:Status-Status}\n') || return 1
    awk '$2 == "installed" || $2 == "config-files" {print $1}' <<< "$listing"
}

unit_family() {
    case "$1" in
        named.service|named-resolvconf.service|bind9.service) echo bind9 ;;
        mysql.service|mysql@*.service|mysqld.service|mysqld@*.service|mariadb.service|mariadb@*.service|mariadb*.socket) echo mysql ;;
        postfix.service|postfix@*.service) echo postfix ;;
        sendmail.service|sm-client.service) echo sendmail ;;
        smbd.service|nmbd.service|samba.service|samba-ad-dc.service|samba-bgqd.service) echo samba ;;
        nginx.service|nginx.socket) echo nginx ;;
        openvpn.service|openvpn@*.service|openvpn-server@*.service|openvpn-client@*.service) echo openvpn ;;
        *) return 1 ;;
    esac
}

managed_units() {
    local files active
    files=$(systemctl list-unit-files --no-legend --no-pager) || return 1
    active=$(systemctl list-units --all --plain --no-legend --no-pager) || return 1
    printf '%s\n%s\n' "$files" "$active" | awk '{print $1}' | sort -u
}

