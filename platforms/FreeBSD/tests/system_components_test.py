"""FreeBSD hardening fixtures runnable on Linux; no host changes."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from fixture_sources import read_source, SHARED

ROOT = Path(__file__).resolve().parents[1]


class ComponentsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.system = self.base / 'system'
        self.system.mkdir()
        self.helpers = self.base / 'service_helpers'
        self.helpers.mkdir()
        for name in ['platform.sh', 'permissions.sh', 'path_hardening.sh',
                     'system_components.sh', 'kernel_network.sh']:
            text = read_source('service_helpers/' + name)
            text = re.sub(r'/(?:usr/local|usr/share|etc|boot)(?=/|\b)',
                          lambda m: str(self.system) + m[0], text)
            text = text.replace('/dev/pf', str(self.system / 'dev/pf'))
            (self.helpers / name).write_text(text)
        (self.base / 'logging.sh').write_text('')
        self.prefix = f'''source '{self.helpers}/system_components.sh'
require_freebsd_root() {{ :; }}
init_logging() {{ :; }}
log() {{ echo "$*"; }}
chown() {{ :; }}
audit_chmod() {{ chmod "$1" "$2"; }}
backup_system_paths() {{ SYSTEM_BACKUP_DIR='{self.base}/backup'; mkdir -p "$SYSTEM_BACKUP_DIR"; }}
audit_file_change() {{ shift; "$@"; }}
stat() {{
    case "$2" in
        %Su) echo root ;;
        %Sg) echo wheel ;;
        %Lp) command stat -c %a "${{@: -1}}" ;;
        *) return 1 ;;
    esac
}}
'''

    def file(self, path, content='retained\n', mode=0o666):
        file = self.system / path.lstrip('/')
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(content)
        file.chmod(mode)
        return file

    def run_shell(self, text, expected=0):
        result = subprocess.run(['bash', '-euo', 'pipefail', '-c', self.prefix + text],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout

    def test_native_configs_and_unsupported_selinux(self):
        nss = self.file('/etc/nsswitch.conf')
        dhcp = self.file('/etc/dhclient.conf')
        hook = self.file('/etc/dhclient-enter-hooks', mode=0o777)
        boot = self.file('/boot/loader.conf')
        self.run_shell('timeout() { return 0; }; component_main nss; component_main dhclient; component_main grub')
        for file, mode in [(nss, 0o644), (dhcp, 0o644), (hook, 0o755), (boot, 0o600)]:
            self.assertEqual(file.stat().st_mode & 0o777, mode)
            self.assertEqual(file.read_text(), 'retained\n')
        out = self.run_shell('secure_path() { return 99; }; component_main selinux')
        self.assertIn('NOT APPLICABLE', out)

    def test_user_keys_startup_and_trust(self):
        home = self.system / 'home/alice'
        files = [self.file('/home/alice/' + name) for name in
                 ['.bashrc', '.cshrc', '.history', '.ssh/authorized_keys', '.ssh/id_ed25519']]
        rc = self.file('/etc/rc.d/sshd', mode=0o777)
        cert = self.file('/usr/local/share/certs/site.crt')
        self.run_shell(f'secure_login_home "{home}" root; secure_native_startup; secure_native_trust')
        for file in files:
            self.assertEqual(file.stat().st_mode & 0o777, 0o600)
        self.assertEqual(rc.stat().st_mode & 0o777, 0o755)
        self.assertEqual(cert.stat().st_mode & 0o777, 0o644)
        external = self.file('/external')
        files[-1].unlink()
        files[-1].symlink_to(external)
        self.run_shell(f'if secure_login_home "{home}" root; then exit 1; fi')
        self.assertEqual(external.stat().st_mode & 0o777, 0o666)

    def test_openssl_preserves_configuration_and_protects_keys(self):
        config = self.file('/etc/ssl/openssl.cnf')
        key = self.file('/etc/ssl/private/server.key')
        self.run_shell('openssl() { [[ "$*" == version || "$*" == "ciphers -s" ]]; }; component_main openssl')
        self.assertEqual(config.stat().st_mode & 0o777, 0o644)
        self.assertEqual(key.stat().st_mode & 0o777, 0o640)
        self.assertEqual(key.read_text(), 'retained\n')

    def test_netfilter_only_queries_native_firewall(self):
        self.run_shell('sysctl() { echo 1; }; ipfw() { [[ "$*" == "-a list" ]]; }; component_main netfilter')
        self.assertTrue((self.base / 'backup/ipfw.rules').exists())

    def test_forwarding_runtime_sysctl_and_rc_persistence(self):
        rc = self.file('/etc/rc.conf', 'gateway_enable=YES\nipv6_gateway_enable=YES\n')
        override = self.file('/etc/rc.conf.local', 'gateway_enable=YES\n')
        sysconf = self.file('/etc/sysctl.conf', 'net.inet.ip.forwarding=1\nnet.inet6.ip6.forwarding=1\n')
        kernel = (ROOT / 'misc/kernel.sh').read_text()
        funcs = kernel[kernel.index('write_sysctl_setting()'):kernel.index('source "$SCRIPT_DIR/../service_helpers/kernel_network.sh"')]
        funcs = funcs.replace('/etc/', str(self.system / 'etc') + '/')
        self.run_shell(f'''
source '{self.helpers}/kernel_network.sh'
SYSCTL_FILE='{sysconf}'
{funcs}
declare -A live=([net.inet.ip.forwarding]=1 [net.inet6.ip6.forwarding]=1)
sysctl() {{
    if [[ "$1" == -n ]]; then echo "${{live[$2]}}";
    else live["${{1%%=*}}"]="${{1#*=}}"; fi
}}
sysrc() {{
    local file='{rc}' key
    if [[ "$1" == -f ]]; then file="$2"; shift 2; fi
    if [[ "$1" == -n ]]; then
        awk -F= -v key="$2" '$1==key {{v=$2}} END {{print v}}' "$file"
    else
        for key in "$@"; do echo "$key" >> "$file"; done
    fi
}}
disable_forwarding
disable_forwarding
[[ "${{live[net.inet.ip.forwarding]}}" == 0 && "${{live[net.inet6.ip6.forwarding]}}" == 0 ]]
''')
        self.assertEqual(sysconf.read_text().splitlines(),
                         ['net.inet.ip.forwarding=0', 'net.inet6.ip6.forwarding=0'])
        for file in (rc, override):
            self.assertIn('gateway_enable=NO', file.read_text())
            self.assertIn('ipv6_gateway_enable=NO', file.read_text())

    def test_missing_required_forwarding_control_fails(self):
        self.run_shell(f'''source '{self.helpers}/kernel_network.sh'
sysctl() {{ return 1; }}
sysrc() {{ return 99; }}
if disable_forwarding; then exit 1; fi
''')


if __name__ == '__main__':
    unittest.main()
