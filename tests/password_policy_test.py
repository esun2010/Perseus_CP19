#!/usr/bin/env python3
"""Exercise password policy using temporary configuration and real PAM generation."""
from pathlib import Path
import ctypes
import ctypes.util
import os
import pwd
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PAM_UPDATE = shutil.which('pam-auth-update')


@unittest.skipUnless(PAM_UPDATE, 'requires Debian/Ubuntu pam-auth-update')
class PasswordPolicyTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cp-password-policy-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ('etc/pam.d', 'var/lib/pam', 'usr/share/pam-configs', 'service_helpers', 'main'):
            (self.root / name).mkdir(parents=True)
        shutil.copytree(ROOT / 'password_management', self.root / 'password_management')
        logging = (ROOT / 'main/logging.sh').read_text().replace('/etc', str(self.root / 'etc'))
        (self.root / 'logging.sh').write_text(logging)
        (self.root / 'main/logging.sh').write_text(logging)
        # Real backups and file edits; replace only host-dependent permission work.
        (self.root / 'service_helpers/permissions.sh').write_text('''
secure_path() { chmod 644 "$1"; }
secure_auth_permissions() { :; }
''')
        text = (ROOT / 'password_management/pwd_policy.sh').read_text()
        text = text.replace('$EUID == 0', '0 == 0')
        for path in ('/etc', '/var/lib/pam', '/usr/share/pam-configs'):
            text = text.replace(path, str(self.root) + path)
        # Keep backup source paths valid after path substitution, too.
        (self.root / 'password_management/pwd_policy.sh').write_text(text)
        for name in ('unix', 'pwquality'):
            shutil.copy(Path('/usr/share/pam-configs') / name, self.root / 'usr/share/pam-configs' / name)
        self.env = dict(os.environ, FIXTURE=str(self.root), CP_BACKUP_ROOT=str(self.root / 'backups'),
                        DEBIAN_FRONTEND='noninteractive', DEBCONF_SYSTEMRC=str(self.root / 'debconf.conf'))
        self.env.pop('BASH_ENV', None)
        (self.root / 'debconf.conf').write_text(f'''Config: config
Templates: templates

Name: config
Driver: File
Filename: {self.root}/debconf-data

Name: templates
Driver: File
Filename: {self.root}/debconf-templates
''')
        # --force is only used to bootstrap this empty fixture, never in the policy.
        result = subprocess.run([PAM_UPDATE, '--root', str(self.root), '--force', '--enable', 'unix'],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        (self.root / 'mocks.sh').write_text(f'''
dpkg-query() {{ echo 'install ok installed'; }}
apt-get() {{ echo 'unexpected package operation' >&2; return 99; }}
pam-auth-update() {{
    if [[ "${{PAM_MODE:-}}" == refuse ]]; then return 0; fi
    {PAM_UPDATE} --root "$FIXTURE" "$@" || return
    if [[ "${{PAM_MODE:-}}" == fail ]]; then return 1; fi
}}
''')
        self.env['BASH_ENV'] = str(self.root / 'mocks.sh')

    def run_policy(self, **variables):
        result = subprocess.run(['bash', str(self.root / 'password_management/pwd_policy.sh')],
                                env=dict(self.env, **variables), text=True, capture_output=True)
        return result

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def config(self, name):
        return self.root / 'etc' / name

    def test_creates_missing_files_and_is_idempotent(self):
        self.assert_ok(self.run_policy())
        expected = {
            'login.defs': ('PASS_MAX_DAYS 90', 'PASS_MIN_DAYS 1', 'PASS_WARN_AGE 7',
                           'UID_MIN 1000', 'UID_MAX 60000', 'SYS_UID_MAX 999', 'UMASK 027'),
            'security/pwquality.conf': ('minlen = 12', 'dcredit = -1', 'ucredit = -1',
                                      'lcredit = -1', 'ocredit = -1', 'enforcing = 1'),
            'security/faillock.conf': ('deny = 5', 'fail_interval = 900', 'unlock_time = 900',
                                     'silent', 'local_users_only'),
        }
        before = {}
        for name, settings in expected.items():
            path = self.config(name)
            before[name] = path.read_text()
            for setting in settings:
                self.assertEqual(before[name].splitlines().count(setting), 1)
            self.assertEqual(path.stat().st_mode & 0o777, 0o644)
        self.assert_ok(self.run_policy())
        for name in expected:
            self.assertEqual(self.config(name).read_text(), before[name])
        manifest = '\n'.join(p.read_text() for p in (self.root / 'backups').glob('*/manifest.txt'))
        self.assertIn(f'ABSENT {self.root}/etc/login.defs', manifest)
        auth = self.config('pam.d/common-auth').read_text()
        self.assertEqual(auth.count('pam_faillock.so preauth'), 1)
        self.assertEqual(auth.count('pam_faillock.so authfail'), 1)
        # Successful Unix authentication skips both authfail and pam_deny.
        self.assertRegex(auth, r'\[success=2 default=ignore\]\s+pam_unix.so')
        self.assertIn('pam_faillock.so', self.config('pam.d/common-account').read_text())

    def test_updates_duplicates_and_preserves_unrelated_configuration(self):
        self.config('security').mkdir()
        self.config('login.defs').write_text('# keep login\nPASS_MAX_DAYS 99999\nPASS_MAX_DAYS 200\nMAIL_DIR /var/mail\nENCRYPT_METHOD YESCRYPT\n')
        self.config('security/pwquality.conf').write_text('# keep quality\nminlen=6\nminlen = 8\nbadwords = scenario')
        self.config('security/faillock.conf').write_text('# keep lockout\ndeny=0\ndeny = 99\nunlock_time = 0\nroot_unlock_time = 600\n')
        self.assert_ok(self.run_policy())
        for name, retained in (('login.defs', 'MAIL_DIR /var/mail'),
                               ('security/pwquality.conf', 'badwords = scenario'),
                               ('security/faillock.conf', 'root_unlock_time = 600')):
            self.assertIn('# keep', self.config(name).read_text())
            self.assertIn(retained, self.config(name).read_text())
        self.assertIn('ENCRYPT_METHOD YESCRYPT', self.config('login.defs').read_text())
        self.assertEqual(self.config('security/faillock.conf').read_text().count('deny'), 1)
        self.assertIn('badwords = scenario\nminlen = 12\n', self.config('security/pwquality.conf').read_text())

    def test_refused_and_partial_pam_updates_restore_stacks_and_profiles(self):
        for mode in ('refuse', 'fail'):
            with self.subTest(mode=mode):
                before = {p: p.read_bytes() for p in self.config('pam.d').glob('common-*')}
                result = self.run_policy(PAM_MODE=mode)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                for path, content in before.items():
                    self.assertEqual(path.read_bytes(), content)
                self.assertFalse((self.root / 'usr/share/pam-configs/cyberpatriot-faillock-preauth').exists())
                self.assertIn('previous stacks restored', result.stdout)

    def test_custom_quality_override_is_rejected_and_restored(self):
        path = self.config('pam.d/common-password')
        path.write_text(path.read_text().replace('retry=3', 'retry=3 minlen=6'))
        before = path.read_bytes()
        result = self.run_policy()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(path.read_bytes(), before)

    def test_real_faillock_blocks_fifth_failure_and_resets_after_success(self):
        pam_name = ctypes.util.find_library('pam')
        if not pam_name:
            self.skipTest('libpam unavailable')
        compiler = shutil.which('cc')
        if not compiler:
            self.skipTest('C compiler unavailable for isolated audit stub')
        # Emulate a kernel without audit support: never send test logins to the
        # host audit daemon, and permit testing in a sandbox without netlink.
        audit_stub = self.root / 'no-kernel-audit.so'
        compiled = subprocess.run([compiler, '-shared', '-fPIC', '-x', 'c', '-', '-o', str(audit_stub)],
            input='#include <errno.h>\nint audit_open(void) { errno = EPROTONOSUPPORT; return -1; }\n',
            text=True, capture_output=True)
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        ctypes.CDLL(str(audit_stub), mode=ctypes.RTLD_GLOBAL)
        pam = ctypes.CDLL(pam_name)
        if not hasattr(pam, 'pam_start_confdir'):
            self.skipTest('libpam has no isolated configuration support')
        self.assert_ok(self.run_policy())
        tally = self.root / 'tally'
        tally.mkdir()
        conf = self.config('security/faillock.conf')
        # Confine all lockout records to the fixture, even when tests run as root.
        conf.write_text(conf.read_text() + f'\ndir = {tally}\neven_deny_root\nnodelay\n')
        service = self.config('pam.d/policy-test')
        username = pwd.getpwuid(os.getuid()).pw_name.encode()
        callback_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int, ctypes.c_void_p,
                                         ctypes.c_void_p, ctypes.c_void_p)
        class Conversation(ctypes.Structure):
            _fields_ = [('conv', callback_type), ('data', ctypes.c_void_p)]
        callback = callback_type(lambda *_: 19)  # No password prompts in this fixture.
        conversation = Conversation(callback, None)
        pam.pam_start_confdir.argtypes = [ctypes.c_char_p, ctypes.c_char_p,
            ctypes.POINTER(Conversation), ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
        for operation in ('pam_authenticate', 'pam_acct_mgmt', 'pam_end'):
            getattr(pam, operation).argtypes = [ctypes.c_void_p, ctypes.c_int]

        def authenticate(valid):
            # Exercise the generated control flow with deterministic credential outcomes.
            auth = self.config('pam.d/common-auth').read_text()
            auth = auth.replace('pam_unix.so', 'pam_permit.so' if valid else 'pam_deny.so')
            account = self.config('pam.d/common-account').read_text().replace('pam_unix.so', 'pam_permit.so')
            service.write_text((auth + '\n' + account).replace('pam_faillock.so', f'pam_faillock.so conf={conf}'))
            handle = ctypes.c_void_p()
            self.assertEqual(pam.pam_start_confdir(b'policy-test', username,
                ctypes.byref(conversation), str(service.parent).encode(), ctypes.byref(handle)), 0)
            status = pam.pam_authenticate(handle, 0)
            if status == 0:
                status = pam.pam_acct_mgmt(handle, 0)
            pam.pam_end(handle, status)
            return status

        for _ in range(4):
            self.assertNotEqual(authenticate(False), 0)
        self.assertEqual(authenticate(True), 0)  # Success clears the preceding failures.
        for _ in range(4):
            self.assertNotEqual(authenticate(False), 0)
        self.assertEqual(authenticate(True), 0)
        for _ in range(5):
            self.assertNotEqual(authenticate(False), 0)
        self.assertNotEqual(authenticate(True), 0)  # Correct credentials cannot bypass lockout.

    def test_symlink_and_nonregular_configuration_are_rejected(self):
        outside = self.root / 'outside'
        outside.write_text('do not change\n')
        path = self.config('login.defs')
        path.symlink_to(outside)
        self.assertNotEqual(self.run_policy().returncode, 0)
        self.assertEqual(outside.read_text(), 'do not change\n')
        path.unlink()
        path.mkdir()
        self.assertNotEqual(self.run_policy().returncode, 0)
        path.rmdir()
        self.config('security').symlink_to(self.root, target_is_directory=True)
        self.assertNotEqual(self.run_policy().returncode, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
