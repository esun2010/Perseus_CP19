#!/usr/bin/env bash
# Safe fixtures: the launcher executes stub scripts, never host hardening.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/repo/lib" "$fixture/repo/services" "$fixture/repo/misc" \
    "$fixture/repo/password_management" "$fixture/repo/user_management" "$fixture/repo/rm_stuff"
cp "$ROOT/run_all.sh" "$ROOT/logging.sh" "$fixture/repo/"
cp "$ROOT/lib/critical_services.sh" "$fixture/repo/lib/"
source "$ROOT/lib/critical_services.sh"
printf '# comment\r\nSSHD\r\nssh\napache\nvsftp\nallow 8080/tcp\nallow 40000:40100/tcp' > "$fixture/repo/critical_services.txt"
load_critical_services "$fixture/repo/critical_services.txt"
[[ "${CRITICAL_SERVICES[*]}" == 'ssh apache2 vsftpd' ]]
[[ "${EXTRA_PORTS[*]}" == '8080/tcp 40000:40100/tcp' ]]
for rule in 0/tcp 65536/tcp 50:40/tcp '22/tcp;touch BAD' 22/sctp; do
    if valid_port_rule "$rule"; then echo "Accepted invalid rule $rule" >&2; exit 1; fi
done
for content in 'none ssh' $'none\nssh' 'unknown' 'allow 65536/tcp'; do
    printf '%s\n' "$content" > "$fixture/invalid.txt"
    if load_critical_services "$fixture/invalid.txt"; then echo 'Accepted invalid list' >&2; exit 1; fi
done
export TEST_RUNS="$fixture/runs"
for script in misc/kernel.sh misc/login.sh misc/file_permissions.sh \
    password_management/pwd_policy.sh password_management/reset_admin_pwd.sh \
    user_management/user_management.sh rm_stuff/rm_mp3+.sh rm_stuff/bad_pkg.sh \
    rm_stuff/pwd_cracking_search.sh services/ssh.sh services/apache2.sh services/vsftpd.sh services/ufw.sh; do
    cat > "$fixture/repo/$script" <<'STUB'
#!/bin/bash
printf '%s\n' "${0##*/}" >> "$TEST_RUNS"
[[ "${0##*/}" != "${FAIL_SCRIPT:-}" ]]
STUB
done
id() { echo 0; }
export -f id
# Removed command-line modes must fail without executing any task.
for option in all services --list ssh; do
    if bash "$fixture/repo/run_all.sh" "$option" > "$fixture/output" 2>&1; then
        echo "Accepted removed option $option" >&2; exit 1
    fi
done
[[ ! -e "$TEST_RUNS" ]]
printf 'ssh\napache2\nvsftpd\nufw\n' > "$fixture/repo/critical_services.txt"
printf 'ssh apache2 vsftpd ufw\n' | (cd "$fixture" && bash repo/run_all.sh) > "$fixture/output"
printf 'ssh.sh\napache2.sh\nvsftpd.sh\nufw.sh\n' > "$fixture/expected"
diff -u "$fixture/expected" "$TEST_RUNS"
: > "$TEST_RUNS"
if printf 'all\n' | FAIL_SCRIPT=apache2.sh bash "$fixture/repo/run_all.sh" > "$fixture/output"; then
    echo 'Service failure was ignored' >&2; exit 1
fi
! grep -q '^ufw.sh$' "$TEST_RUNS"
grep -q 'SKIPPED: required service failed' "$fixture/output"
: > "$TEST_RUNS"
printf 'all\n' | bash "$fixture/repo/run_all.sh" > "$fixture/output"
[[ $(wc -l < "$TEST_RUNS") == 13 ]]
[[ $(sort -u "$TEST_RUNS" | wc -l) == 13 ]]
[[ $(tail -n 1 "$TEST_RUNS") == ufw.sh ]]
printf 'none\n' > "$fixture/repo/critical_services.txt"
: > "$TEST_RUNS"
printf 'all\n' | bash "$fixture/repo/run_all.sh" > "$fixture/output"
[[ $(wc -l < "$TEST_RUNS") == 9 ]]
! grep -qE '^(ssh|apache2|vsftpd|ufw).sh$' "$TEST_RUNS"
grep -q 'skipped: not critical' "$fixture/output"
: > "$TEST_RUNS"
printf 'ssh apache2 vsftpd ufw\n' | bash "$fixture/repo/run_all.sh" > "$fixture/output"
[[ ! -s "$TEST_RUNS" ]]
printf 'ssh\n' > "$fixture/repo/critical_services.txt"
printf 'ssh ufw apache2\n' | bash "$fixture/repo/run_all.sh" > "$fixture/output"
printf 'ssh.sh\n' > "$fixture/expected"
diff -u "$fixture/expected" "$TEST_RUNS"
: > "$TEST_RUNS"
printf 'log log per\n' | bash "$fixture/repo/run_all.sh" > "$fixture/output"
printf 'login.sh\nfile_permissions.sh\n' > "$fixture/expected"
diff -u "$fixture/expected" "$TEST_RUNS"
: > "$TEST_RUNS"
for input in '' services bogus; do
    if printf '%s\n' "$input" | bash "$fixture/repo/run_all.sh" > "$fixture/output" 2>&1; then
        echo "Accepted invalid selection $input" >&2; exit 1
    fi
done
[[ ! -s "$TEST_RUNS" ]]
if bash "$fixture/repo/run_all.sh" < /dev/null > "$fixture/output" 2>&1; then
    echo 'Accepted missing input' >&2; exit 1
fi
source "$ROOT/lib/service_common.sh"
config="$fixture/config"
printf '# keep comment\nlocal_enable=NO\nlocal_enable=YES\nlisten_port=2121\n' > "$config"
set_config_values "$config" local_enable=YES anonymous_enable=NO
[[ $(grep -c '^local_enable=' "$config") == 1 ]]
grep -q '^listen_port=2121$' "$config"
cp "$config" "$fixture/expected"
set_config_values "$config" local_enable=YES anonymous_enable=NO
diff -u "$fixture/expected" "$config"
systemctl() { return 1; }
if enable_service ssh; then echo 'Failed systemctl was ignored' >&2; exit 1; fi

# Exercise the actual firewall script with stub commands and fixture configs.
cp "$ROOT/lib/service_common.sh" "$fixture/repo/lib/"
cat >> "$fixture/repo/lib/service_common.sh" <<'STUB'
service_init() { init_logging; }
install_packages() { :; }
STUB
cp "$ROOT/services/ufw.sh" "$fixture/repo/services/ufw.sh"
sed -i "s|/etc/vsftpd.conf|$fixture/vsftpd.conf|g; s|/usr/sbin/sshd|mock_sshd|g" "$fixture/repo/services/ufw.sh"
printf 'ssh\napache2\nvsftpd\nallow 3306/tcp\n' > "$fixture/repo/critical_services.txt"
printf 'listen_port=2121\npasv_min_port=40000\npasv_max_port=40100\n' > "$fixture/vsftpd.conf"
export TEST_UFW="$fixture/ufw_commands" TEST_UFW_ACTIVE="$fixture/ufw_active"
: > "$TEST_UFW"
systemctl() {
    if [[ "$*" == 'show -p MainPID --value apache2' ]]; then echo 1234;
    elif [[ "$*" == 'show -p Listen --value ssh.socket' ]]; then echo '[::]:2200 (Stream)'; fi
    return 0
}
mock_sshd() { echo 'port 2222'; }
ss() { echo 'LISTEN 0 511 *:8443 *:* users:(("apache2",pid=1234,fd=4))'; }
ufw() {
    printf '%s\n' "$*" >> "$TEST_UFW"
    if [[ "$*" == '--force enable' ]]; then touch "$TEST_UFW_ACTIVE"; fi
    if [[ "$1" == status ]]; then
        if [[ -e "$TEST_UFW_ACTIVE" ]]; then echo 'Status: active'; else echo 'Status: inactive'; fi
    fi
}
export -f systemctl mock_sshd ss ufw
SSH_CONNECTION='192.0.2.1 55000 192.0.2.2 2223' bash "$fixture/repo/services/ufw.sh" > "$fixture/output"
for rule in 3306/tcp 2222/tcp 2200/tcp 2223/tcp 8443/tcp 2121/tcp 40000:40100/tcp; do
    grep -q "^insert 1 allow $rule$" "$TEST_UFW"
done
awk '/^insert/ {if(enabled) exit 1} /^--force enable$/ {enabled=1} END {if(!enabled) exit 1}' "$TEST_UFW"
# An undiscoverable Apache listener must stop before modifying the firewall.
ss() { :; }
export -f ss
: > "$TEST_UFW"
if bash "$fixture/repo/services/ufw.sh" > "$fixture/output"; then echo 'Missing listener ignored' >&2; exit 1; fi
[[ ! -s "$TEST_UFW" ]]
echo 'Service selection and helper tests passed.'
