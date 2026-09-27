"""Shared launchers and native dispatch, with all system actions stubbed."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PlatformIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ('service_helpers', 'input', 'platforms/FreeBSD/service_helpers'):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        for name in ('run_all.sh', 'run_all_services.sh', 'run_all_2.sh',
                     'service_helpers/task_paths.sh', 'service_helpers/critical_services.sh'):
            shutil.copy2(ROOT / name, self.root / name)
        (self.root / 'service_helpers/distribution.sh').write_text('load_distribution() { CP_DISTRO=freebsd; }\n')
        (self.root / 'service_helpers/startup_repair.sh').write_text('startup_repair() { echo repair >> "$CALLS"; }\n')
        (self.root / 'platforms/FreeBSD/service_helpers/platform.sh').write_text('require_freebsd_root() { :; }; require_commands() { :; }\n')
        (self.root / 'logging.sh').write_text('log() { :; }; init_logging() { :; }; backup_package_configuration() { :; }\n')
        (self.root / 'input/critical_services.txt').write_text('ssh\nufw\nnginx\n')
        self.native_tasks = ('misc/kernel.sh', 'misc/login.sh', 'misc/file_permissions.sh',
                             'password_management/pwd_policy.sh', 'password_management/reset_admin_pwd.sh',
                             'rm_stuff/malware_search.sh', 'rm_stuff/bad_pkg.sh',
                             'services/ssh.sh', 'services/apache2.sh', 'services/vsftpd.sh', 'services/pf.sh')
        self.shared_tasks = ('misc/system_hardening.sh', 'user_management/user_management.sh',
                             'rm_stuff/rm_mp3+.sh', 'services/reconcile.sh', 'services/nginx.sh',
                             'services/bind9.sh', 'services/mysql.sh', 'services/postfix.sh',
                             'services/sendmail.sh', 'services/samba.sh', 'services/openvpn.sh',
                             'services/wordpress.sh', 'services/joomla.sh')
        for path in self.native_tasks:
            self.stub('platforms/FreeBSD/' + path)
            if path != 'services/pf.sh':
                self.stub(path, fail=True)  # Linux code must never be selected.
        for path in self.shared_tasks:
            self.stub(path)
        (self.root / 'env.sh').write_text('''uname() { echo FreeBSD; }
id() { echo 0; }
pkg() { echo "pkg $*" >> "$CALLS"; }
apt() { echo unexpected-apt >> "$CALLS"; return 99; }
sudo() { echo unexpected-sudo >> "$CALLS"; return 99; }
''')

    def stub(self, path, fail=False):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(f'echo "{path}" >> "$CALLS"\n[[ "${{FAIL_TASK:-}}" != "{path}" ]] || exit 7\nexit {99 if fail else 0}\n')

    def launch(self, name, selection, fail_task='', expected=0):
        result = subprocess.run(['bash', str(self.root / name)], input=selection + '\n',
                                capture_output=True, text=True,
                                env=dict(os.environ, BASH_ENV=str(self.root / 'env.sh'),
                                         CALLS=str(self.root / 'calls'), FAIL_TASK=fail_task))
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return (self.root / 'calls').read_text().splitlines() if (self.root / 'calls').exists() else []

    def test_general_uses_native_overrides_and_shared_components(self):
        calls = self.launch('run_all.sh', 'all')
        self.assertIn('platforms/FreeBSD/misc/kernel.sh', calls)
        self.assertIn('misc/system_hardening.sh', calls)
        self.assertIn('user_management/user_management.sh', calls)
        self.assertIn('pkg upgrade', calls)
        self.assertFalse(any('unexpected-' in line or line.startswith('services/') for line in calls))
        self.assertTrue((self.root / '.run_all_status.freebsd').exists())
        self.assertFalse((self.root / '.run_all_status').exists())

    def test_services_share_policy_and_apply_native_firewall_last(self):
        calls = self.launch('run_all_services.sh', 'auto')
        self.assertEqual(calls, ['services/reconcile.sh', 'platforms/FreeBSD/services/ssh.sh',
                                 'services/nginx.sh', 'platforms/FreeBSD/services/pf.sh'])
        self.assertTrue((self.root / '.run_all_services_status.freebsd').exists())

    def test_service_failure_blocks_pf_and_remains_resumable(self):
        calls = self.launch('run_all_services.sh', 'auto',
                            fail_task='platforms/FreeBSD/services/ssh.sh', expected=1)
        self.assertNotIn('platforms/FreeBSD/services/pf.sh', calls)
        (self.root / 'calls').unlink()
        self.assertIn('platforms/FreeBSD/services/pf.sh', self.launch('run_all_services.sh', ''))

    def test_unsupported_native_service_fails_before_mutation(self):
        (self.root / 'input/critical_services.txt').write_text('rsyslog\n')
        self.assertEqual(self.launch('run_all_services.sh', 'auto', expected=1), [])

    def test_duplicate_data_and_shared_implementations_are_absent(self):
        for relative in ('input', 'log', 'logging.sh', 'run_all.sh', 'run_all_2.sh',
                         'service_helpers/managed_services.sh', 'service_helpers/second_pass_accounts.sh',
                         'services/nginx.sh', 'misc/nss.sh'):
            self.assertFalse((ROOT / 'platforms/FreeBSD' / relative).exists(), relative)

    def test_shared_service_backend_uses_root_data_and_logging(self):
        result = subprocess.run(['bash', '-c', '''
uname() { echo FreeBSD; }
source "$REPOSITORY/service_helpers/managed_services.sh"
[[ "$MANAGED_PLATFORM" == freebsd && "$REPO_DIR" == "$REPOSITORY" ]]
[[ "$LOG_FILE" == "$REPOSITORY/all_logs.txt" ]]
[[ $(declare -f installed_server_packages) == *"pkg query"* ]]
source "$REPOSITORY/service_helpers/second_pass_accounts.sh"
[[ "$SECOND_ROOT" == "$REPOSITORY" ]]
'''], env=dict(os.environ, REPOSITORY=str(ROOT)), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
