#!/usr/bin/env python3
"""Regression checks for the requested Ubuntu fixes, without host changes."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]

class RequestedFixesTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='cp-requested-fixes-')
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
    def run_bash(self,text,**variables):
        env=dict(os.environ,FIXTURE=str(self.root),CP_BACKUP_ROOT=str(self.root/'backups'))
        env.update(variables)
        return subprocess.run(['bash','-c',text],env=env,text=True,capture_output=True)
    def test_lightdm_absent_is_skipped_and_installed_configuration_is_seat_scoped(self):
        (self.root/'misc').mkdir();(self.root/'etc').mkdir()
        (self.root/'service_helpers').mkdir(); (self.root/'input').mkdir()
        (self.root/'input/distribution.txt').write_text('auto\n')
        (self.root/'etc/os-release').write_text('ID=ubuntu\nVERSION_CODENAME=noble\n')
        for name in ('distribution.sh','login_manager.sh'):
            (self.root/'service_helpers'/name).write_text((ROOT/'service_helpers'/name).read_text().replace('/etc',str(self.root/'etc')))
        (self.root/'logging.sh').write_text((ROOT/'logging.sh').read_text())
        script=(ROOT/'misc/login.sh').read_text().replace('/etc',str(self.root/'etc')).replace('/var/backups',str(self.root/'legacy-backups'))
        (self.root/'misc/login.sh').write_text(script)
        mocks='''
id() { if [[ "$1" == -u ]]; then echo 0; else return 1; fi; }
dpkg-query() { if [[ "${@: -1}" == lightdm ]]; then printf '%s' "$LIGHTDM_STATUS"; else return 1; fi; }
install() { mkdir -p "${@: -1}"; }
chown() { :; }
systemctl() { echo unexpected >> "$FIXTURE/restart"; return 99; }
'''
        (self.root/'mocks.sh').write_text(mocks)
        result=self.run_bash('bash "$FIXTURE/misc/login.sh"',BASH_ENV=str(self.root/'mocks.sh'),LIGHTDM_STATUS='absent')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertFalse((self.root/'etc/lightdm').exists())
        (self.root/'etc/lightdm').mkdir()
        conf=self.root/'etc/lightdm/lightdm.conf';conf.write_text('[Seat:*]\nallow-guest=true\n[XDMCPServer]\nenabled=false\n')
        result=self.run_bash('bash "$FIXTURE/misc/login.sh"',BASH_ENV=str(self.root/'mocks.sh'),LIGHTDM_STATUS='installed')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('[Seat:*]\nallow-guest=false\n[XDMCPServer]',conf.read_text())
        self.assertIn('[Seat:*]\nallow-guest=false',(self.root/'etc/lightdm/lightdm.conf.d/99-cyberpatriot-guest.conf').read_text())
        self.assertFalse((self.root/'restart').exists())
    def test_kernel_failures_propagate(self):
        text=(ROOT/'misc/kernel.sh').read_text()
        helpers=text[text.index('add_sysctl_setting() {'):text.index('###############################################################################\n# Administrator allowlist')]
        helpers+=text[text.index('harden_mountpoint() {'):text.index('write_fstab_entry() {')]
        (self.root/'kernel_helpers.sh').write_text(helpers)
        result=self.run_bash('''set -euo pipefail
source "$FIXTURE/kernel_helpers.sh"
log() { :; }
ensure_sysctl_file() { :; }; audit_file_change() { :; }; SYSCTL_FILE="$FIXTURE/config"
sysctl() { return 1; }
if add_sysctl_setting fake.key 1; then exit 91; fi
sysctl() { if [[ "$1" == -n ]]; then echo 0; fi; }
if add_sysctl_setting fake.key 1; then exit 92; fi
audit_chmod() { return 1; }; mountpoint() { return 1; }
if harden_mountpoint "$FIXTURE" fixture; then exit 93; fi
audit_chmod() { :; }; mountpoint() { :; }; findmnt() { echo rw; }; mount() { return 1; }
if harden_mountpoint "$FIXTURE" fixture; then exit 94; fi
mount() { :; }
if harden_mountpoint "$FIXTURE" fixture; then exit 95; fi
''')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
    def test_openvpn_client_uses_client_unit_and_unmasks_template(self):
        client=self.root/'openvpn/client';client.mkdir(parents=True)
        (client/'competition.conf').write_text('client\n')
        text=(ROOT/'service_helpers/managed_platform.sh').read_text().replace('/etc/openvpn',str(self.root/'openvpn'))
        (self.root/'managed.sh').write_text(text)
        result=self.run_bash('''set -euo pipefail
source "$FIXTURE/managed.sh"
install_managed_package() { :; }; require_regular_config() { [[ -f "$1" ]]; }; secure_path() { :; }
backup_system_paths() { :; }
systemctl() { printf '%s\\n' "$*" >> "$FIXTURE/calls"; }
enable_service() { printf 'enable %s\\n' "$1" >> "$FIXTURE/calls"; }
log() { :; }
configure_native_service openvpn
''')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        calls=(self.root/'calls').read_text()
        self.assertIn('unmask openvpn-client@.service',calls)
        self.assertIn('enable openvpn-client@competition',calls)
    def test_package_cleanup_uses_exact_installed_status(self):
        for name in ('rm_stuff','service_helpers','input'):(self.root/name).mkdir()
        (self.root/'logging.sh').write_text('log() { :; }\n')
        (self.root/'rm_stuff/bad_pkg.sh').write_text((ROOT/'rm_stuff/bad_pkg.sh').read_text().replace('$EUID -ne 0','0 -ne 0'))
        (self.root/'mocks.sh').write_text('''
dpkg() { echo unexpected >> "$FIXTURE/dpkg-used"; return 99; }
dpkg-query() { if [[ "${@: -1}" == nmap ]]; then echo installed; else echo config-files; fi; }
apt-get() { :; }
apt() { printf '%s\\n' "$*" >> "$FIXTURE/purges"; }
''')
        result=self.run_bash('bash "$FIXTURE/rm_stuff/bad_pkg.sh"',BASH_ENV=str(self.root/'mocks.sh'))
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual((self.root/'purges').read_text(),'purge -y -- nmap\n')
        self.assertFalse((self.root/'dpkg-used').exists())

if __name__=='__main__':unittest.main(verbosity=2)
