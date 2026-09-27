#!/usr/bin/env python3
"""Run real task control flow against temporary paths and fake native commands."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BSD = (ROOT / 'service_helpers/platform.sh').exists()


class BackupCommandsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cp-backup-commands-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ('input', 'misc', 'services', 'password_management', 'service_helpers',
                     'etc/lightdm', 'etc/security', 'etc/ufw', 'etc/default', 'etc/systemd/system'):
            (self.root / name).mkdir(parents=True, exist_ok=True)
        for name in ('passwd', 'shadow', 'master.passwd', 'group', 'gshadow', 'pwd.db', 'spwd.db',
                     'subuid', 'subgid', 'security/opasswd', 'lightdm/lightdm.conf', 'ufw/user.rules', 'default/ufw'):
            (self.root / 'etc' / name).write_text('original fixture content\n')
        (self.root / 'input/auth_admins.txt').write_text('alice\nbob\n')
        (self.root / 'input/critical_services.txt').write_text('none\n')
        # Only these copied files run. All absolute policy paths point into the fixture.
        for name in ('logging.sh', 'service_helpers/service_common.sh', 'service_helpers/permissions.sh',
                     'service_helpers/critical_services.sh', 'service_helpers/managed_firewall.sh', 'service_helpers/managed_platform.sh', 'password_management/reset_admin_pwd.sh', 'misc/login.sh'):
            text = (ROOT / name).read_text().replace('/etc', str(self.root / 'etc'))
            text = text.replace('$EUID -ne 0', '0 -ne 0')
            text = text.replace('[[ -t 0 && -t 1 ]]', 'true')
            (self.root / name).write_text(text)
        (self.root / 'service_helpers/platform.sh').write_text('''
require_freebsd_root() { :; }
require_commands() { :; }
package_installed() { return 1; }
''')
        (self.root / 'mocks.sh').write_text(r'''
id() { if [[ "${1:-}" == -u ]]; then printf '0\n'; else return 0; fi; }
cp() { [[ "${FAIL_BACKUP:-no}" != yes ]] || return 1; command cp "$@"; }
assert_account_backup() {
    [[ -f "$SYSTEM_BACKUP_DIR/COMPLETE" ]] || return 81
    cmp "$FIXTURE/etc/$ACCOUNT_FILE" "$SYSTEM_BACKUP_DIR/files$FIXTURE/etc/$ACCOUNT_FILE" || return 82
    printf 'account change\n' >> "$FIXTURE/calls"
    printf 'changed\n' >> "$FIXTURE/etc/$ACCOUNT_FILE"
}
chpasswd() { local input; read -r input; assert_account_backup; }
passwd() {
    if [[ "${1:-}" == -S ]]; then printf 'guest P\n'; return; fi
    assert_account_backup
}
usermod() { assert_account_backup; }
userdel() { assert_account_backup; }
pw() {
    case "$1" in usershow) return 0 ;; lock|usermod) assert_account_backup ;; *) return 88 ;; esac
}
systemctl() { [[ "$1" != is-active ]]; }
''')
        if BSD:
            with (self.root / 'mocks.sh').open('a') as out:
                out.write("id() { printf '1001\\n'; }\n")
        self.env = dict(os.environ, BASH_ENV=str(self.root / 'mocks.sh'),
                        FIXTURE=str(self.root), CP_BACKUP_ROOT=str(self.root / 'backups'),
                        ACCOUNT_FILE='master.passwd' if BSD else 'shadow')
        self.env.pop('SSH_CONNECTION', None)

    def run_task(self, name, fail_backup=False):
        env = dict(self.env, FAIL_BACKUP='yes' if fail_backup else 'no')
        return subprocess.run(['bash', str(self.root / name)], env=env, text=True, capture_output=True)

    def test_password_resets_snapshot_each_change(self):
        result = self.run_task('password_management/reset_admin_pwd.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / 'calls').read_text().count('account change'), 2)
        self.assertEqual(len(list((self.root / 'backups').glob('*/COMPLETE'))), 2)
        self.assertNotIn('original fixture content', (self.root / 'all_logs.txt').read_text())

    def test_password_reset_stops_on_backup_failure(self):
        result = self.run_task('password_management/reset_admin_pwd.sh', True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'calls').exists())

    def test_guest_changes_snapshot_each_database_update(self):
        result = self.run_task('misc/login.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / 'calls').read_text().count('account change'), 2)

    def test_guest_changes_stop_on_backup_failure(self):
        result = self.run_task('misc/login.sh', True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'calls').exists())

    @unittest.skipIf(BSD, 'UFW is Ubuntu-only; FreeBSD PF has its own fixture suite')
    def test_ufw_backups_precede_firewall_mutations(self):
        text = (ROOT / 'services/ufw.sh').read_text().replace('/etc', str(self.root / 'etc'))
        (self.root / 'services/ufw.sh').write_text(text)
        with (self.root / 'service_helpers/service_common.sh').open('a') as out:
            out.write(r'''
service_init() { :; }
install_packages() { :; }
secure_service_permissions() { :; }
ufw() {
    if [[ "$1" == status ]]; then printf 'Status: active\n'; return; fi
    [[ -f "$SYSTEM_BACKUP_DIR/COMPLETE" ]] || return 81
    cmp "$FIXTURE/etc/ufw/user.rules" "$SYSTEM_BACKUP_DIR/files$FIXTURE/etc/ufw/user.rules" || return 82
    cmp "$FIXTURE/etc/default/ufw" "$SYSTEM_BACKUP_DIR/files$FIXTURE/etc/default/ufw" || return 83
    printf 'ufw change\n' >> "$FIXTURE/calls"
}
''')
        result = self.run_task('services/ufw.sh', True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'calls').exists())
        result = self.run_task('services/ufw.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / 'calls').read_text().count('ufw change'), 4)


if __name__ == '__main__':
    unittest.main(verbosity=2)
