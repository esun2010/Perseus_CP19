#!/usr/bin/env bash
# Shared policy for the explicitly managed service families.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/service_common.sh"
source "$REPO_DIR/service_helpers/managed_platform.sh"

require_regular_config() {
    [[ "$1" == /* && -f "$1" && ! -L "$1" ]] || {
        log "FAILED: existing regular configuration required: $1"; return 1;
    }
}

add_site() {
    local app="$1" path="$2" resolved item
    [[ -d "$path" && ! -L "$path" ]] || { log "FAILED: invalid site directory $path"; return 1; }
    resolved=$(realpath "$path") || return 1
    [[ "$resolved" == "$path" ]] || { log "FAILED: use canonical site path $resolved"; return 1; }
    case "$path" in /|/etc|/usr|/usr/local|/var|/var/www|/usr/local/www|/home|/srv|/opt) log "FAILED: shared parent cannot be a managed site: $path"; return 1;; esac
    case "$app" in
        wordpress) [[ -f "$path/wp-settings.php" ]] || return 1 ;;
        joomla) [[ -f "$path/administrator/manifests/files/joomla.xml" ]] || return 1 ;;
        *) return 1 ;;
    esac
    for item in "${SITES[@]}"; do [[ "$item" == "$app $path" ]] && return 0; done
    SITES+=("$app $path")
}

discover_sites() {
    SITES=()
    local base listing marker app path extra line other otherapp otherpath
    for base in /var/www /usr/share/wordpress /usr/local/www; do
        [[ -d "$base" && ! -L "$base" ]] || continue
        listing=$(find -P "$base" -xdev -type f \( -name wp-settings.php -o -path '*/administrator/manifests/files/joomla.xml' \) -print) || return 1
        while IFS= read -r marker; do
            [[ -n "$marker" ]] || continue
            if [[ "$marker" == */wp-settings.php ]]; then app=wordpress; path=${marker%/wp-settings.php}
            else app=joomla; path=${marker%/administrator/manifests/files/joomla.xml}; fi
            add_site "$app" "$path" || return 1
        done <<< "$listing"
    done
    if [[ -f "$REPO_DIR/input/web_apps.txt" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line=${line%%#*}; read -r app path extra <<< "$line"
            [[ -n "$app" ]] || continue
            [[ -n "$path" && -z "$extra" ]] || { log 'FAILED: invalid web_apps.txt entry'; return 1; }
            add_site "$app" "$path" || return 1
        done < "$REPO_DIR/input/web_apps.txt"
    fi
    # Never disable a parent tree containing another, critical application.
    for line in "${SITES[@]}"; do
        app=${line%% *}; path=${line#* }
        critical_service "$app" && continue
        for other in "${SITES[@]}"; do
            otherapp=${other%% *}; otherpath=${other#* }
            if critical_service "$otherapp" && [[ "$otherpath" == "$path" || "$otherpath" == "$path/"* ]]; then
                log "FAILED: disabling $path overlaps critical $otherpath"; return 1
            fi
        done
    done
}

# CMS applications have no independent boot service. Deny traversal of their
# document roots, saving the original mode for restoration when made critical.
set_site_enabled() {
    local path="$1" enabled="$2" state="/var/lib/cyberpatriot/disabled-sites$1.mode" mode
    [[ ! -L "$state" ]] || return 1
    if [[ "$enabled" == yes ]]; then
        [[ -f "$state" ]] || return 0
        read -r mode < "$state"
        [[ "$mode" =~ ^[0-7]{1,4}$ ]] || return 1
        backup_system_paths "$path" "$state" || return 1
        chmod "$mode" "$path" || return 1
        rm -- "$state" || return 1
        log "RESTORED critical site access: $path"
    else
        if [[ -f "$state" ]]; then
            if [[ "$MANAGED_PLATFORM" == linux ]]; then mode=$(stat -c '%a' "$path")
            else mode=$(stat -f '%Lp' "$path"); fi
            [[ "$mode" != 0 ]] || return 0
            backup_system_paths "$path" || return 1
            chmod 000 "$path"; return $?
        fi
        if [[ "$MANAGED_PLATFORM" == linux ]]; then mode=$(stat -c '%a' "$path")
        else mode=$(stat -f '%Lp' "$path"); fi
        backup_system_paths "$path" "$state" || return 1
        (umask 077; mkdir -p "${state%/*}" && printf '%s\n' "$mode" > "$state") || return 1
        chmod 000 "$path" || return 1
        log "DISABLED site access, retained all files: $path"
    fi
}

reconcile_managed_services() {
    local family units unit site app path
    units=$(managed_units) || return 1
    discover_sites || return 1
    while IFS= read -r unit; do
        family=$(unit_family "$unit") || continue
        critical_service "$family" || disable_managed_unit "$unit" || return 1
    done <<< "$units"
    for site in "${SITES[@]}"; do
        app=${site%% *}; path=${site#* }
        if critical_service "$app"; then set_site_enabled "$path" yes || return 1
        else set_site_enabled "$path" no || return 1; fi
    done
    log 'VERIFIED unlisted services disabled; packages and site files retained'
}

configure_cms() {
    local key="$1" site path config found=0
    if ! critical_service apache2 && ! critical_service nginx; then
        log "SKIPPED $key: neither Apache nor Nginx is critical"; return 0
    fi
    discover_sites || return 1
    for site in "${SITES[@]}"; do
        [[ "${site%% *}" == "$key" ]] || continue
        path=${site#* }; found=1
        if [[ "$key" == wordpress ]]; then
            config="$path/wp-config.php"
            [[ -e "$config" ]] || config="$(dirname "$path")/wp-config.php"
        else config="$path/configuration.php"; fi
        config=$(realpath "$config") || return 1
        require_regular_config "$config" || return 1
        command -v php >/dev/null || { log 'FAILED: PHP CLI required to validate existing CMS configuration'; return 1; }
        php -n -l "$config" >/dev/null || return 1
        # Preserve application ownership; remove access by unrelated users.
        secure_path "$config" 640 "$(cms_owner "$config")" "$(cms_group "$config")" || return 1
        log "VERIFIED $key configuration permissions and PHP syntax: $path"
    done
    ((found)) || { log "FAILED: no existing $key installation found; install the scenario's site or add its path to input/web_apps.txt"; return 1; }
}

managed_main() {
    local key="$1"; shift
    (($# == 0)) || { echo 'This script accepts no arguments.' >&2; return 1; }
    service_init
    load_critical_services "$REPO_DIR/input/critical_services.txt" || return 1
    reconcile_managed_services || return 1
    [[ "$key" != reconcile ]] || return 0
    if ! critical_service "$key"; then log "DISABLED unlisted $key"; return 0; fi
    case "$key" in
        wordpress|joomla) configure_cms "$key" ;;
        *) local status=0; configure_native_service "$key" || status=$?
           if ((status == 3)); then log "SKIPPED $key: native implementation unavailable"; return 0; fi
           return "$status" ;;
    esac
}
