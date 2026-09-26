#!/usr/bin/env python3
"""Check account/PAM/log protection using fixture files and simulated ownership."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BSD = (ROOT / 'service_helpers/platform.sh').exists()


class AuthenticationPermissionsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cp-auth-permissions-')
        self.addCleanup(self.temp.cleanup)
        self.fixture = Path(self.temp.name)
        self.system = self.fixture / 'system'
        self.originals = {}
        paths = [
            '/etc/passwd', '/etc/group', '/etc/pam.d/login',
            '/var/log/auth.log', '/var/log/auth.log.1',
        ]
        if BSD:
            paths += ['/etc/master.passwd', '/etc/spwd.db', '/etc/pwd.db',
                      '/etc/login.conf', '/etc/login.conf.db', '/usr/local/etc/pam.d/sshd',
                      '/usr/lib/pam_unix.so.6', '/usr/local/lib/pam_example.so']
        else:
            paths += ['/etc/shadow', '/etc/gshadow', '/etc/passwd-', '/etc/group-',
                      '/etc/shadow-', '/etc/gshadow-', '/etc/security/access.conf',
                      '/etc/security/pwquality.conf', '/etc/security/opasswd', '/etc/security/opasswd.old',
                      '/usr/lib64/security/pam_unix.so', '/usr/lib/x86_64-linux-gnu/security/pam_example.so',
                      '/var/log/secure', '/var/log/secure.1']
        for name in paths:
            p = self.path(name)
            p.parent.mkdir(parents=True, exist_ok=True)
            content = f'fixture content for {name}\n'
            p.write_text(content)
            p.chmod(0o777 if '/lib' in name and 'pam_' in name else 0o666)
            self.originals[p] = content
        pam = self.path('/etc/pam.d')
        pam.chmod(0o777)
        self.path('/etc/pam.d/strict').write_text('strict configuration\n')
        self.path('/etc/pam.d/strict').chmod(0o600)
        self.path('/outside').write_text('external policy\n')
        self.path('/outside').chmod(0o666)
        self.path('/etc/pam.d/link').symlink_to(self.path('/outside'))
        if not BSD:
            self.path('/lib64').mkdir()
            self.path('/lib64/security').symlink_to(self.path('/usr/lib64/security'))
        (self.fixture / 'logging.sh').write_text((ROOT / 'logging.sh').read_text())
        permissions = (ROOT / 'service_helpers/permissions.sh').read_text()
        # Replace only absolute policy roots, retaining the real helper control flow.
        permissions = re.sub(r'(?<![A-Za-z0-9_])/(?:usr|etc|var|lib64|lib)(?=/)',
                             lambda match: str(self.system) + match.group(), permissions)
        (self.fixture / 'permissions.sh').write_text(permissions)
        (self.fixture / 'runner.sh').write_text(r'''
set -euo pipefail
source "$FIXTURE/logging.sh"
source "$FIXTURE/permissions.sh"
LOG_FILE="$FIXTURE/audit.log"
declare -A owners=() groups=()
stat() {
    local format="$2" path="${@: -1}"
    case "$format" in
        %U|%Su) printf '%s\n' "${owners[$path]:-root}" ;;
        %G|%Sg) printf '%s\n' "${groups[$path]:-untrusted}" ;;
        %a|%Lp)
            if [[ "$(uname -s)" == FreeBSD ]]; then command stat -f '%Lp' "$path"
            else command stat -c '%a' "$path"; fi ;;
        *) return 90 ;;
    esac
}
chown() {
    [[ "$1" != -- ]] || shift
    local ownership="$1" path="$2"
    if [[ -f "$path" ]]; then
        [[ -f "$SYSTEM_BACKUP_DIR/COMPLETE" ]] || return 91
        cmp "$path" "$SYSTEM_BACKUP_DIR/files$path" || return 92
    fi
    owners[$path]=${ownership%%:*}
    if [[ "$ownership" == *:* ]]; then groups[$path]=${ownership#*:}; fi
    printf '%s %s\n' "$ownership" "$path" >> "$FIXTURE/ownership.log"
}
getent() { [[ "$*" == 'group shadow' && "${NO_SHADOW_GROUP:-no}" == no ]]; }
cp() { [[ "${FAIL_BACKUP:-no}" != yes ]] || return 1; command cp "$@"; }
chmod() {
    # Password history must never be made readable by group/other, even briefly.
    if [[ "$*" == *'/security/opasswd'* && "$1" != 600 ]]; then return 93; fi
    command chmod "$@"
}
owners["$FIXTURE/system/etc/passwd"]=intruder
if [[ "$IS_BSD" == no ]]; then owners["$FIXTURE/system/var/log/auth.log"]=syslog; fi
secure_auth_permissions
if [[ "${REPEAT:-no}" == yes ]]; then
    count_before=$(find "$CP_BACKUP_ROOT" -name COMPLETE | wc -l)
    secure_auth_permissions
    count_after=$(find "$CP_BACKUP_ROOT" -name COMPLETE | wc -l)
    [[ "$count_before" == "$count_after" ]] || exit 94
fi
''')

    def path(self, name):
        return self.system / name.lstrip('/')

    def run_permissions(self, **options):
        env = dict(os.environ, FIXTURE=str(self.fixture), CP_BACKUP_ROOT=str(self.fixture / 'backups'),
                   IS_BSD='yes' if BSD else 'no', **options)
        return subprocess.run(['bash', str(self.fixture / 'runner.sh')], env=env, text=True, capture_output=True)

    def assert_mode(self, path, expected):
        self.assertEqual(self.path(path).stat().st_mode & 0o7777, expected, path)

    def test_public_account_files_recover_from_overly_strict_permissions(self):
        names=['/etc/passwd','/etc/group'] + (['/etc/pwd.db'] if BSD else [])
        for name in names: self.path(name).chmod(0o600)
        result=self.run_permissions()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        for name in names: self.assert_mode(name,0o644)

    def test_all_native_paths_protected_and_repeat_run_preserves_stricter_modes(self):
        result = self.run_permissions(REPEAT='yes')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for name in ('/etc/passwd', '/etc/group', '/etc/pam.d/login'):
            self.assert_mode(name, 0o644)
        self.assert_mode('/etc/pam.d', 0o755)
        self.assert_mode('/etc/pam.d/strict', 0o600)
        self.assert_mode('/outside', 0o666)
        for name in ('/var/log/auth.log', '/var/log/auth.log.1'):
            self.assert_mode(name, 0o640)
        ownership = (self.fixture / 'ownership.log').read_text()
        self.assertIn(('root:wheel ' if BSD else 'root:root ') + str(self.path('/etc/group')), ownership)
        if BSD:
            for name in ('/etc/master.passwd', '/etc/spwd.db'):
                self.assert_mode(name, 0o600)
            for name in ('/etc/pwd.db', '/etc/login.conf', '/etc/login.conf.db', '/usr/local/etc/pam.d/sshd'):
                self.assert_mode(name, 0o644)
            self.assert_mode('/usr/lib/pam_unix.so.6', 0o755)
            self.assert_mode('/usr/local/lib/pam_example.so', 0o755)
            self.assertFalse(self.path('/etc/shadow').exists())
            self.assertFalse(self.path('/usr/lib64/security').exists())
        else:
            for name in ('/etc/shadow', '/etc/gshadow', '/etc/shadow-', '/etc/gshadow-'):
                self.assert_mode(name, 0o640)
                self.assertIn('root:shadow ' + str(self.path(name)), ownership)
            for name in ('/etc/security/opasswd', '/etc/security/opasswd.old'):
                self.assert_mode(name, 0o600)
            for name in ('/etc/security/access.conf', '/etc/security/pwquality.conf'):
                self.assert_mode(name, 0o644)
            self.assert_mode('/usr/lib64/security/pam_unix.so', 0o755)
            self.assert_mode('/usr/lib/x86_64-linux-gnu/security/pam_example.so', 0o755)
            self.assert_mode('/var/log/secure', 0o640)
            self.assert_mode('/var/log/secure.1', 0o640)
            self.assertNotIn('root ' + str(self.path('/var/log/auth.log')) + '\n', ownership)
        for p, content in self.originals.items():
            self.assertEqual(p.read_text(), content)
        log = (self.fixture / 'audit.log').read_text()
        self.assertNotIn('fixture content', log)

    def test_failed_backup_stops_before_ownership_or_modes_change(self):
        result = self.run_permissions(FAIL_BACKUP='yes')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.fixture / 'ownership.log').exists())
        for name in ('/etc/passwd', '/etc/group', '/etc/pam.d/login'):
            self.assert_mode(name, 0o666)

    def test_missing_required_database_fails_without_fabricating_one(self):
        self.path('/etc/group').unlink()
        result = self.run_permissions()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.path('/etc/group').exists())
        self.assertFalse((self.fixture / 'ownership.log').exists())

    def test_redirected_core_database_fails_without_changing_its_target(self):
        self.path('/etc/passwd').unlink()
        self.path('/etc/passwd').symlink_to(self.path('/outside'))
        result = self.run_permissions()
        self.assertNotEqual(result.returncode, 0)
        self.assert_mode('/outside', 0o666)

    def test_absent_platform_specific_paths_are_not_created(self):
        for name in ('/var/log/auth.log', '/var/log/auth.log.1'):
            self.path(name).unlink()
        if not BSD:
            self.path('/var/log/secure').unlink()
            self.path('/var/log/secure.1').unlink()
        result = self.run_permissions()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.path('/var/log/auth.log').exists())
        self.assertFalse(self.path('/var/log/secure').exists())

    @unittest.skipIf(BSD, 'shadow is Linux-specific')
    def test_missing_shadow_group_falls_back_to_root(self):
        result = self.run_permissions(NO_SHADOW_GROUP='yes')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('root:root ' + str(self.path('/etc/shadow')),
                      (self.fixture / 'ownership.log').read_text())


if __name__ == '__main__':
    unittest.main(verbosity=2)
