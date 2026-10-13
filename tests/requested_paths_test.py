from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RequestedPathsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)

    def run_shell(self, script):
        result = subprocess.run(['bash', '-euo', 'pipefail', '-c', script],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def prelude(self):
        return f'''source '{ROOT}/main/logging.sh'
source '{ROOT}/service_helpers/permissions.sh'
source '{ROOT}/service_helpers/path_hardening.sh'
log() {{ :; }}
export CP_BACKUP_ROOT='{self.base}/backups'
'''

    def test_user_secrets_protected_content_retained_and_links_refused(self):
        home = self.base / 'home'
        (home / '.ssh').mkdir(parents=True)
        files = ['.bash_profile', '.bashrc', '.bash_login', '.profile', '.zshrc',
                 '.bash_history', '.ssh/authorized_keys', '.ssh/config',
                 '.ssh/id_rsa', '.ssh/id_ed25519']
        for name in files:
            (home / name).write_text('do not disclose or replace\n')
            (home / name).chmod(0o666)
        self.run_shell(self.prelude() + f'secure_login_home "{home}" "$(id -un)"')
        for name in files:
            self.assertEqual((home / name).stat().st_mode & 0o777, 0o600)
            self.assertEqual((home / name).read_text(), 'do not disclose or replace\n')
        outside = self.base / 'outside'
        outside.write_text('retained')
        outside.chmod(0o666)
        (home / '.ssh/id_rsa').unlink()
        (home / '.ssh/id_rsa').symlink_to(outside)
        self.run_shell(self.prelude() + f'if secure_login_home "{home}" "$(id -un)"; then exit 1; fi')
        self.assertEqual(outside.stat().st_mode & 0o777, 0o666)

    def test_boot_files_and_fat_mounts(self):
        helper = (ROOT / 'service_helpers/path_hardening.sh').read_text()
        helper = helper.replace('/boot/', str(self.base / 'boot') + '/')
        local = self.base / 'helper.sh'
        local.write_text(helper)
        paths = ['grub2/grub.cfg', 'efi/EFI/ubuntu/grub.cfg',
                 'efi/EFI/centos/grub.cfg', 'efi/EFI/redhat/grub.cfg',
                 'loader/entries/linux.conf']
        for name in paths:
            file = self.base / 'boot' / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text('existing boot configuration')
            file.chmod(0o666)
        self.run_shell(self.prelude() + f'''
source '{local}'
chown() {{ :; }}
findmnt() {{ echo ext4; }}
secure_boot_paths
''')
        for name in paths:
            self.assertEqual((self.base / 'boot' / name).stat().st_mode & 0o777, 0o600)
        efi = self.base / 'boot/efi/EFI/ubuntu/grub.cfg'
        efi.chmod(0o666)
        self.run_shell(self.prelude() + f'''
source '{local}'
findmnt() {{ echo vfat; }}
secure_path() {{ echo 'must not chmod FAT'; return 1; }}
secure_tree() {{ return 1; }}
secure_boot_paths
''')
        self.assertEqual(efi.stat().st_mode & 0o777, 0o666)

    def test_vendor_units_and_certificate_trees(self):
        roots = ['/lib/systemd/system', '/usr/lib/systemd/system',
                 '/usr/share/ca-certificates', '/etc/pki/tls/certs',
                 '/etc/pki/ca-trust/source/anchors', '/usr/local/share/ca-certificates']
        helper = (ROOT / 'service_helpers/path_hardening.sh').read_text()
        files = []
        for index, path in enumerate(roots):
            directory = self.base / f'tree{index}'
            directory.mkdir()
            names = ['sshd.service', 'nginx.service', 'httpd.service',
                     'rsyslog.service', 'auditd.service'] if index < 2 else ['local.crt']
            for name in names:
                file = directory / name
                file.write_text('original content')
                file.chmod(0o666)
                files.append(file)
            helper = helper.replace(' ' + path, ' ' + str(directory))
        # Internal symbolic links must not let hardening escape a trusted tree.
        outside = self.base / 'outside'
        outside.write_text('outside')
        outside.chmod(0o666)
        (self.base / 'tree0/alias.service').symlink_to(outside)
        local = self.base / 'helper.sh'
        local.write_text(helper)
        self.run_shell(self.prelude() + f"source '{local}'\nchown() {{ :; }}\nsecure_vendor_units_and_trust")
        for file in files:
            self.assertEqual(file.stat().st_mode & 0o777, 0o644)
            self.assertEqual(file.read_text(), 'original content')
        self.assertEqual(outside.stat().st_mode & 0o777, 0o666)

    def test_kernel_always_disables_forwarding(self):
        script = (ROOT / 'main/kernel.sh').read_text()
        start = script.index('# Forwarding changes reset')
        end = script.index('log "Sysctl hardening complete."')
        output = self.run_shell('add_sysctl_setting() { echo "$*"; }\n' + script[start:end])
        for setting in ['fs.protected_hardlinks 1', 'fs.protected_symlinks 1',
                        'kernel.sysrq 0', 'kernel.randomize_va_space 2',
                        'net.ipv4.conf.all.secure_redirects 0',
                        'net.ipv4.conf.default.secure_redirects 0',
                        'net.ipv4.ip_forward 0', 'net.ipv6.conf.all.forwarding 0']:
            self.assertIn(setting, output)
        self.assertLess(output.index('net.ipv4.ip_forward 0'),
                        output.index('net.ipv4.tcp_syncookies 1'))
        self.assertNotIn('forwarding.txt', script)

    def test_forwarding_is_persisted_and_applied_idempotently(self):
        script = (ROOT / 'main/kernel.sh').read_text()
        functions = script[script.index('ensure_sysctl_file()'):script.index('load_admin_allowlist()')]
        config = self.base / 'hardening.conf'
        config.write_text('net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n')
        self.run_shell(f'''SYSCTL_FILE='{config}'
log() {{ :; }}
audit_file_change() {{ shift; "$@"; }}
sysctl() {{
    if [[ "$1" == -w ]]; then echo "$2" >> '{self.base}/runtime'; else echo 0; fi
}}
{functions}
for attempt in 1 2; do
    add_sysctl_setting net.ipv4.ip_forward 0
    add_sysctl_setting net.ipv6.conf.all.forwarding 0
done
''')
        self.assertEqual(config.read_text().splitlines(),
                         ['net.ipv4.ip_forward = 0', 'net.ipv6.conf.all.forwarding = 0'])
        self.assertEqual((self.base / 'runtime').read_text().splitlines(),
                         ['net.ipv4.ip_forward=0', 'net.ipv6.conf.all.forwarding=0'] * 2)


if __name__ == '__main__':
    unittest.main()
