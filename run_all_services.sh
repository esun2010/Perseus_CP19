#!/bin/bash
set -uo pipefail
# Repair command lookup before invoking any external command.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
hash -r
if (($#)); then
    echo 'This launcher only supports interactive selection. Run: sudo bash run_all_services.sh' >&2
    exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/service_helpers/distribution.sh"
load_distribution || exit 1
source "$SCRIPT_DIR/service_helpers/task_paths.sh"
source "$SCRIPT_DIR/service_helpers/critical_services.sh"
load_critical_services "$SCRIPT_DIR/input/critical_services.txt" || exit 1

# Reconcile first; configure selected services; apply the firewall last.
ORDER=(svc ssh apache2 vsftpd bind9 mysql postfix sendmail samba nginx openvpn wordpress joomla sssd dhcpd nfs avahi cups snmpd fail2ban chrony ntpd acpid smartd rsyslog ufw)
declare -A SCRIPT_MAP=(
    [sssd]=services/sssd.sh
    [dhcpd]=services/dhcpd.sh
    [nfs]=services/nfs-server.sh
    [avahi]=services/avahi.sh
    [cups]=services/cupsd.sh
    [snmpd]=services/snmpd.sh
    [fail2ban]=services/extended/fail2ban.sh
    [chrony]=services/extended/chrony.sh
    [ntpd]=services/extended/ntpd.sh
    [acpid]=services/extended/acpid.sh
    [smartd]=services/extended/smartd.sh
    [rsyslog]=services/extended/rsyslog.sh

    [svc]=services/reconcile.sh
    [bind9]=services/bind9.sh
    [mysql]=services/mysql.sh
    [postfix]=services/postfix.sh
    [sendmail]=services/sendmail.sh
    [samba]=services/samba.sh
    [nginx]=services/nginx.sh
    [openvpn]=services/openvpn.sh
    [wordpress]=services/wordpress.sh
    [joomla]=services/joomla.sh
    [ssh]=services/ssh.sh
    [apache2]=services/apache2.sh
    [vsftpd]=services/vsftpd.sh
    [ufw]=services/ufw.sh
)
declare -A DESCRIPTION=(
    [sssd]='Check installed sssd configuration and permissions'
    [dhcpd]='Check installed dhcpd configuration and permissions'
    [nfs]='Check installed nfs configuration and permissions'
    [avahi]='Check installed avahi configuration and permissions'
    [cups]='Check installed cups configuration and permissions'
    [snmpd]='Check installed snmpd configuration and permissions'
    [fail2ban]='Check installed fail2ban configuration and permissions'
    [chrony]='Check installed chrony configuration and permissions'
    [ntpd]='Check installed ntpd configuration and permissions'
    [acpid]='Check installed acpid configuration and permissions'
    [smartd]='Check installed smartd configuration and permissions'
    [rsyslog]='Check installed rsyslog configuration and permissions'

    [svc]='Disable unlisted managed services'
    [bind9]='Configure BIND DNS'
    [mysql]='Configure existing MySQL/MariaDB or install MariaDB'
    [postfix]='Configure Postfix'
    [sendmail]='Configure Sendmail'
    [samba]='Configure Samba shares/domain service'
    [nginx]='Configure Nginx'
    [openvpn]='Configure existing OpenVPN profiles'
    [wordpress]='Protect existing WordPress installations'
    [joomla]='Protect existing Joomla installations'
    [ssh]='Install/configure SSH'
    [apache2]='Install/configure Apache'
    [vsftpd]='Install/configure FTP/FTPS'
    [ufw]='Configure firewall for critical services'
)
# The catalog varies; selection, resume, dependencies and failure handling do not.
FIREWALL_KEY=ufw
SERVICE_KEYS=(ssh apache2 vsftpd bind9 mysql postfix sendmail samba nginx openvpn wordpress joomla sssd dhcpd nfs avahi cups snmpd ufw)
if [[ "$CP_DISTRO" == freebsd ]]; then
    ORDER=(svc ssh apache2 vsftpd bind9 mysql postfix sendmail samba nginx openvpn wordpress joomla pf)
    SERVICE_KEYS=(ssh apache2 vsftpd bind9 mysql postfix sendmail samba nginx openvpn wordpress joomla pf)
    FIREWALL_KEY=pf
    SCRIPT_MAP[pf]=platforms/FreeBSD/services/pf.sh
    DESCRIPTION[pf]='Configure PF firewall for critical services'
    # Fail before doing any work for services without a native implementation.
    for key in "${!SCRIPT_MAP[@]}"; do
        keep=0
        for item in "${ORDER[@]}"; do [[ "$key" != "$item" ]] || keep=1; done
        ((keep)) || unset 'SCRIPT_MAP[$key]'
    done
    for key in "${CRITICAL_SERVICES[@]}"; do
        [[ -n "${SCRIPT_MAP[$key]:-}" ]] || { echo "Unsupported FreeBSD critical service: $key" >&2; exit 1; }
    done
fi
resolve_task_paths

# Store task keywords as data, never as executable shell code.
STATE_FILE="$SCRIPT_DIR/.run_all_services_status"
[[ "$CP_DISTRO" != freebsd ]] || STATE_FILE+=.freebsd
[[ ! -L "$STATE_FILE" && ( ! -e "$STATE_FILE" || -f "$STATE_FILE" ) ]] || {
    echo "Refusing unsafe state file: $STATE_FILE" >&2; exit 1;
}
declare -A COMPLETED=()
if [[ -e "$STATE_FILE" ]]; then
    [[ -r "$STATE_FILE" ]] || { echo "Cannot read $STATE_FILE" >&2; exit 1; }
    while IFS= read -r saved_key || [[ -n "$saved_key" ]]; do
        for key in "${ORDER[@]}"; do
            [[ "$saved_key" != "$key" ]] || COMPLETED["$key"]=1
        done
    done < "$STATE_FILE"
fi
save_status() {
    local temporary key
    temporary=$(mktemp "$STATE_FILE.XXXXXX") || return 1
    if ! (
        for key in "${ORDER[@]}"; do
            if [[ -n "${COMPLETED[$key]:-}" ]]; then printf '%s\n' "$key"; fi
        done
    ) > "$temporary" || ! mv -f -- "$temporary" "$STATE_FILE"; then
        rm -f -- "$temporary"
        return 1
    fi
}

declare -A TASK_STATUS=()
for key in "${ORDER[@]}"; do
    TASK_STATUS["$key"]=not_run
    [[ -z "${COMPLETED[$key]:-}" ]] || TASK_STATUS["$key"]=ran
    if [[ "$key" != svc && "${SCRIPT_MAP[$key]}" != services/extended/* ]] && ! critical_service "$key"; then
        TASK_STATUS["$key"]='N/a'
    fi
done
show_task_status() {
    local key
    for key in "${ORDER[@]}"; do
        printf '%-8s %-8s %s\n' "$key" "${TASK_STATUS[$key]}" "${DESCRIPTION[$key]}"
    done
}
show_task_status
printf 'Critical services: %s\n' "${CRITICAL_SERVICES[*]:-none}"
read -r -p "Enter service keywords, 'auto' for critical services, 'all', or Enter to resume: " -a INPUT || {
    echo 'No selection received.' >&2; exit 1;
}
declare -A SELECTED=()
RESUME=0
if ((${#INPUT[@]} == 0)); then
    RESUME=1
    for key in "${ORDER[@]}"; do
        [[ "${TASK_STATUS[$key]}" != not_run ]] || SELECTED["$key"]=1
    done
fi
for key in "${INPUT[@]}"; do
    case "$key" in pf|ufw) key=$FIREWALL_KEY ;; apache24) key=apache2 ;; esac
    case "$key" in openssh|sshd) key=ssh ;; crony|chronyd) key=chrony ;; ntp|ntpsec) key=ntpd ;; nfs-server|nfs-kernel-server) key=nfs ;; cupsd) key=cups ;; avahi-daemon) key=avahi ;; snmp) key=snmpd ;; mariadb) key=mysql ;; smb) key=samba ;; named|bind) key=bind9 ;; wp) key=wordpress ;; esac
    case "$key" in
        auto|auto_run)
            for item in "${CRITICAL_SERVICES[@]}"; do SELECTED["$item"]=1; done ;;
        all)
            for item in "${ORDER[@]}"; do
                SELECTED["$item"]=1
            done ;;
        *)
            [[ -n "${SCRIPT_MAP[$key]:-}" ]] || { echo "Unknown task: $key" >&2; exit 1; }
            SELECTED["$key"]=1 ;;
    esac
done
# Skip every unlisted service, including UFW, even when explicitly selected.
for key in "${SERVICE_KEYS[@]}"; do
    if [[ -n "${SELECTED[$key]:-}" ]]; then
        if ! critical_service "$key"; then
            echo "Skipping ${SCRIPT_MAP[$key]}: not listed in input/critical_services.txt."
            unset 'SELECTED[$key]'
        elif critical_service "$FIREWALL_KEY"; then
            SELECTED[$FIREWALL_KEY]=1
        fi
    fi
done
# UFW needs configured, running critical services to discover the actual ports.
if [[ -n "${SELECTED[$FIREWALL_KEY]:-}" ]]; then
    for key in "${CRITICAL_SERVICES[@]}"; do
        if ((RESUME == 0)) || [[ "${TASK_STATUS[$key]}" != ran ]]; then
            SELECTED["$key"]=1
        fi
    done
fi
# CMS task selection also selects the effective web/database dependencies.
if [[ -n "${SELECTED[wordpress]:-}${SELECTED[joomla]:-}" ]]; then
    for key in apache2 nginx mysql; do
        critical_service "$key" && SELECTED["$key"]=1
    done
fi
# Reconcile after validating all user input, even on resume or an empty selection.
SELECTED[svc]=1
SCRIPTS=()
for key in "${ORDER[@]}"; do
    [[ -n "${SELECTED[$key]:-}" ]] || continue
    script=${SCRIPT_MAP[$key]}
    [[ -f "$SCRIPT_DIR/$script" ]] || { echo "Missing script: $script" >&2; exit 1; }
    SCRIPTS+=("$script")
done
printf 'Selected: %s\n' "${SCRIPTS[@]}"
if ((${#SCRIPTS[@]} == 0)); then echo 'No eligible scripts selected.'; exit 0; fi
[[ $(id -u) == 0 ]] || { echo 'Run with sudo: sudo bash run_all_services.sh' >&2; exit 1; }
require_launcher_platform || exit 1
cd "$SCRIPT_DIR" || exit 1
source "$SCRIPT_DIR/logging.sh"
init_logging
# Do not proceed with other changes if service disabling could not complete.
{
    unset 'COMPLETED[svc]'
    TASK_STATUS[svc]=not_run
    save_status || exit 1
    if ! bash "$SCRIPT_DIR/services/reconcile.sh"; then
        log 'FAILED service policy; remaining tasks were not run'
        exit 1
    fi
    COMPLETED[svc]=1
    TASK_STATUS[svc]=ran
    save_status || exit 1
    if ((${#SCRIPTS[@]} == 1)); then log "Service policy complete; no other tasks selected"; exit 0; fi
}
declare -A RESULTS=()
FAILED=0
service_failed=0
for script in "${SCRIPTS[@]}"; do
    if [[ "$script" == services/reconcile.sh ]]; then RESULTS["$script"]=PASS; continue; fi
    if [[ "$script" == "${SCRIPT_MAP[$FIREWALL_KEY]}" && "$service_failed" == 1 ]]; then
        unset 'COMPLETED[$FIREWALL_KEY]'
        TASK_STATUS[$FIREWALL_KEY]=not_run
        save_status || { echo "Cannot save task status to $STATE_FILE" >&2; exit 1; }
        RESULTS["$script"]='SKIPPED: required service failed'
        log "SKIPPED $script because a required service failed"
        FAILED=$((FAILED+1))
        continue
    fi
    for key in "${ORDER[@]}"; do
        [[ "${SCRIPT_MAP[$key]}" != "$script" ]] || break
    done
    # Clear previous success before a rerun so failure or interruption is retryable.
    unset 'COMPLETED[$key]'
    TASK_STATUS["$key"]=not_run
    save_status || { echo "Cannot save task status to $STATE_FILE" >&2; exit 1; }
    log "RUN $script"
    if bash "$SCRIPT_DIR/$script"; then
        RESULTS["$script"]=PASS
        COMPLETED["$key"]=1
        TASK_STATUS["$key"]=ran
        save_status || { echo "Cannot save task status to $STATE_FILE" >&2; exit 1; }
        log "PASS $script"
    else
        status=$?
        RESULTS["$script"]="FAIL (exit $status)"
        log "FAILED $script (exit $status)"
        FAILED=$((FAILED+1))
        service_failed=1
    fi
done
for script in "${SCRIPTS[@]}"; do printf '%-45s %s\n' "$script" "${RESULTS[$script]}"; done
printf '\nTask status:\n'
show_task_status
((FAILED == 0))
