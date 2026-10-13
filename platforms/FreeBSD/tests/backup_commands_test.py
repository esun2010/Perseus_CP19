#!/usr/bin/env python3
"""Run real task control flow against temporary paths and fake native commands."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from fixture_sources import read_source, SHARED

ROOT = Path(__file__).resolve().parents[1]
BSD = (ROOT / 'service_helpers/platform.sh').exists()


class BackupCommandsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cp-backup-commands-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ('input', 'config', 'main', 'password_management', 'service_helpers',
                     'etc/lightdm', 'etc/security', 'etc/ufw', 'etc/default', 'etc/systemd/system'):
            (self.root / name).mkdir(parents=True, exist_ok=True)
        for name in ('passwd', 'shadow', 'master.passwd', 'group', 'gshadow', 'pwd.db', 'spwd.db',
                     'subuid', 'subgid', 'security/opasswd', 'lightdm/lightdm.conf', 'ufw/user.rules', 'default/ufw'):
            (self.root / 'etc' / name).write_text('original fixture content\n')
        (self.root / 'input/auth_admins.txt').write_text('alice\nbob\n')
        # Only these copied files run. All absolute policy paths point into the fixture.
        for name in ('service_helpers/permissions.sh', 'main/login.sh'):
            text = read_source(name).replace('/etc', str(self.root / 'etc'))
            text = text.replace('$EUID -ne 0', '0 -ne 0')
            text = text.replace('[[ -t 0 && -t 1 ]]', 'true')
            (self.root / name).write_text(text)
        logging = read_source('main/logging.sh').replace('/etc', str(self.root / 'etc'))
        (self.root / 'logging.sh').write_text(logging)
        (self.root / 'main/logging.sh').write_text(logging)
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
                out.write("uname() { echo FreeBSD; }\n")
                out.write("id() { printf '1001\\n'; }\n")
        self.env = dict(os.environ, BASH_ENV=str(self.root / 'mocks.sh'),
                        FIXTURE=str(self.root), CP_BACKUP_ROOT=str(self.root / 'backups'),
                        ACCOUNT_FILE='master.passwd' if BSD else 'shadow')
        self.env.pop('SSH_CONNECTION', None)

    def run_task(self, name, fail_backup=False):
        env = dict(self.env, FAIL_BACKUP='yes' if fail_backup else 'no')
        return subprocess.run(['bash', str(self.root / name)], env=env, text=True, capture_output=True)

    def test_guest_changes_snapshot_each_database_update(self):
        result = self.run_task('main/login.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / 'calls').read_text().count('account change'), 2)

    def test_guest_changes_stop_on_backup_failure(self):
        result = self.run_task('main/login.sh', True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'calls').exists())



if __name__ == '__main__':
    unittest.main(verbosity=2)
