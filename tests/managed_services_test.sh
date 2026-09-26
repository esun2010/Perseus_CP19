#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/service_helpers/managed_services.sh"
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
log() { printf '%s\n' "$*" >> "$TEMP/log"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
printf 'wp\nmariadb\nnginx\nsmb\nnamed\n' > "$TEMP/list"
load_critical_services "$TEMP/list"
[[ "${CRITICAL_SERVICES[*]}" == 'wordpress mysql nginx samba bind9' ]] || fail aliases
printf 'wordpress\n' > "$TEMP/list"
load_critical_services "$TEMP/list"
critical_service nginx && fail 'implicit web dependency'
critical_service mysql && fail 'implicit database dependency'
discover_sites() { fail 'CMS should skip without a critical web server'; }
configure_cms wordpress
for value in '' $'postfix\nsendmail' $'none\nnginx' 'nginx;touch nope'; do
    printf '%s\n' "$value" > "$TEMP/list"
    if load_critical_services "$TEMP/list" 2>/dev/null; then fail 'unsafe list accepted'; fi
done
# Shared policy is exercised with all external operations replaced by fixtures.
discover_sites() { SITES=(); }
installed_server_packages() { if [[ ! -e "$TEMP/removed" ]]; then printf 'nginx\npostfix\n'; else echo nginx; fi; }
package_family() { case "$1" in nginx|postfix) echo "$1";; *) return 1;; esac; }
managed_units() { printf 'nginx\npostfix\n'; }
unit_family() { package_family "$1"; }
check_removal_plan() { [[ "${REMOVE_PACKAGES[*]}" == postfix ]]; }
disable_managed_unit() { echo "$1" >> "$TEMP/stopped"; }
remove_server_packages() { touch "$TEMP/removed"; }
CRITICAL_SERVICES=(nginx)
reconcile_managed_services
[[ "$(cat "$TEMP/stopped")" == postfix ]] || fail 'critical daemon stopped'
rm "$TEMP/removed" "$TEMP/stopped"
check_removal_plan() { return 1; }
if reconcile_managed_services; then fail 'unsafe removal plan accepted'; fi
[[ ! -e "$TEMP/stopped" && ! -e "$TEMP/removed" ]] || fail 'mutation before preflight'
# Restore functions and verify real filesystem discovery under a temporary path.
source "$ROOT/service_helpers/managed_services.sh"
log() { :; }
mkdir -p "$TEMP/site/child"
touch "$TEMP/site/wp-settings.php" "$TEMP/site/child/wp-settings.php"
SITES=(); add_site wordpress "$TEMP/site"
[[ "${SITES[0]}" == "wordpress $TEMP/site" ]] || fail discovery
ln -s "$TEMP/site" "$TEMP/link"
if add_site wordpress "$TEMP/link"; then fail 'symlink root accepted'; fi
if add_site wordpress /var; then fail 'shared root accepted'; fi
# Firewall includes only matching public managed listeners and correct protocols.
source "$ROOT/service_helpers/managed_firewall.sh"
native_managed_listeners() { printf 'tcp 8443 nginx\nudp 53 named\ntcp 3306 mariadbd\ntcp 9000 unrelated\n'; }
CRITICAL_SERVICES=(nginx bind9); rules=(); append_managed_firewall_rules
[[ " ${rules[*]} " == *' 8443/tcp '* && " ${rules[*]} " == *' 53/udp '* && ${#rules[@]} == 2 ]] || fail 'firewall selection'
printf 'PASS managed service aliases, CMS stack policy, removal preflight, critical preservation, path safety, firewall listeners\n'

# Exercise each native dependency gate with fake package-manager output.
source "$ROOT/service_helpers/managed_platform.sh"
CRITICAL_SERVICES=(nginx)
if [[ "$MANAGED_PLATFORM" == linux ]]; then
    REMOVE_PACKAGES=(postfix)
    apt-get() { printf '%s\n' "$PLAN"; }
    PLAN='Purg postfix [1.0]'; check_removal_plan
    PLAN='Remv nginx [1.0]'
    if check_removal_plan; then fail 'critical dependency removal accepted'; fi
    PLAN='Remv unrelated [1.0]'
    if check_removal_plan; then fail 'unrelated dependency removal accepted'; fi
    PLAN='Inst unrelated (1.0)'
    if check_removal_plan; then fail 'unexpected installation accepted'; fi
else
    REMOVE_PACKAGES=(postfix)
    pkg() { if [[ "$1" == query ]]; then printf '%s\n' "$DEPENDENT"; else return 0; fi; }
    DEPENDENT=''; check_removal_plan
    DEPENDENT=nginx
    if check_removal_plan; then fail 'critical dependency removal accepted'; fi
    DEPENDENT=unrelated
    if check_removal_plan; then fail 'unrelated dependency removal accepted'; fi
fi
printf 'PASS native package removal dependency gates\n'
