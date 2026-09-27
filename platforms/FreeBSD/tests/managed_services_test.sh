#!/usr/bin/env bash
set -euo pipefail
CP_DISTRO=freebsd
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
uname() { echo FreeBSD; }
source "$ROOT/../../service_helpers/managed_services.sh"
unset -f uname
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
log() { :; }
fail() { echo "FAIL: $*" >&2; exit 1; }
printf 'wp\nmariadb\nnginx\nsmb\nnamed\n' > "$TEMP/list"
load_critical_services "$TEMP/list"
[[ "${CRITICAL_SERVICES[*]}" == 'wordpress mysql nginx samba bind9' ]] || fail aliases
printf 'wordpress\n' > "$TEMP/list"; load_critical_services "$TEMP/list"
critical_service nginx && fail 'implicit web dependency'
discover_sites() { fail 'CMS should skip without critical web server'; }
configure_cms wordpress
for value in '' $'postfix\nsendmail' $'none\nnginx'; do
    printf '%s\n' "$value" > "$TEMP/list"
    if load_critical_services "$TEMP/list" 2>/dev/null; then fail 'unsafe list accepted'; fi
done
discover_sites() { SITES=('wordpress /fixture/wp' 'joomla /fixture/joomla'); }
managed_units() { printf 'nginx\npostfix\n'; }
unit_family() { echo "$1"; }
disable_managed_unit() { echo "disable $1" >> "$TEMP/calls"; }
set_site_enabled() { echo "site $*" >> "$TEMP/calls"; }
# Tripwires: policy must never query or remove packages/site trees.
installed_server_packages() { fail 'policy queried packages'; }
remove_server_packages() { fail 'policy removed packages'; }
remove_site_tree() { fail 'policy deleted site'; }
CRITICAL_SERVICES=(nginx wordpress)
reconcile_managed_services
[[ "$(cat "$TEMP/calls")" == $'disable postfix\nsite /fixture/wp yes\nsite /fixture/joomla no' ]] || fail policy
source "$ROOT/service_helpers/managed_platform.sh"
backup_system_paths() { echo backup >> "$TEMP/native"; }
if [[ "$MANAGED_PLATFORM" == linux ]]; then
    systemctl() {
        printf '%s\n' "$*" >> "$TEMP/native"
        case "$1" in is-active) return 3;; is-enabled) echo masked;; esac
    }
    disable_managed_unit nginx.service
    grep -q '^disable --now nginx.service$' "$TEMP/native"
    grep -q '^mask nginx.service$' "$TEMP/native"
    grep -q '^is-enabled nginx.service$' "$TEMP/native"
else
    service() { printf '%s\n' "$*" >> "$TEMP/native"; [[ "$2" != onestatus ]]; }
    # service -e takes one argument.
    service() { printf '%s\n' "$*" >> "$TEMP/native"; [[ "${2:-}" != onestatus ]]; }
    set_rc_value() { printf '%s\n' "$*" >> "$TEMP/native"; }
    disable_managed_unit mysql-server
    grep -q '^mysql_enable=NO$' "$TEMP/native"
    grep -q '^-e$' "$TEMP/native"
fi
source "$ROOT/../../service_helpers/managed_firewall.sh"
native_managed_listeners() { printf 'tcp 8443 nginx\nudp 53 named\ntcp 3306 mariadbd\n'; }
CRITICAL_SERVICES=(nginx bind9); rules=(); append_managed_firewall_rules
[[ ${#rules[@]} == 2 ]] || fail firewall
printf 'PASS service policy: retained packages/sites, critical preservation, persistent native disable, CMS stack, firewall\n'
