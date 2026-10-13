#!/usr/bin/env bash
# Safe fixtures only: never changes host accounts, PAM, mounts, or sysctls.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cat > "$fixture/login.conf" <<'CONF'
# Local classes must survive a default-class edit.
default|Default Class:\
    :passwd_format=sha512:\
# An embedded comment must not split a continued capability record.
    :passwordtime=365d:warnpassword=2d:\
    :umask=022:

staff:\
    :passwordtime=45d:\
    :tc=default:
root:\
    :ignorenologin:\
    :tc=default:
CONF
awk -f "$REPO/platforms/FreeBSD/password_management/login_defaults.awk" "$fixture/login.conf" > "$fixture/login.new"
grep -q '^default|Default Class:passwordtime=90d:warnpassword=7d:passwd_format=sha512:umask=022:$' "$fixture/login.new" || fail 'default capabilities'
grep -q 'passwordtime=45d' "$fixture/login.new" || fail 'custom class preservation'
grep -q 'ignorenologin' "$fixture/login.new" || fail 'root class preservation'
awk -f "$REPO/platforms/FreeBSD/password_management/login_defaults.awk" "$fixture/login.new" > "$fixture/login.second"
cmp -s "$fixture/login.new" "$fixture/login.second" || fail 'login.conf idempotence'
printf 'staff:passwordtime=45d:\n' > "$fixture/no-default"
if awk -f "$REPO/platforms/FreeBSD/password_management/login_defaults.awk" "$fixture/no-default" >/dev/null; then fail 'missing default accepted'; fi
printf 'default:umask=022:\ndefault:umask=077:\n' > "$fixture/duplicate"
if awk -f "$REPO/platforms/FreeBSD/password_management/login_defaults.awk" "$fixture/duplicate" >/dev/null; then fail 'duplicate default accepted'; fi
printf 'default:\\\n' > "$fixture/unterminated"
if awk -f "$REPO/platforms/FreeBSD/password_management/login_defaults.awk" "$fixture/unterminated" >/dev/null; then fail 'unterminated record accepted'; fi
printf 'default:passwordtime@:warnpassword@:umask=022:\n' > "$fixture/cancelled"
awk -f "$REPO/platforms/FreeBSD/password_management/login_defaults.awk" "$fixture/cancelled" > "$fixture/cancelled.new"
if grep -q 'passwordtime@\|warnpassword@' "$fixture/cancelled.new"; then fail 'cancelled capability retained'; fi
if command -v cap_mkdb >/dev/null; then
    cap_mkdb "$fixture/login.new"
    [[ -s "$fixture/login.new.db" ]] || fail 'cap_mkdb fixture compilation'
fi

cat > "$fixture/passwd" <<'PAM'
# Conventional FreeBSD passwd stack.
#password requisite pam_passwdqc.so enforce=users
password required pam_unix.so no_warn try_first_pass
PAM
awk -f "$REPO/platforms/FreeBSD/password_management/passwd_policy.awk" "$fixture/passwd" > "$fixture/passwd.new"
[[ "$(grep -c '^password requisite pam_passwdqc.so ' "$fixture/passwd.new")" == 1 ]] || fail 'required quality module'
grep -q 'min=12,12,12,12,12 max=128 random=0 .*enforce=everyone$' "$fixture/passwd.new" || fail 'password policy options'
[[ "$(grep -c '^password required pam_unix.so ' "$fixture/passwd.new")" == 1 ]] || fail 'local password module'
awk -f "$REPO/platforms/FreeBSD/password_management/passwd_policy.awk" "$fixture/passwd.new" > "$fixture/passwd.second"
cmp -s "$fixture/passwd.new" "$fixture/passwd.second" || fail 'PAM idempotence'
printf 'password required pam_ldap.so\n' > "$fixture/custom"
if awk -f "$REPO/platforms/FreeBSD/password_management/passwd_policy.awk" "$fixture/custom" >/dev/null; then fail 'unsupported PAM accepted'; fi
printf 'password sufficient pam_unix.so\n' > "$fixture/sufficient"
if awk -f "$REPO/platforms/FreeBSD/password_management/passwd_policy.awk" "$fixture/sufficient" >/dev/null; then fail 'sufficient PAM stack accepted'; fi

# Load just the pure allowlist parser, not the executable hardening script.
source <(awk '/^load_admin_allowlist\(\) \{/ { body=1 } body { print } body && /^}/ { exit }' "$REPO/main/kernel.sh")
SCRIPT_DIR="$fixture/main"
mkdir -p "$SCRIPT_DIR" "$fixture/input"
log() { :; }
pw() { [[ "$1" == usershow && "$2" == -n && ( "$3" == alice || "$3" == bob_admin || "$3" == root ) ]]; }
id() { [[ "$1" == -u && "$2" == -- ]] || return 1; case "$3" in root) printf '0\n';; alice|bob_admin) printf '1001\n';; *) return 1;; esac; }
printf '# admins\r\n alice \r\nsecret\r\nbob_admin\nsecret\nalice\nsecret\nroot\nsecret\n' > "$fixture/input/auth_admins.txt"
load_admin_allowlist
[[ "${ADMIN_USERS[*]}" == 'alice bob_admin' ]] || fail 'trim, CRLF, duplicates, or dotted username handling'
printf 'root\n' > "$fixture/input/auth_admins.txt"
if load_admin_allowlist; then fail 'root-only allowlist accepted'; fi
printf 'alice\nsecret\nbad;name\nsecret\n' > "$fixture/input/auth_admins.txt"
if load_admin_allowlist; then fail 'invalid username accepted'; fi
printf 'missing\n' > "$fixture/input/auth_admins.txt"
if load_admin_allowlist; then fail 'nonexistent user accepted'; fi
printf 'PASS: FreeBSD hardening configuration fixtures\n'
