"""Exercise audit logging on private fixtures without changing host settings."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


class SettingsLoggingTests(unittest.TestCase):
    def audit(self, before, after, name='config', status=0):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            target = base / name
            if before is not None:
                target.write_text(before)
            (base / 'replacement').write_text(after)
            result = subprocess.run(['bash', '-c', '''
source "$REPO/main/logging.sh"
LOG_FILE="$FIXTURE/log"
CP_BACKUP_ROOT="$FIXTURE/backups"
edit() { cp "$FIXTURE/replacement" "$TARGET"; return "$EDIT_STATUS"; }
audit_file_change "$TARGET" edit
'''], env=dict(os.environ, REPO=str(ROOT), FIXTURE=directory,
              TARGET=str(target), EDIT_STATUS=str(status)), capture_output=True, text=True)
            self.assertEqual(result.returncode, status, result.stderr)
            return (base / 'log').read_text()

    def test_changed_added_removed_and_unchanged(self):
        log = self.audit('a = old\nb=keep\nremoved=yes\n', 'a = new\nb=keep\nadded=42\n')
        self.assertIn(':a from old to new', log)
        self.assertIn(':added with new value 42', log)
        self.assertIn(':removed from yes to <unset>', log)
        self.assertNotIn(':b from', log)

    def test_empty_and_missing_original(self):
        for original in ('', None):
            log = self.audit(original, '# comment\nkey=value\n')
            self.assertIn('added ', log)
            self.assertIn(':key with new value value', log)
            self.assertNotIn(':#', log)

    def test_sections_and_duplicate_settings(self):
        log = self.audit('[Seat:*]\nallow-guest=true\nallow-guest=false\n[Seat:one]\nallow-guest=true\n',
                         '[Seat:*]\nallow-guest=false\n[Seat:one]\nallow-guest=false\n')
        self.assertIn(':[Seat:*]/allow-guest from true | false to false', log)
        self.assertIn(':[Seat:one]/allow-guest from true to false', log)

    def test_comments_and_spacing_do_not_log_changes(self):
        log = self.audit('# old\nkey = same\n', '# new\nkey=same\n')
        self.assertNotIn(' changed ', log)
        self.assertNotIn(' added ', log)

    def test_partial_failure_still_logged(self):
        log = self.audit('key=old\n', 'key=new\n', status=7)
        self.assertIn(':key from old to new', log)
        self.assertIn('FAILED editing', log)

    def test_fstab_mount_options(self):
        log = self.audit('tmpfs /tmp tmpfs defaults 0 0\n',
                         'tmpfs /tmp tmpfs defaults,noexec,nosuid,nodev 0 0\n', name='fstab')
        self.assertIn(':/tmp/options from defaults to defaults,noexec,nosuid,nodev', log)
        self.assertNotIn(':/tmp/source from', log)

    def test_sudoers_and_polkit(self):
        log = self.audit('Defaults timestamp_timeout=5\nroot ALL=(ALL:ALL) ALL\n',
                         'Defaults timestamp_timeout=0\nroot ALL=(ALL:ALL) ALL\nalice ALL=(ALL:ALL) PASSWD: ALL\n')
        self.assertIn(':Defaults timestamp_timeout from 5 to 0', log)
        self.assertIn(':alice ALL with new value (ALL:ALL) PASSWD: ALL', log)
        log = self.audit('return ["unix-user:old"];\n', 'return ["unix-user:new"];\n', name='admins.rules')
        self.assertIn(':policy from return ["unix-user:old"]; to return ["unix-user:new"];', log)

    def test_freebsd_sysctl_and_rc_settings(self):
        log = self.audit('net.inet.ip.forwarding=1\n',
                         'net.inet.ip.forwarding=0\nnet.inet6.ip6.forwarding=0\n', name='sysctl.conf')
        self.assertIn(':net.inet.ip.forwarding from 1 to 0', log)
        self.assertIn(':net.inet6.ip6.forwarding with new value 0', log)
        log = self.audit('gateway_enable="YES"\n',
                         'gateway_enable="NO"\nipv6_gateway_enable="NO"\n', name='rc.conf')
        self.assertIn(':gateway_enable from "YES" to "NO"', log)
        self.assertIn(':ipv6_gateway_enable with new value "NO"', log)



if __name__ == '__main__':
    unittest.main()
