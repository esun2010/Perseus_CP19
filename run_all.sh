#!/bin/bash
set -uo pipefail
# Repair command lookup before invoking any external command.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
hash -r
if (($#)); then
    echo 'This launcher only supports interactive selection. Run: sudo bash run_all.sh' >&2
    exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/service_helpers/critical_services.sh"
load_critical_services "$SCRIPT_DIR/input/critical_services.txt" || exit 1

# Collect malware indicators before cleanup; required services next, firewall last.
ORDER=(svc mal ker log pol usr adm mp3 pkg per ssh apache2 vsftpd bind9 mysql postfix sendmail samba nginx openvpn wordpress joomla ufw)
declare -A SCRIPT_MAP=(
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
    [ker]=misc/kernel.sh
    [log]=misc/login.sh
    [pol]=password_management/pwd_policy.sh
    [usr]=user_management/user_management.sh
    [adm]=password_management/reset_admin_pwd.sh
    [mp3]=rm_stuff/rm_mp3+.sh
    [pkg]=rm_stuff/bad_pkg.sh
    [mal]=rm_stuff/malware_search.sh
    [per]=misc/file_permissions.sh
    [ssh]=services/ssh.sh
    [apache2]=services/apache2.sh
    [vsftpd]=services/vsftpd.sh
    [ufw]=services/ufw.sh
)
declare -A DESCRIPTION=(
    [svc]='Disable unlisted managed services (always runs)'
    [bind9]='Configure BIND DNS'
    [mysql]='Configure existing MySQL/MariaDB or install MariaDB'
    [postfix]='Configure Postfix'
    [sendmail]='Configure Sendmail'
    [samba]='Configure Samba shares/domain service'
    [nginx]='Configure Nginx'
    [openvpn]='Configure existing OpenVPN profiles'
    [wordpress]='Protect existing WordPress installations'
    [joomla]='Protect existing Joomla installations'
    [ker]='Kernel settings'
    [log]='Guest login settings'
    [pol]='Password policy'
    [usr]='User/admin management'
    [adm]='Reset administrator passwords'
    [mp3]='Remove MP3/MOV/MP4 files'
    [pkg]='Review and remove packages'
    [mal]='Scan malware, cracking tools, cron and backdoors'
    [per]='File permissions'
    [ssh]='Install/configure SSH'
    [apache2]='Install/configure Apache'
    [vsftpd]='Install/configure FTP/FTPS'
    [ufw]='Configure firewall for critical services'
)
# Store task keywords as data, never as executable shell code.
STATE_FILE="$SCRIPT_DIR/.run_all_status"
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
    if [[ "$key" != svc && "${SCRIPT_MAP[$key]}" == services/* ]] && ! critical_service "$key"; then
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
read -r -p "Enter keywords, 'all' to rerun all, or press Enter to resume: " -a INPUT || {
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
    [[ "$key" != cra ]] || key=mal # Backward-compatible selection alias.
    case "$key" in mariadb) key=mysql ;; smb) key=samba ;; named|bind) key=bind9 ;; wp) key=wordpress ;; esac
    case "$key" in
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
for key in ssh apache2 vsftpd bind9 mysql postfix sendmail samba nginx openvpn wordpress joomla ufw; do
    if [[ -n "${SELECTED[$key]:-}" ]]; then
        if ! critical_service "$key"; then
            echo "Skipping ${SCRIPT_MAP[$key]}: not listed in input/critical_services.txt."
            unset 'SELECTED[$key]'
        elif critical_service ufw; then
            SELECTED[ufw]=1
        fi
    fi
done
# UFW needs configured, running critical services to discover the actual ports.
if [[ -n "${SELECTED[ufw]:-}" ]]; then
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
[[ $(id -u) == 0 ]] || { echo 'Run with sudo: sudo bash run_all.sh' >&2; exit 1; }
cd "$SCRIPT_DIR" || exit 1
source "$SCRIPT_DIR/logging.sh"
init_logging
# Initial repairs always precede service policy, upgrades and selected tasks.
source "$SCRIPT_DIR/service_helpers/startup_repair.sh"
startup_repair || { log "FAILED initial system repairs; tasks stopped"; exit 1; }
# Do not proceed with other changes if service disabling could not complete.
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
# Refresh package metadata before upgrading; stop if either command fails.
log "RUN sudo apt update"
if sudo apt update; then
    log "PASS sudo apt update"
else
    status=$?
    log "FAILED sudo apt update (exit $status)"
    exit "$status"
fi
backup_package_configuration || exit 1
log "RUN sudo apt upgrade"
if sudo apt upgrade; then
    log "PASS sudo apt upgrade"
else
    status=$?
    log "FAILED sudo apt upgrade (exit $status)"
    exit "$status"
fi
# Install only standard inspection utilities; never install suspect tools.
if [[ -n "${SELECTED[mal]:-}" ]]; then
    unset 'COMPLETED[mal]'
    TASK_STATUS[mal]=not_run
    save_status || { echo "Cannot save task status to $STATE_FILE" >&2; exit 1; }
    log 'Ensuring malware scan dependencies: procps iproute2 file findutils grep sed coreutils'
    backup_package_configuration || exit 1
    if ! apt-get install -y procps iproute2 file findutils grep sed coreutils; then
        log 'FAILED installing malware scan dependencies'
        exit 1
    fi
fi
declare -A RESULTS=()
FAILED=0
service_failed=0
for script in "${SCRIPTS[@]}"; do
    if [[ "$script" == services/reconcile.sh ]]; then RESULTS["$script"]=PASS; continue; fi
    if [[ "$script" == services/ufw.sh && "$service_failed" == 1 ]]; then
        unset 'COMPLETED[ufw]'
        TASK_STATUS[ufw]=not_run
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
        [[ "$script" != services/* ]] || service_failed=1
    fi
done
for script in "${SCRIPTS[@]}"; do printf '%-45s %s\n' "$script" "${RESULTS[$script]}"; done
printf '\nTask status:\n'
show_task_status
((FAILED == 0))
