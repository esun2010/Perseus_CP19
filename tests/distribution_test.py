"""Distribution routing tests using isolated files and mocked service commands."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class DistributionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ('service_helpers', 'input', 'etc/upstream-release', 'etc/gdm3', 'keyrings'):
            (self.root / name).mkdir(parents=True)
        for name in ('distribution.sh', 'login_manager.sh'):
            text = (ROOT / 'service_helpers' / name).read_text()
            text = text.replace('/etc', str(self.root / 'etc')).replace('/usr/share/keyrings', str(self.root / 'keyrings'))
            (self.root / 'service_helpers' / name).write_text(text)
        (self.root / 'input/distribution.txt').write_text('auto\n')
        for name in ('ubuntu-archive', 'debian-archive', 'linuxmint'):
            (self.root / 'keyrings' / (name + '-keyring.gpg')).touch()

    def run_script(self, body):
        return subprocess.run(['bash', '-euc', f'''source '{self.root}/service_helpers/distribution.sh'
source '{self.root}/service_helpers/login_manager.sh'
log() {{ :; }}
dpkg() {{ echo amd64; }}
{body}'''], text=True, capture_output=True)

    def test_sources_matrix(self):
        cases = [
            ('ubuntu', 'noble', '', '', 'ubuntu', 'noble'),
            ('debian', 'bookworm', '', '', 'debian', 'bookworm'),
            ('linuxmint', 'xia', 'UBUNTU_CODENAME=noble\n', '', 'ubuntu', 'noble'),
            ('linuxmint', 'faye', '', 'ID=debian\nVERSION_CODENAME=bookworm\n', 'debian', 'bookworm'),
        ]
        for ident, codename, extra, upstream, base, suite in cases:
            with self.subTest(ident=ident, codename=codename):
                (self.root/'etc/os-release').write_text(f'ID="{ident}"\nVERSION_CODENAME={codename}\n'+extra)
                (self.root/'etc/upstream-release/os-release').write_text(upstream)
                result = self.run_script('load_distribution; write_distribution_sources')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f'Suites: {suite} {suite}-updates', result.stdout)
                self.assertIn(f'{base}-archive-keyring.gpg', result.stdout)
                self.assertEqual('packages.linuxmint.com' in result.stdout, ident == 'linuxmint')
                if base == 'debian': self.assertIn('non-free-firmware', result.stdout)

    def test_invalid_and_mismatched_input(self):
        (self.root/'etc/os-release').write_text('ID=debian\nVERSION_CODENAME=bookworm\n')
        for selection in ('ubuntu', 'debian\nmint', '', '$(touch bad)'):
            (self.root/'input/distribution.txt').write_text(selection)
            self.assertNotEqual(self.run_script('load_distribution').returncode, 0)
        (self.root/'input/distribution.txt').write_text('# ubuntu\ndebian # this machine\n')
        self.assertEqual(self.run_script('load_distribution').returncode, 0)

    def test_missing_base_and_keyring_fail(self):
        (self.root/'etc/os-release').write_text('ID=linuxmint\nVERSION_CODENAME=xia\n')
        self.assertNotEqual(self.run_script('load_distribution').returncode, 0)
        (self.root/'etc/os-release').write_text('ID=ubuntu\nVERSION_CODENAME=noble\n')
        (self.root/'keyrings/ubuntu-archive-keyring.gpg').unlink()
        self.assertNotEqual(self.run_script('load_distribution; write_distribution_sources').returncode, 0)

    def test_gdm_paths_and_preservation(self):
        for base, filename in [('ubuntu', 'custom.conf'), ('debian', 'daemon.conf')]:
            path = self.root/'etc/gdm3'/filename
            path.write_text('# keep\n[daemon]\nAutomaticLoginEnable=true\nTimedLoginEnable=true\n[security]\nDisallowTCP=true\n')
            result = self.run_script(f'''CP_BASE={base}; CP_DISTRO={base}
audit_file_change() {{ cp "$1" "$1.backup"; shift; "$@"; }}
configure_other_login_manager gdm3
configure_other_login_manager gdm3''')
            self.assertEqual(result.returncode, 0, result.stderr)
            text = path.read_text()
            self.assertIn('AutomaticLoginEnable=false', text)
            self.assertIn('TimedLoginEnable=false', text)
            self.assertIn('[security]\nDisallowTCP=true', text)
            self.assertEqual(text.count('AutomaticLoginEnable='), 1)
            self.assertTrue(Path(str(path)+'.backup').exists())

    def test_sddm_preserves_theme(self):
        path = self.root/'etc/sddm.conf'
        path.write_text('[Theme]\nCurrent=breeze\n[Autologin]\nUser=alice\nRelogin=true\n')
        result = self.run_script('''CP_DISTRO=debian
backup_system_paths() { :; }
audit_file_change() { shift; "$@"; }
configure_other_login_manager sddm''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Current=breeze', path.read_text())
        self.assertIn('User=\nRelogin=false', path.read_text())

    def test_unit_aliases_all_distros(self):
        for distro in ('ubuntu','debian','mint'):
            result = self.run_script(f'''CP_DISTRO={distro}
systemctl() {{ if [[ "${{@: -1}}" == mariadb ]]; then echo loaded; else echo not-found; fi; }}
distribution_service_unit mysql''')
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(result.stdout.strip(),'mariadb')

    def test_freebsd_detection_and_mismatch(self):
        for selection in ('auto', 'freebsd', 'ubuntu'):
            (self.root/'input/distribution.txt').write_text(selection)
            result = self.run_script('uname() { echo FreeBSD; }; load_distribution; echo "$CP_DISTRO"')
            self.assertEqual(result.returncode == 0, selection != 'ubuntu', result.stderr)
            if result.returncode == 0: self.assertEqual(result.stdout.strip(), 'freebsd')
        (self.root/'input/distribution.txt').write_text('freebsd')
        (self.root/'etc/os-release').write_text('ID=ubuntu\nVERSION_CODENAME=noble\n')
        self.assertNotEqual(self.run_script('uname() { echo Linux; }; load_distribution').returncode, 0)

    def test_launchers_route_to_bundled_freebsd(self):
        native = self.root/'platforms/FreeBSD'
        native.mkdir(parents=True)
        (self.root/'input/distribution.txt').write_text('freebsd')
        mock = self.root/'mock.sh'
        mock.write_text('uname() { echo FreeBSD; }\n')
        import os
        env = dict(os.environ, BASH_ENV=str(mock))
        for name in ('run_all.sh', 'run_all_2.sh'):
            (self.root/name).write_text((ROOT/name).read_text())
            (native/name).write_text('echo NATIVE-'+name+'\n')
            result = subprocess.run(['bash', str(self.root/name)], env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), 'NATIVE-'+name)
