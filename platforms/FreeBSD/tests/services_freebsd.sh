#!/usr/bin/env bash
# Pure helpers and isolated fake PF lifecycle; never changes the host firewall.
set -euo pipefail
CP_DISTRO=freebsd
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/cyberpatriot-service-tests.XXXXXX")
trap 'rm -rf "$TEMP"' EXIT
export CP_BACKUP_ROOT="$TEMP/backups"
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
source "$ROOT/service_helpers/service_common.sh"
LOG_FILE="$TEMP/audit.log"

printf '# keep\nlisten=NO\n listen =NO\nlisten_ipv6=YES\npath=/keep/me\n' > "$TEMP/config"
set_config_values "$TEMP/config" 'listen-key=YES' >/dev/null 2>&1 && fail 'invalid key accepted'
set_config_values "$TEMP/config" listen >/dev/null 2>&1 && fail 'missing value accepted'
# Reset after intentionally probing invalid input.
printf '# keep\nlisten=NO\n listen =NO\nlisten_ipv6=YES\npath=/keep/me\n' > "$TEMP/config"
set_config_values "$TEMP/config" listen=YES background=YES
[[ $(grep -c '^listen=YES$' "$TEMP/config") == 1 ]] || fail 'duplicate settings retained'
grep -q '^listen_ipv6=YES$' "$TEMP/config"
grep -q '^# keep$' "$TEMP/config"
cp "$TEMP/config" "$TEMP/once"
set_config_values "$TEMP/config" listen=YES background=YES
cmp "$TEMP/config" "$TEMP/once"
pass 'portable configuration editing preserves comments and is idempotent'

sockstat() {
    [[ "$*" == '-46l -P tcp' ]] || return 1
    cat <<'SOCKETS'
USER COMMAND PID FD PROTO LOCAL-ADDRESS FOREIGN-ADDRESS
root sshd 123 5 tcp4 *:2222 *:*
root sshd 123 6 tcp6 [::]:2222 *:*
www httpd 444 6 tcp4 192.0.2.1:8080 *:*
www httpd 445 6 tcp6 [2001:db8::1]:8443 *:*
www httpd 446 6 tcp4 192.0.2.1:8080 *:*
root vsftpd 333 3 tcp4 *:21 *:*
root other 222 5 tcp4 *:9999 *:*
SOCKETS
}
[[ $(listening_tcp_ports sshd) == 2222 ]] || fail 'custom SSH listener'
[[ $(listening_tcp_ports httpd) == $'8080\n8443' ]] || fail 'Apache IPv4/IPv6 listeners'
[[ -z $(listening_tcp_ports absent) ]] || fail 'unrelated listeners leaked'
pass 'live FreeBSD socket ports include IPv6 and custom listeners without duplicates'

printf 'original\n' > "$TEMP/original"
backup_config "$TEMP/original" >/dev/null
printf 'changed\n' > "$TEMP/original"
restore_config "$TEMP/original" "$CONFIG_BACKUP" >/dev/null
[[ $(cat "$TEMP/original") == original ]] || fail 'configuration restoration'
pass 'configuration backups restore original contents'

(
    mock_running=no
    mock_enabled=NO
    sysrc() {
        if [[ "$1" == -l ]]; then printf '%s %s\n' "$TEMP/rc.conf" "$TEMP/rc.conf.local"; return; fi
        if [[ "$1" == -n ]]; then printf '%s\n' "$mock_enabled"
        else mock_enabled=${1#*=}; fi
    }
    service() {
        printf '%s\n' "$*" >> "$TEMP/service-calls"
        case "$2" in
            onestatus) [[ "$mock_running" == yes ]] ;;
            onereload) [[ "$mock_running" == yes ]] ;;
            onestop) mock_running=no ;;
            *) return 1 ;;
        esac
    }
    capture_service_state sshd
    [[ "$SERVICE_WAS_ENABLED" == NO && "$SERVICE_WAS_RUNNING" == no ]]
    if enable_service sshd >/dev/null; then fail "inactive service refreshed"; fi
    [[ "$mock_enabled" == YES && "$mock_running" == no ]]
    restore_service_state sshd "$SERVICE_WAS_ENABLED" "$SERVICE_WAS_RUNNING"
    [[ "$mock_enabled" == NO && "$mock_running" == no ]]
    mock_running=yes
    capture_service_state apache24
    enable_service apache24 >/dev/null
    restore_service_state apache24 "$SERVICE_WAS_ENABLED" "$SERVICE_WAS_RUNNING"
    [[ "$mock_enabled" == NO && "$mock_running" == yes ]]
) || fail 'service state restoration'
! grep -q '^sshd onestart$' "$TEMP/service-calls"
! grep -q '^sshd onestop$' "$TEMP/service-calls"
grep -q '^apache24 onereload$' "$TEMP/service-calls"
pass 'rc refresh and rollback preserve inactive services'

FIXTURE="$TEMP/repo"
mkdir -p "$FIXTURE/services" "$FIXTURE/service_helpers" "$FIXTURE/input" "$FIXTURE/etc"
# Replace only absolute /etc destinations in the copied script with fixture paths.
sed "s|/etc/|$FIXTURE/etc/|g" "$ROOT/services/pf.sh" > "$FIXTURE/services/pf.sh"
export TEST_ROOT="$ROOT" PF_FIXTURE="$FIXTURE"
printf 'pf\nallow 00443/tcp\nallow 40000:40100/tcp\n' > "$FIXTURE/input/critical_services.txt"
cp "$ROOT/../../service_helpers/managed_firewall.sh" "$ROOT/service_helpers/managed_platform.sh" "$FIXTURE/service_helpers/"
cat > "$FIXTURE/service_helpers/service_common.sh" <<'MOCKS'
source "$TEST_ROOT/service_helpers/service_common.sh"
REPO_DIR=$PF_FIXTURE
LOG_FILE="$PF_FIXTURE/audit.log"
service_init() { :; }
require_commands() { :; }
secure_path() { chmod "$2" "$1"; }
kldstat() { return 0; }
kldload() { return 0; }
listening_tcp_ports() { [[ "$1" != sshd ]] || printf '2222\n'; }
sysrc() {
    if [[ "$1" == -l ]]; then printf '%s/etc/rc.conf\n' "$PF_FIXTURE"; return; fi
    if [[ "$1" == -n ]]; then
        case "$2" in
            pf_rules) printf '%s/etc/pf.conf\n' "$PF_FIXTURE" ;;
            pf_enable) cat "$PF_FIXTURE/enabled" ;;
            *) return 1 ;;
        esac
    else printf '%s\n' "${1#*=}" > "$PF_FIXTURE/enabled"; fi
}
pfctl() {
    printf '%s\n' "$*" >> "$PF_FIXTURE/pfctl-calls"
    case "$1" in
        -s) printf 'Status: %s\n' "$(cat "$PF_FIXTURE/state")" ;;
        -nf) [[ "${FAIL_VALIDATE:-no}" != yes ]] ;;
        -f) cp "$2" "$PF_FIXTURE/runtime" ;;
        -e) [[ "${FAIL_ENABLE:-no}" != yes ]] || return 1; printf 'Enabled\n' > "$PF_FIXTURE/state" ;;
        -d) printf 'Disabled\n' > "$PF_FIXTURE/state" ;;
        *) return 1 ;;
    esac
}
MOCKS
printf 'NO\n' > "$FIXTURE/enabled"
printf 'Disabled\n' > "$FIXTURE/state"
bash "$FIXTURE/services/pf.sh" > "$TEMP/pf.log"
grep -q '^pass in proto tcp from any to self port 2222 keep state$' "$FIXTURE/runtime"
grep -q '^pass in proto tcp from any to self port 443 keep state$' "$FIXTURE/runtime"
grep -q '^pass in proto tcp from any to self port 40000:40100 keep state$' "$FIXTURE/runtime"
grep -q 'proto ipv6-icmp' "$FIXTURE/runtime"
grep -q 'port 67 to any port 68' "$FIXTURE/runtime"
grep -q 'port 547 to any port 546' "$FIXTURE/runtime"
[[ $(cat "$FIXTURE/state") == Enabled && $(cat "$FIXTURE/enabled") == YES ]]
if grep -q -- '-F' "$FIXTURE/pfctl-calls"; then fail 'PF flushed states'; fi
pass 'PF preserves live SSH ports, supports IPv6/DHCP and enables without flushing states'

cp "$FIXTURE/runtime" "$TEMP/original-policy"
: > "$FIXTURE/pfctl-calls"
if FAIL_VALIDATE=yes bash "$FIXTURE/services/pf.sh" > "$TEMP/pf.log"; then fail 'invalid PF candidate accepted'; fi
cmp "$FIXTURE/runtime" "$TEMP/original-policy"
if grep -q '^-f ' "$FIXTURE/pfctl-calls"; then fail 'invalid candidate changed active firewall'; fi
pass 'invalid PF candidate leaves live firewall untouched'

printf 'Disabled\n' > "$FIXTURE/state"
printf 'NO\n' > "$FIXTURE/enabled"
printf '\n# original marker for rollback\n' >> "$FIXTURE/etc/pf.conf"
cp "$FIXTURE/etc/pf.conf" "$TEMP/original-config"
if FAIL_ENABLE=yes bash "$FIXTURE/services/pf.sh" > "$TEMP/pf.log"; then fail 'PF enable failure hidden'; fi
cmp "$FIXTURE/etc/pf.conf" "$TEMP/original-config"
cmp "$FIXTURE/runtime" "$TEMP/original-config"
[[ $(cat "$FIXTURE/state") == Disabled && $(cat "$FIXTURE/enabled") == NO ]]
pass 'PF activation failure restores configuration, rules and boot state'

printf 'block in quick all\n' > "$FIXTURE/etc/pf.conf"
: > "$FIXTURE/pfctl-calls"
if bash "$FIXTURE/services/pf.sh" > "$TEMP/pf.log"; then fail 'unmanaged PF policy replaced'; fi
[[ $(cat "$FIXTURE/etc/pf.conf") == 'block in quick all' ]]
[[ ! -s "$FIXTURE/pfctl-calls" ]] || fail 'unmanaged PF policy altered live state'
grep -q 'Review candidate' "$TEMP/pf.log"
pass 'unmanaged PF rules stay unchanged with a reviewable candidate'
printf '\n%d service regression groups passed. No host services were changed.\n' "$passed"
