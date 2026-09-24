#!/usr/bin/env bash
set -uo pipefail
if (($#)); then
    echo 'This launcher only supports interactive selection. Run: sudo bash run_all.sh' >&2
    exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/critical_services.sh"
load_critical_services "$SCRIPT_DIR/critical_services.txt" || exit 1

# General tasks first, required services next, firewall last.
ORDER=(ker log pol usr adm mp3 pkg cra per ssh apache2 vsftpd ufw)
declare -A SCRIPT_MAP=(
    [ker]=misc/kernel.sh 
    [log]=misc/login.sh
    [pol]=password_management/pwd_policy.sh
    [usr]=user_management/user_management.sh
    [adm]=password_management/reset_admin_pwd.sh
    [mp3]=rm_stuff/rm_mp3+.sh 
    [pkg]=rm_stuff/bad_pkg.sh
    [cra]=rm_stuff/pwd_cracking_search.sh 
    [per]=misc/file_permissions.sh
    [ssh]=services/ssh.sh 
    [apache2]=services/apache2.sh
    [vsftpd]=services/vsftpd.sh 
    [ufw]=services/ufw.sh
)
declare -A DESCRIPTION=(
    [ker]='Kernel settings' 
    [log]='Guest login settings'
    [pol]='Password policy' 
    [usr]='User/admin management'
    [adm]='Reset administrator passwords' 
    [mp3]='Remove MP3/MOV/MP4 files'
    [pkg]='Review and remove packages' 
    [cra]='Search for password crackers'
    [per]='File permissions' 
    [ssh]='Install/configure SSH'
    [apache2]='Install/configure Apache' 
    [vsftpd]='Install/configure FTP/FTPS'
    [ufw]='Configure firewall for critical services'
)
for key in "${ORDER[@]}"; do
    note=''
    if [[ "${SCRIPT_MAP[$key]}" == services/* ]] && ! critical_service "$key"; then
        note=' [skipped: not critical]'
    fi
    printf '%-8s %s%s\n' "$key" "${DESCRIPTION[$key]}" "$note"
done
printf 'Critical services: %s\n' "${CRITICAL_SERVICES[*]:-none}"
read -r -p "Enter script keywords (space-separated), or 'all': " -a INPUT || {
    echo 'No selection received.' >&2; exit 1;
}
((${#INPUT[@]})) || { echo 'No tasks selected.' >&2; exit 1; }
declare -A SELECTED=()
for key in "${INPUT[@]}"; do
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
for key in ssh apache2 vsftpd ufw; do
    if [[ -n "${SELECTED[$key]:-}" ]]; then
        if ! critical_service "$key"; then
            echo "Skipping ${SCRIPT_MAP[$key]}: not listed in critical_services.txt."
            unset 'SELECTED[$key]'
        elif critical_service ufw; then
            SELECTED[ufw]=1
        fi
    fi
done
# UFW needs configured, running critical services to discover the actual ports.
if [[ -n "${SELECTED[ufw]:-}" ]]; then
    for key in "${CRITICAL_SERVICES[@]}"; do SELECTED["$key"]=1; done
fi
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
declare -A RESULTS=()
FAILED=0
service_failed=0
for script in "${SCRIPTS[@]}"; do
    if [[ "$script" == services/ufw.sh && "$service_failed" == 1 ]]; then
        RESULTS["$script"]='SKIPPED: required service failed'
        log "SKIPPED $script because a required service failed"
        FAILED=$((FAILED+1))
        continue
    fi
    log "RUN $script"
    if bash "$SCRIPT_DIR/$script"; then
        RESULTS["$script"]=PASS
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
((FAILED == 0))
