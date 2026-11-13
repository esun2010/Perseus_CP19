#!/bin/bash
set -uo pipefail
# Repair command lookup before invoking any external command.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
hash -r
if (($#)); then
    echo 'This launcher only supports interactive selection. Run: sudo bash main/run_all.sh' >&2
    exit 1
fi
MAIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$MAIN_DIR/.." && pwd)"
source "$SCRIPT_DIR/service_helpers/distribution.sh"
load_distribution || exit 1
source "$SCRIPT_DIR/service_helpers/task_paths.sh"
# CyberPatriot scoring tasks.
ORDER=(usr mp3 ker sys pol log per updates-auto pkg cpkg csvc mal)
declare -A SCRIPT_MAP=(
    [sys]=config/system_hardening.sh
    [ker]=config/kernel.sh
    [log]=config/login.sh
    [per]=config/file_permissions.sh
    [updates-auto]=config/automatic_updates.sh
    [pol]=password_management/pwd_policy.sh
    [usr]=user_management/user_management.sh
    [mp3]=rm_stuff/rm_mp3+.sh
    [pkg]=rm_stuff/bad_pkg.sh
    [mal]=rm_stuff/malware_scan.sh
    [cpkg]=compare/compare_pkgs.sh
    [csvc]=compare/compare_services.sh
)
declare -A DESCRIPTION=(
    [usr]='User Management (then User Cleanup)'
    [mp3]='Media Inventory (then Media Cleanup)'
    [ker]='Kernel Hardening'
    [sys]='System Components'
    [pol]='Password Policy'
    [log]='Guest Login'
    [per]='File Permissions'
    [updates-auto]='Daily Update Checks'
    [pkg]='Bad Packages'
    [cpkg]='Package Comparison'
    [csvc]='Service Comparison'
    [mal]='Malware Scan (ClamAV and Lynis)'
)
resolve_task_paths

# Store task keywords as data, never as executable shell code.
STATE_FILE="$MAIN_DIR/.run_all_status"
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
done
show_task_status() {
    local key
    for key in "${ORDER[@]}"; do
        printf '%-8s %-8s %s\n' "$key" "${TASK_STATUS[$key]}" "${DESCRIPTION[$key]}"
    done
}
show_task_status
read -r -p "Enter script keywords, 'auto' to run all, or press Enter to resume: " -a INPUT || {
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
    case "$key" in system_hardening|nss|openssl|grub|selinux|netfilter|iptables|dhclient) key=sys ;; esac
    case "$key" in
        auto|all)
            for item in "${ORDER[@]}"; do
                SELECTED["$item"]=1
            done ;;
        *)
            [[ -n "${SCRIPT_MAP[$key]:-}" ]] || { echo "Unknown task: $key" >&2; exit 1; }
            SELECTED["$key"]=1 ;;
    esac
done
SCRIPTS=()
for key in "${ORDER[@]}"; do
    [[ -n "${SELECTED[$key]:-}" ]] || continue
    script=${SCRIPT_MAP[$key]}
    [[ -f "$SCRIPT_DIR/$script" ]] || { echo "Missing script: $script" >&2; exit 1; }
    SCRIPTS+=("$script")
done
printf 'Selected: %s\n' "${SCRIPTS[@]}"
if ((${#SCRIPTS[@]} == 0)); then echo 'No eligible scripts selected.'; exit 0; fi
[[ $(id -u) == 0 ]] || { echo 'Run with sudo: sudo bash main/run_all.sh' >&2; exit 1; }
require_launcher_platform || exit 1
cd "$SCRIPT_DIR" || exit 1
source "$MAIN_DIR/logging.sh"
init_logging
# Initial repairs always precede upgrades and selected tasks.
source "$SCRIPT_DIR/service_helpers/startup_repair.sh"
startup_repair || { log "FAILED initial system repairs; tasks stopped"; exit 1; }
if [[ "$CP_DISTRO" == freebsd ]]; then
    require_commands pkg || exit 1
    backup_package_configuration || exit 1
    pkg -N >/dev/null 2>&1 || pkg bootstrap -y || exit 1
    log 'RUN pkg update'
    pkg update || exit 1
    backup_package_configuration || exit 1
    log 'RUN pkg upgrade'
    pkg upgrade || exit 1
else
    backup_package_configuration || exit 1
    log "RUN apt-get upgrade"
    if DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq; then
        log "PASS apt-get upgrade"
    else
        status=$?
        log "FAILED sudo apt upgrade (exit $status)"
        exit "$status"
    fi
fi
declare -A RESULTS=()
FAILED=0
for script in "${SCRIPTS[@]}"; do
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
    fi
done
for script in "${SCRIPTS[@]}"; do printf '%-45s %s\n' "$script" "${RESULTS[$script]}"; done
printf '\nTask status:\n'
show_task_status
((FAILED == 0))
