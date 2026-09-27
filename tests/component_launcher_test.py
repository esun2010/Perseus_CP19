"""Run launcher selection/execution against stub tasks, never host services."""
from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ComponentLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'service_helpers').mkdir()
        (self.root / 'input').mkdir()
        (self.root / 'service_helpers/task_paths.sh').write_text((ROOT / 'service_helpers/task_paths.sh').read_text())
        (self.root / 'service_helpers/distribution.sh').write_text(
            'load_distribution() { CP_DISTRO=debian; }\n')
        (self.root / 'service_helpers/critical_services.sh').write_text(
            (ROOT / 'service_helpers/critical_services.sh').read_text())
        (self.root / 'logging.sh').write_text('log() { echo "$*"; }; init_logging() { :; }\n')

    def launch(self, launcher, selection, critical='ufw\n', args=False,
               full=False, failing='', expected=0):
        (self.root / 'input/critical_services.txt').write_text(critical)
        script = (ROOT / launcher).read_text()
        marker = '[[ $(id -u) == 0 ]]'
        if full:
            self.assertEqual(launcher, 'run_all_services.sh')
            script = script.replace(marker, '[[ 0 == 0 ]]')
        else:
            script = script.split(marker)[0] + 'exit 0\n'
        for path in re.findall(r'\[\w+\]=([\w/+.-]+\.sh)', script):
            self.assertTrue((ROOT / path).is_file(), path)
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(f'echo "{path}" >> "{self.root}/calls"\nexit {1 if path == failing else 0}\n')
        (self.root / launcher).write_text(script)
        cmd = ['bash', str(self.root / launcher)]
        if args:
            cmd += selection.split()
        env = dict(os.environ, RUN_SERVICES='1')
        result = subprocess.run(cmd, input='' if args else selection + '\n',
                                text=True, capture_output=True, env=env)
        self.assertEqual(result.returncode, expected, result.stderr + result.stdout)
        return [line.removeprefix('Selected: ') for line in
                result.stdout.splitlines() if line.startswith('Selected: ')]

    def test_normal_all_never_selects_services(self):
        selected = self.launch('run_all.sh', 'all', critical='invalid\n')
        self.assertTrue(selected)
        self.assertFalse(any(p.startswith('services/') for p in selected))
        self.assertIn('misc/kernel.sh', selected)

    def test_system_components_select_one_consolidated_task(self):
        self.assertEqual(self.launch('run_all.sh', 'sys nss openssl grub selinux iptables dhclient'),
                         ['misc/system_hardening.sh'])
        self.assertEqual(self.launch('run_all.sh', 'system_hardening'),
                         ['misc/system_hardening.sh'])
        selected = self.launch('run_all.sh', 'all')
        self.assertEqual(selected.count('misc/system_hardening.sh'), 1)

    def test_normal_rejects_service_keywords(self):
        self.launch('run_all.sh', 'ssh', expected=1)

    def test_extended_manual_selection(self):
        self.assertEqual(self.launch('run_all_services.sh', 'rsyslog chrony'),
                         ['services/reconcile.sh', 'services/extended/chrony.sh',
                          'services/extended/rsyslog.sh'])

    def test_role_gating_and_aliases(self):
        self.assertEqual(self.launch('run_all_services.sh', 'sssd nfs-server cupsd',
                                     'nfs-server\ncupsd\n'),
                         ['services/reconcile.sh', 'services/nfs-server.sh', 'services/cupsd.sh'])

    def test_auto_run_only_critical_and_firewall_last(self):
        expected = ['services/reconcile.sh', 'services/ssh.sh',
                    'services/extended/rsyslog.sh', 'services/ufw.sh']
        for selection in ('auto', 'auto_run'):
            self.assertEqual(self.launch('run_all_services.sh', selection,
                                         'ufw\nrsyslog\nssh\n'), expected)

    def test_normal_auto_runs_all(self):
        self.assertEqual(self.launch('run_all.sh', 'auto'),
                         self.launch('run_all.sh', 'all'))

    def test_both_launchers_reject_arguments(self):
        for launcher in ('run_all.sh', 'run_all_services.sh'):
            self.launch(launcher, 'auto', args=True, expected=1)

    def test_auto_run_none_only_reconciles(self):
        self.assertEqual(self.launch('run_all_services.sh', 'auto', 'none\n'),
                         ['services/reconcile.sh'])

    def test_failure_blocks_firewall_and_progress_is_independent(self):
        (self.root / '.run_all_status').write_text('ker\n')
        (self.root / '.run_all_services_status').write_text('ssh\nufw\n')
        self.launch('run_all_services.sh', 'auto', 'ssh\nufw\n',
                    full=True, failing='services/ssh.sh', expected=1)
        self.assertEqual((self.root / 'calls').read_text().splitlines(),
                         ['services/reconcile.sh', 'services/ssh.sh'])
        self.assertEqual((self.root / '.run_all_status').read_text(), 'ker\n')
        self.assertEqual((self.root / '.run_all_services_status').read_text(), 'svc\n')
        (self.root / 'calls').unlink()
        self.launch('run_all_services.sh', '', 'ssh\nufw\n', full=True)
        calls = (self.root / 'calls').read_text().splitlines()
        self.assertLess(calls.index('services/ssh.sh'), calls.index('services/ufw.sh'))
        state = (self.root / '.run_all_services_status').read_text().splitlines()
        self.assertIn('ssh', state)
        self.assertIn('ufw', state)

    def test_reconciliation_failure_stops_service_execution(self):
        self.launch('run_all_services.sh', 'auto', 'ssh\n', full=True,
                    failing='services/reconcile.sh', expected=1)
        self.assertEqual((self.root / 'calls').read_text().splitlines(), ['services/reconcile.sh'])


if __name__ == '__main__':
    unittest.main()
