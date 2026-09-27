#!/usr/bin/env bash
# Parse data; never execute the user-editable service list.
load_critical_services() {
    local file="$1" line name port extra seen_none=0
    CRITICAL_SERVICES=()
    EXTRA_PORTS=()
    [[ -r "$file" ]] || { echo "Cannot read $file" >&2; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line//$'\r'/}
        line=${line%%#*}
        read -r name port extra <<< "$line"
        [[ -n "$name" ]] || continue
        name=${name,,}
        if [[ "$name" == allow ]]; then
            [[ -z "$extra" ]] && valid_port_rule "$port" || {
                echo "Invalid firewall rule in $file: $line" >&2; return 1;
            }
            EXTRA_PORTS+=("$port")
            continue
        fi
        [[ -z "$port" ]] || { echo "Use one service per line: $line" >&2; return 1; }
        case "$name" in
            ssh|sshd|openssh|openssh-server) name=ssh ;;
            apache2|apache|http|httpd|https) name=apache2 ;;
            vsftpd|vsftp|ftp) name=vsftpd ;;
            ufw) name=ufw ;;
            bind9|bind|named) name=bind9 ;;
            mysql|mysqld|mariadb|mysql-server|mariadb-server) name=mysql ;;
            postfix) name=postfix ;;
            sendmail) name=sendmail ;;
            samba|smb|smbd|samba_server) name=samba ;;
            wordpress|wp) name=wordpress ;;
            joomla) name=joomla ;;
            openvpn) name=openvpn ;;
            nginx) name=nginx ;;
            sssd|fail2ban|chrony|ntpd|acpid|smartd|rsyslog|dhcpd|snmpd) ;;
            chronyd|crony) name=chrony ;;
            ntp|ntpsec) name=ntpd ;;
            isc-dhcp-server) name=dhcpd ;;
            nfs|nfs-server|nfs-kernel-server) name=nfs ;;
            avahi|avahi-daemon) name=avahi ;;
            cups|cupsd) name=cups ;;
            snmp) name=snmpd ;;
            smartmontools) name=smartd ;;
            none) seen_none=1; continue ;;
            *) echo "Unsupported critical service: $name. Configure it separately and add 'allow PORT/tcp'." >&2; return 1 ;;
        esac
        if ! critical_service "$name"; then CRITICAL_SERVICES+=("$name"); fi
    done < "$file"
    if ((seen_none && ${#CRITICAL_SERVICES[@]})); then
        echo "Remove 'none' when listing critical services in $file." >&2
        return 1
    fi
    # An empty/truncated list must never authorize automatic removal.
    if ((seen_none == 0 && ${#CRITICAL_SERVICES[@]} == 0)); then
        echo "List required services or explicitly write 'none' in $file." >&2
        return 1
    fi
    if critical_service postfix && critical_service sendmail; then
        echo 'Choose one MTA: postfix or sendmail, not both on the same host.' >&2
        return 1
    fi

    if critical_service chrony && critical_service ntpd; then
        echo 'Choose one time daemon: chrony or ntpd.' >&2
        return 1
    fi

}

critical_service() {
    local item
    for item in "${CRITICAL_SERVICES[@]}"; do [[ "$item" == "$1" ]] && return 0; done
    return 1
}

valid_port_rule() {
    local rule="$1" first last
    [[ "$rule" =~ ^([0-9]{1,5})(:([0-9]{1,5}))?/(tcp|udp)$ ]] || return 1
    first=$((10#${BASH_REMATCH[1]}))
    last=$first
    [[ -z "${BASH_REMATCH[3]}" ]] || last=$((10#${BASH_REMATCH[3]}))
    ((first >= 1 && last <= 65535 && first <= last))
}
