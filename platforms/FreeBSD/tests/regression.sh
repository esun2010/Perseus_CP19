#!/usr/bin/env bash
# Safe regression checks: all task executions and package operations use fixtures.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/cyberpatriot-tests.XXXXXX")
trap 'rm -rf "$TEMP"' EXIT
export CP_BACKUP_ROOT="$TEMP/backups"
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

while IFS= read -r -d '' script; do bash -n "$script"; done < <(find "$ROOT" -name '*.sh' -not -path '*/.git/*' -print0)
sh -n "$ROOT/bootstrap.sh"
pass 'all shell files parse; bootstrap also parses as sh'

source "$ROOT/service_helpers/critical_services.sh"
printf 'sshd\napache24\nvsftp\nufw\nallow 8443/tcp\nallow 40000:40100/tcp\n' > "$TEMP/services"
load_critical_services "$TEMP/services"
[[ "${CRITICAL_SERVICES[*]}" == 'ssh apache2 vsftpd pf' ]] || fail 'service aliases'
[[ "${EXTRA_PORTS[*]}" == '8443/tcp 40000:40100/tcp' ]] || fail 'extra ports'
pass 'native and legacy service aliases, extra ports'
for rule in 0/tcp 65536/tcp 50:40/udp 22/icmp '22/tcp;id' '-1/tcp' ''; do
    if valid_port_rule "$rule"; then fail "accepted bad rule: $rule"; fi
done
for rule in 1/tcp 65535/udp 00022/tcp 1:65535/udp; do
    valid_port_rule "$rule" || fail "rejected valid rule: $rule"
done
printf 'none\nssh\n' > "$TEMP/services"
if load_critical_services "$TEMP/services" 2>/dev/null; then fail 'none plus service accepted'; fi
printf 'pf\nallow 22/tcp extra\n' > "$TEMP/services"
if load_critical_services "$TEMP/services" 2>/dev/null; then fail 'trailing data accepted'; fi
printf '$(touch should-not-exist)\n' > "$TEMP/services"
if load_critical_services "$TEMP/services" 2>/dev/null; then fail 'shell input accepted'; fi
pass 'invalid service lists and port rules rejected as data'

source "$ROOT/service_helpers/platform.sh"
(
    uname() { echo Linux; }
    if require_freebsd_root 2>/dev/null; then exit 1; fi
    uname() { echo FreeBSD; }
    id() { echo 1001; }
    if require_freebsd_root 2>/dev/null; then exit 1; fi
    id() { echo 0; }
    sysctl() { echo 1; }
    if require_freebsd_root 2>/dev/null; then exit 1; fi
    sysctl() { echo 0; }
    require_freebsd_root
) || fail 'platform guard'
pass 'platform guard rejects Linux, non-root, and jails'
(
    backup_package_configuration() { :; }
    pkg() {
        printf '%s\n' "$*" >> "$TEMP/packages"
        case "$*" in
            '-N') return 0 ;;
            'info -e bash') return 0 ;;
            'info -e apache24') [[ -f "$TEMP/installed" ]] ;;
            'install -y apache24') touch "$TEMP/installed" ;;
            *) return 1 ;;
        esac
    }
    ensure_packages bash apache24
    ensure_packages bash apache24
    if ensure_packages --force 2>/dev/null; then exit 1; fi
) || fail 'package helper'
[[ $(grep -c '^install -y apache24$' "$TEMP/packages") == 1 ]] || fail 'package reinstalled'
pass 'packages are installed only when absent and invalid names fail'

(
    source "$ROOT/logging.sh"
    LOG_FILE="$TEMP/audit.log"
    printf 'old setting\n' > "$TEMP/config"
    edit_config() { printf 'new setting\n' > "$TEMP/config"; }
    partial_failure() { printf 'partial setting\n' > "$TEMP/config"; return 7; }
    audit_file_change "$TEMP/config" edit_config >/dev/null
    audit_file_change "$TEMP/config" partial_failure >/dev/null && exit 1
    grep -q -- '-old setting' "$LOG_FILE"
    grep -q -- '+new setting' "$LOG_FILE"
    grep -q 'FAILED editing' "$LOG_FILE"
) || fail 'audit diff'
pass 'audit records successful and failed configuration edits'

FIXTURE="$TEMP/repo"
mkdir -p "$FIXTURE/service_helpers" "$FIXTURE/input" "$FIXTURE/services" \
    "$FIXTURE/misc" "$FIXTURE/password_management" "$FIXTURE/user_management" "$FIXTURE/rm_stuff"
cp "$ROOT/run_all.sh" "$ROOT/logging.sh" "$FIXTURE/"
printf '\nbackup_package_configuration() { :; }\n' >> "$FIXTURE/logging.sh"
cp "$ROOT/service_helpers/critical_services.sh" "$FIXTURE/service_helpers/"
cat > "$FIXTURE/service_helpers/platform.sh" <<'STUB'
require_freebsd_root() { :; }
require_commands() { :; }
pkg() { printf 'pkg %s\n' "$*" >> "$TEST_CALLS"; }
STUB
printf 'startup_repair() { printf "repair\\n" >> "$TEST_CALLS"; }\n' > "$FIXTURE/service_helpers/startup_repair.sh"
export TEST_CALLS="$TEMP/calls"
for path in misc/kernel.sh misc/login.sh password_management/pwd_policy.sh \
    user_management/user_management.sh password_management/reset_admin_pwd.sh \
    'rm_stuff/rm_mp3+.sh' rm_stuff/bad_pkg.sh rm_stuff/malware_search.sh \
    misc/file_permissions.sh services/reconcile.sh services/ssh.sh services/apache2.sh services/vsftpd.sh services/pf.sh; do
    cat > "$FIXTURE/$path" <<'STUB'
#!/usr/bin/env bash
printf 'task %s\n' "${0##*/}" >> "$TEST_CALLS"
[[ "${0##*/}" != "${FAIL_TASK:-}" ]]
STUB
done
printf 'ssh\npf\n' > "$FIXTURE/input/critical_services.txt"
printf 'ssh\n' | bash "$FIXTURE/run_all.sh" > "$TEMP/launcher.log"
grep -q '^task ssh.sh$' "$TEST_CALLS"
grep -q '^task pf.sh$' "$TEST_CALLS"
grep -q '^pf$' "$FIXTURE/.run_all_status.freebsd"
pass 'selecting SSH also configures critical PF and records completion'

: > "$TEST_CALLS"
export FAIL_TASK=ssh.sh
if printf 'ssh\n' | bash "$FIXTURE/run_all.sh" > "$TEMP/launcher.log"; then fail 'launcher hid failed service'; fi
grep -q '^task ssh.sh$' "$TEST_CALLS"
if grep -q '^task pf.sh$' "$TEST_CALLS"; then fail 'PF ran after service failure'; fi
if grep -q -E '^(pf|ssh)$' "$FIXTURE/.run_all_status.freebsd"; then fail 'failed tasks kept old success'; fi
unset FAIL_TASK
pass 'failed service blocks PF and clears stale successful state'

: > "$TEST_CALLS"
printf 'ufw\n' | bash "$FIXTURE/run_all.sh" > "$TEMP/launcher.log"
grep -q '^task pf.sh$' "$TEST_CALLS"
pass 'legacy ufw selection invokes PF'

printf 'none\n' > "$FIXTURE/input/critical_services.txt"
: > "$TEST_CALLS"
printf 'ssh pf\n' | bash "$FIXTURE/run_all.sh" > "$TEMP/launcher.log"
[[ "$(cat "$TEST_CALLS")" == $'repair\ntask reconcile.sh' ]] || fail 'ineligible setup ran'
: > "$TEST_CALLS"
if bash "$FIXTURE/run_all.sh" all > "$TEMP/launcher.log" 2>&1; then fail 'arguments accepted'; fi
[[ ! -s "$TEST_CALLS" ]] || fail 'invalid invocation caused changes'
pass 'unlisted services run only reconciliation; invalid invocation causes no changes'

printf 'all\n' | bash "$FIXTURE/run_all.sh" > "$TEMP/launcher.log"
[[ $(grep -c '^task ' "$TEST_CALLS") == 10 ]] || fail 'all did not run nine general tasks plus reconciliation'
: > "$TEST_CALLS"
printf '\n' | bash "$FIXTURE/run_all.sh" > "$TEMP/launcher.log"
[[ "$(cat "$TEST_CALLS")" == $'repair\ntask reconcile.sh' ]] || fail 'resume repeated completed tasks'
pass 'all and resume respect eligibility and saved FreeBSD progress'
printf '\n%d regression groups passed. No host hardening was run.\n' "$passed"
