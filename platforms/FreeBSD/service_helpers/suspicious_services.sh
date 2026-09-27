#!/usr/bin/env bash
# Read-only review of commonly exposed services; a finding is not proof of malware.
suspicious_service_family() {
    local name="${1%%:*}" family
    name=${name%.service}; name=${name%.socket}; name=${name%%@*}
    if family=$(unit_family "$1"); then printf '%s\n' "$family"; return 0; fi
    if family=$(package_family "$name"); then printf '%s\n' "$family"; return 0; fi
    case "$name" in
        apache2|apache2-bin|apache24|apache[0-9]*|httpd) echo apache2 ;;
        ssh|sshd|openssh|openssh-server|openssh-portable) echo ssh ;;
        vsftpd|vsftpd-*) echo vsftpd ;;
        proftpd*|pure-ftpd*|ftpd) echo ftp-other ;;
        telnetd|in.telnetd|telnetd-ssl|inetutils-telnetd) echo telnet ;;
        rsh-server|rshd|rlogind|rexecd|rsh-redone-server) echo rsh ;;
        tftpd*|tftp-hpa|tftp|atftpd) echo tftp ;;
        nfs-server|nfs-kernel-server|nfsd|mountd|rpcbind) echo nfs ;;
        snmpd|net-snmp*) echo snmp ;;
        avahi-daemon|avahi) echo avahi ;;
        cups|cupsd|cups-daemon|cups-browsed) echo cups ;;
        redis|redis-server|redis[0-9]*) echo redis ;;
        mongod|mongodb|mongodb-org-server|mongodb[0-9]*) echo mongodb ;;
        postgresql|postgresql-[0-9]*|postgresql[0-9]*-server) echo postgresql ;;
        tor|tor-*) echo tor ;;
        xrdp|xrdp-sesman) echo xrdp ;;
        x11vnc|tigervnc*|tightvncserver|vncserver|vncserver-*) echo vnc ;;
        squid|squid[0-9]*|tinyproxy|privoxy) echo proxy ;;
        rsync|rsyncd) echo rsync ;;
        inetd|openbsd-inetd|inetutils-inetd|xinetd) echo inetd ;;
        docker|docker.io|docker-ce|containerd|containerd.io) echo containers ;;
        *) return 1 ;;
    esac
}

suspicious_service_reason() {
    case "$1" in
        apache2|nginx|wordpress|joomla) echo 'Web content/application exposure; review sites and listeners' ;;
        telnet|rsh|ftp-other|vsftpd|tftp) echo 'Remote access/file transfer; review authentication and transport encryption' ;;
        ssh|xrdp|vnc|openvpn) echo 'Remote access path; review authorized users and network reachability' ;;
        mysql|postgresql|mongodb|redis) echo 'Database/cache access; review bind addresses, authentication and stored data' ;;
        postfix|sendmail|proxy|tor) echo 'Mail, proxy or relay capability; review unauthorized relaying and egress' ;;
        samba|nfs|rsync) echo 'File sharing; review exported paths and write permissions' ;;
        inetd) echo 'Super-server can launch additional services; inspect its configuration' ;;
        containers) echo 'Container runtime; review privileged workloads and daemon access' ;;
        *) echo 'Additional network service; review necessity, configuration and listeners' ;;
    esac
}

suspicious_packages() {
    if [[ "$MANAGED_PLATFORM" == linux ]]; then
        local output
        output=$(dpkg-query -W -f='${Package}\t${db:Status-Status}\n') || return 1
        awk '$2 == "installed" {print $1}' <<< "$output"
    else pkg query -a '%n'; fi
}

suspicious_unit_state() {
    local unit="$1" state enabled
    if [[ "$MANAGED_PLATFORM" == linux ]]; then
        state=$(systemctl show "$unit" -p ActiveState -p SubState -p UnitFileState --no-pager) || return 1
        printf '%s' "${state//$'\n'/; }"
    else
        enabled=$(service -e) || return 1
        if grep -Fqx "/etc/rc.d/$unit" <<< "$enabled" || grep -Fqx "/usr/local/etc/rc.d/$unit" <<< "$enabled"; then state='boot-enabled'
        else state='not boot-enabled'; fi
        if service "$unit" onestatus >/dev/null 2>&1; then printf 'running; %s' "$state"
        else printf 'not running or status unavailable; %s' "$state"; fi
    fi
}

suspicious_write() {
    local message="$*"
    message=${message//\\/\\\\}; message=${message//$'\n'/\\n}
    message=${message//$'\r'/\\r}; message=${message//$'\t'/\\t}
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$message" >> "$SUSPICIOUS_LOG"
}

audit_suspicious_services() {
    local packages units name family state count=0 failed=0
    SUSPICIOUS_LOG="$REPO_DIR/suspicious_services.txt"
    [[ ! -L "$SUSPICIOUS_LOG" && ( ! -e "$SUSPICIOUS_LOG" || -f "$SUSPICIOUS_LOG" ) ]] || {
        log "FAILED unsafe suspicious-services log path: $SUSPICIOUS_LOG"; return 1;
    }
    (umask 077; touch "$SUSPICIOUS_LOG") && chmod 600 "$SUSPICIOUS_LOG" || return 1
    suspicious_write 'SCAN START — unlisted services to review, not confirmed malware; captured before service disabling' || return 1
    if ! packages=$(suspicious_packages); then
        suspicious_write 'ERROR: installed-package inventory unavailable' || return 1; packages=''; failed=1
    fi
    if ! units=$(managed_units); then
        suspicious_write 'ERROR: service inventory unavailable' || return 1; units=''; failed=1
    fi
    while IFS= read -r name; do
        family=$(suspicious_service_family "$name") || continue
        critical_service "$family" && continue
        suspicious_write "REVIEW family=$family package=$name state=installed (running/boot state not inferred) reason=$(suspicious_service_reason "$family")" || return 1
        count=$((count+1))
    done <<< "$packages"
    while IFS= read -r name; do
        family=$(suspicious_service_family "$name") || continue
        critical_service "$family" && continue
        if ! state=$(suspicious_unit_state "$name"); then
            state='UNKNOWN (state query failed)'; failed=1
        fi
        suspicious_write "REVIEW family=$family service=$name state=$state reason=$(suspicious_service_reason "$family")" || return 1
        count=$((count+1))
    done <<< "$units"
    suspicious_write "SCAN END findings=$count incomplete=$failed; catalog-based check, custom names and unpackaged CMS installations may require manual review" || return 1
    log "Suspicious-services review: $count findings; incomplete=$failed; $SUSPICIOUS_LOG"
    ((failed == 0))
}
