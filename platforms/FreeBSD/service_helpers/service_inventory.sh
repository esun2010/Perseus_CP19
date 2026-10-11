#!/usr/bin/env bash
MANAGED_PLATFORM=freebsd
installed_server_packages() { pkg query -a '%n'; }
package_family() {
    case "$1" in
        bind9[0-9]*) echo bind9 ;;
        mysql[0-9]*-server|mariadb[0-9]*-server) echo mysql ;;
        postfix|postfix-*|postfix[0-9]*) echo postfix ;;
        sendmail|sendmail-*) echo sendmail ;;
        samba4[0-9]*) echo samba ;;
        nginx|nginx-*) echo nginx ;;
        openvpn|openvpn-[0-9]*) echo openvpn ;;
        wordpress|wordpress-*) echo wordpress ;;
        joomla[0-9]*|joomla|joomla-*) echo joomla ;;
        *) return 1 ;;
    esac
}
unit_family() {
    case "$1" in
        named) echo bind9 ;;
        mysql-server) echo mysql ;;
        postfix) echo postfix ;;
        sendmail) echo sendmail ;;
        samba_server|smbd|nmbd|samba) echo samba ;;
        nginx) echo nginx ;;
        openvpn|openvpn_*) echo openvpn ;;
        *) return 1 ;;
    esac
}
managed_units() { service -l; }
