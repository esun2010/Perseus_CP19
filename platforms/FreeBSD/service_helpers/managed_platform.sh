#!/usr/bin/env bash
# Native FreeBSD operations; package versions are discovered, never hardcoded.
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

disable_managed_unit() {
    local unit="$1" variable
    if service "$unit" onestatus >/dev/null 2>&1; then service "$unit" onestop || return 1; fi
    case "$unit" in
        mysql-server) variable=mysql ;;
        *) variable="$unit" ;;
    esac
    if [[ "$unit" == sendmail ]]; then
        set_rc_value sendmail_enable=NONE || return 1
        set_rc_value sendmail_submit_enable=NO || return 1
        set_rc_value sendmail_outbound_enable=NO || return 1
        set_rc_value sendmail_msp_queue_enable=NO || return 1
        log 'DISABLED Sendmail; any base-system binary is retained (not a removable third-party package)'
    else
        set_rc_value "${variable}_enable=NO" || return 1
    fi
    if service "$unit" onestatus >/dev/null 2>&1; then log "FAILED stopping $unit"; return 1; fi
    local enabled
    enabled=$(service -e) || return 1
    if grep -Eq "/${unit}$" <<< "$enabled"; then
        log "FAILED: $unit is still enabled; inspect rc.conf.d overrides"; return 1
    fi
    log "DISABLED unlisted service at boot: $unit"
}

install_managed_package() {
    local key="$1" listing package family available selected=""
    listing=$(installed_server_packages) || return 1
    while IFS= read -r package; do
        family=$(package_family "$package") || continue
        [[ "$family" != "$key" ]] || return 0
    done <<< "$listing"
    # A base Sendmail installation does not need a replacement package.
    if [[ "$key" == sendmail && -x /usr/libexec/sendmail/sendmail && -f /etc/mail/sendmail.cf ]]; then return 0; fi
    available=$(pkg rquery -a '%n') || { log 'FAILED querying enabled FreeBSD package repositories; run pkg update'; return 1; }
    while IFS= read -r package; do
        family=$(package_family "$package") || continue
        [[ "$family" == "$key" ]] || continue
        # Prefer stable base packages, not development/LTS flavor substitutions.
        case "$key:$package" in
            bind9:bind9[0-9]*|mysql:mariadb[0-9]*-server|samba:samba4[0-9]*|postfix:postfix|sendmail:sendmail|nginx:nginx|openvpn:openvpn)
                [[ "$package" != *-devel* ]] || continue
                selected="$package"; break ;;
        esac
    done < <(printf '%s\n' "$available" | sort -Vr)
    if [[ -z "$selected" ]]; then
        log "UNAVAILABLE: no supported native package for $key in enabled repositories; configuration skipped"
        return 3
    fi
    install_packages "$selected"
}

managed_enable() {
    local unit="$1"
    if [[ "$unit" == mysql-server ]]; then
        set_rc_value mysql_enable=YES || return 1
        refresh_service mysql-server || return 1
        service mysql-server onestatus || return 1
    else
        enable_service "$unit" || return 1
    fi
}

configure_native_service() {
    local key="$1" config profiles profile status=0
    install_managed_package "$key" || status=$?
    [[ "$status" == 0 ]] || return "$status"
    case "$key" in
        bind9)
            config=$(sysrc -n named_conf 2>/dev/null) || config=/usr/local/etc/namedb/named.conf
            config=${config:-/usr/local/etc/namedb/named.conf}
            require_regular_config "$config" || return 1
            named-checkconf -z "$config" || return 1
            secure_path "$config" 644 || return 1
            managed_enable named ;;
        mysql)
            # Keep the installed engine, its users, data, listener and credentials.
            for config in /usr/local/etc/my.cnf /usr/local/etc/mysql/my.cnf; do
                [[ -e "$config" ]] || continue
                require_regular_config "$config" || return 1
                secure_path "$config" 644 || return 1
            done
            managed_enable mysql-server ;;
        postfix)
            config=$(postconf -h config_directory) || return 1
            config="$config/main.cf"
            require_regular_config "$config" || return 1
            backup_config "$config" || return 1
            local previous="$CONFIG_BACKUP"
            if ! postconf -e 'disable_vrfy_command = yes' || ! postfix check || ! managed_enable postfix; then
                backup_system_paths "$config" || return 1
                cp -p "$previous" "$config" || return 1
                log 'FAILED Postfix setup; restored main.cf'; return 1
            fi ;;
        sendmail)
            config=/etc/mail/sendmail.cf
            require_regular_config "$config" || return 1
            local binary=/usr/libexec/sendmail/sendmail
            [[ -x "$binary" ]] || binary=/usr/local/sbin/sendmail
            [[ -x "$binary" ]] || { log 'UNAVAILABLE: native Sendmail executable not found; configuration skipped'; return 3; }
            "$binary" -C "$config" -bt < /dev/null > /dev/null || return 1
            secure_path "$config" 644 || return 1
            managed_enable sendmail ;;
        samba)
            config=/usr/local/etc/smb4.conf
            require_regular_config "$config" || return 1
            testparm -s "$config" > /dev/null || return 1
            secure_path "$config" 644 || return 1
            managed_enable samba_server ;;
        nginx)
            config=/usr/local/etc/nginx/nginx.conf
            require_regular_config "$config" || return 1
            nginx -t || return 1
            secure_path "$config" 644 || return 1
            managed_enable nginx ;;
        openvpn)
            profiles=$(sysrc -n openvpn_profiles 2>/dev/null) || profiles=""
            if [[ -n "$profiles" ]]; then
                log 'FAILED: custom FreeBSD OpenVPN profiles need per-profile validation; use the existing rc configuration manually'
                return 1
            fi
            config=$(sysrc -n openvpn_configfile 2>/dev/null) || config=/usr/local/etc/openvpn/openvpn.conf
            config=${config:-/usr/local/etc/openvpn/openvpn.conf}
            require_regular_config "$config" || return 1
            secure_path "$config" 600 || return 1
            managed_enable openvpn ;;
    esac
}

cms_owner() { stat -f '%Su' "$1"; }
cms_group() { stat -f '%Sg' "$1"; }

native_managed_listeners() {
    local sockets
    sockets=$(sockstat -46l) || return 1
    awk 'NR>1 && $5 ~ /^(tcp|udp)[46]$/ {
        endpoint=$6; if(endpoint ~ /^127\./ || endpoint ~ /^\[?::1\]?:/) next;
        port=endpoint; sub(/^.*:/,"",port); if(port !~ /^[0-9]+$/) next;
        proto=$5; sub(/[46]$/,"",proto); print proto " " port " " $2
    }' <<< "$sockets"
}
