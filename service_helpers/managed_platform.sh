#!/usr/bin/env bash
# Ubuntu/Debian operations. Never execute this helper directly.
MANAGED_PLATFORM=linux

installed_server_packages() {
    local listing
    listing=$(dpkg-query -W -f='${Package}\t${db:Status-Status}\n') || return 1
    awk '$2 == "installed" || $2 == "config-files" {print $1}' <<< "$listing"
}

package_family() {
    case "$1" in
        bind9) echo bind9 ;;
        mysql-server|mysql-server-*|mysql-community-server|mysql-community-server-*|default-mysql-server|mariadb-server|mariadb-server-*) echo mysql ;;
        postfix|postfix-*) echo postfix ;;
        sendmail|sendmail-base|sendmail-bin|sendmail-cf) echo sendmail ;;
        samba|samba-ad-dc) echo samba ;;
        nginx|nginx-core|nginx-full|nginx-light|nginx-extras|nginx-common) echo nginx ;;
        openvpn) echo openvpn ;;
        wordpress|wordpress-*) echo wordpress ;;
        joomla|joomla-*) echo joomla ;;
        *) return 1 ;;
    esac
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

disable_managed_unit() {
    local unit="$1"
    backup_system_paths /etc/systemd/system || return 1
    if [[ "$unit" == *@.service ]]; then
        systemctl disable "$unit" || return 1
    else
        systemctl disable --now "$unit" || return 1
    fi
    systemctl mask "$unit" || return 1
    if systemctl is-active --quiet "$unit"; then log "FAILED stopping $unit"; return 1; fi
    [[ "$(systemctl is-enabled "$unit" 2>/dev/null)" == masked ]] || {
        log "FAILED: $unit is not persistently masked"; return 1;
    }
    log "DISABLED and persistently masked unlisted service: $unit"
}

install_managed_package() {
    local key="$1" package="" existing
    existing=$(installed_server_packages) || return 1
    case "$key" in
        bind9) package=bind9 ;;
        mysql)
            if grep -Eq '^(mariadb-server|mysql-server|mysql-community-server)(-|$)' <<< "$existing"; then return 0; fi
            package=mariadb-server ;;
        postfix|sendmail|samba|nginx|openvpn) package="$key" ;;
        *) return 1 ;;
    esac
    # Refuse install plans which would replace other services (e.g. a database
    # engine or a mail transport) without an explicit migration.
    local plan
    plan=$(LC_ALL=C apt-get -s install -- "$package") || return 1
    if grep -Eq '^(Remv|Purg) ' <<< "$plan"; then
        log "FAILED: installing $package would remove existing packages; resolve the conflict first"; return 1
    fi
    install_packages "$package"
}

managed_enable() {
    backup_system_paths /etc/systemd/system || return 1
    systemctl unmask "$1" || return 1
    enable_service "$1"
}

configure_native_service() {
    local key="$1" config role unit profile found=0
    install_managed_package "$key" || return 1
    case "$key" in
        bind9)
            config=/etc/bind/named.conf
            require_regular_config "$config" || return 1
            named-checkconf -z "$config" || return 1
            secure_path "$config" 644 || return 1
            # Modern Ubuntu names the real unit named; bind9 may be an alias.
            unit=named
            [[ "$(systemctl show -p LoadState --value named.service)" != not-found ]] || unit=bind9
            managed_enable "$unit" ;;
        mysql)
            config=/etc/mysql/my.cnf
            # Debian's main my.cnf is commonly an alternatives symlink.
            config=$(readlink -f "$config") || return 1
            require_regular_config "$config" || return 1
            secure_path "$config" 644 || return 1
            unit=mysql
            [[ "$(systemctl show -p LoadState --value mariadb.service)" == not-found ]] || unit=mariadb
            managed_enable "$unit" ;;
        postfix)
            config=$(postconf -h config_directory) || return 1
            config="$config/main.cf"
            require_regular_config "$config" || return 1
            backup_config "$config" || return 1
            local previous="$CONFIG_BACKUP"
            # Do not log the configuration diff: custom files may contain secrets.
            if ! postconf -e 'disable_vrfy_command = yes' || ! postfix check || ! managed_enable postfix; then
                backup_system_paths "$config" || return 1
                cp -p "$previous" "$config" || return 1
                log 'FAILED Postfix setup; restored main.cf'; return 1
            fi ;;
        sendmail)
            config=/etc/mail/sendmail.cf
            require_regular_config "$config" || return 1
            sendmail -C "$config" -bt < /dev/null > /dev/null || return 1
            secure_path "$config" 644 || return 1
            managed_enable sendmail ;;
        samba)
            config=/etc/samba/smb.conf
            require_regular_config "$config" || return 1
            testparm -s "$config" > /dev/null || return 1
            role=$(testparm -s --parameter-name='server role' "$config" 2>/dev/null) || return 1
            secure_path "$config" 644 || return 1
            if [[ "$role" == *'active directory domain controller'* ]]; then
                managed_enable samba-ad-dc || return 1
            else
                managed_enable smbd || return 1
                managed_enable nmbd || return 1
            fi ;;
        nginx)
            require_regular_config /etc/nginx/nginx.conf || return 1
            nginx -t || return 1
            secure_path /etc/nginx/nginx.conf 644 || return 1
            managed_enable nginx ;;
        openvpn)
            # A working VPN needs scenario-specific PKI, routes and peer settings.
            # Never invent keys or replace an existing VPN profile with a template.
            for config in /etc/openvpn/server/*.conf /etc/openvpn/*.conf; do
                [[ -f "$config" ]] || continue
                require_regular_config "$config" || return 1
                profile=${config##*/}; profile=${profile%.conf}
                [[ "$profile" =~ ^[A-Za-z0-9_-]+$ ]] || { log "FAILED invalid OpenVPN profile name: $profile"; return 1; }
                secure_path "$config" 600 || return 1
                if [[ "$config" == /etc/openvpn/server/* ]]; then unit="openvpn-server@$profile"
                else unit="openvpn@$profile"; fi
                managed_enable "$unit" || return 1
                found=1
            done
            ((found)) || { log 'FAILED: OpenVPN requires an existing configured profile in /etc/openvpn/server or /etc/openvpn'; return 1; } ;;
    esac
}

cms_owner() { stat -c '%U' "$1"; }
cms_group() { stat -c '%G' "$1"; }

# Actual listeners, including nonstandard ports. Never open loopback databases.
native_managed_listeners() {
    local sockets
    sockets=$(ss -H -lntup) || return 1
    awk '{proto=$1; endpoint=$5; if (proto !~ /^(tcp|udp)$/) next;
        if (endpoint ~ /^127\./ || endpoint ~ /^\[?::1\]?:/) next;
        port=endpoint; sub(/^.*:/,"",port); if(port !~ /^[0-9]+$/) next;
        print proto " " port " " $0}' <<< "$sockets"
}
