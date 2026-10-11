#!/usr/bin/env python3
"""Native operations are mocked; all configuration lives in a temporary tree."""
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[1]
BSD = 'FreeBSD' in ROOT.name

class StartupRepairTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.etc = self.base / 'etc'
        for name in ('apt/sources.list.d',): (self.etc / name).mkdir(parents=True)
        (self.etc/'environment').write_text('LANG=en_US.UTF-8\nPATH=./bad\n')
        (self.etc/'os-release').write_text('ID=ubuntu\nVERSION_CODENAME=noble\n')
        (self.etc/'apt/sources.list').write_text('broken-original\n')
        self.keyring=self.base/'keyring'; self.keyring.write_text('fixture')
        text=(ROOT/'service_helpers/startup_repair.sh').read_text()
        text=text.replace('/etc',str(self.etc)).replace('/usr/share/keyrings/ubuntu-archive-keyring.gpg',str(self.keyring))
        # Also isolate all scan roots; no host files are inspected or changed.
        for name in ('/var/lib/dpkg','/var/lib/apt','/var/cache/apt','/var/db/pkg','/usr/local'+str(self.etc)):
            text=text.replace(name,str(self.base/'nonexistent'))
        self.helper=self.base/'repair.sh'; self.helper.write_text(text)
        if not BSD:
            helper=(ROOT/'service_helpers/distribution.sh').read_text().replace('/etc',str(self.etc)).replace('/usr/share/keyrings/ubuntu-archive-keyring.gpg',str(self.keyring))
            helper=helper.replace('$root/input/distribution.txt',str(ROOT/'input/distribution.txt'))
            (self.base/'distribution.sh').write_text(helper)
    def run_script(self, body):
        script='''set -euo pipefail
source "$HELPER"
log() { :; }
backup_system_paths() {
    printf 'backup %s\\n' "$*" >> "$CALLS"
    SYSTEM_BACKUP_DIR="$BASE/backup"
    mkdir -p "$SYSTEM_BACKUP_DIR/files$ETC"
    cp -a "$ETC/apt" "$SYSTEM_BACKUP_DIR/files$ETC/" 2>/dev/null || true
}
''' + body
        import os
        env=dict(os.environ,HELPER=str(self.helper),BASE=str(self.base),ETC=str(self.etc),CALLS=str(self.base/'calls'))
        return subprocess.run(['bash','-c',script],env=env,text=True,capture_output=True)
    @unittest.skipIf(BSD,'Ubuntu-specific')
    def test_path_preserves_other_settings(self):
        result=self.run_script('PATH=/usr/bin:/bin; repair_persistent_path')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.etc/'environment').read_text(),'LANG=en_US.UTF-8\nPATH="/usr/bin:/bin"\n')
    @unittest.skipIf(BSD,'Ubuntu-specific')
    def test_network_failure_preserves_sources(self):
        result=self.run_script('apt-get() { echo "Temporary failure resolving server"; return 100; }; repair_apt_repositories')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.etc/'apt/sources.list').read_text(),'broken-original\n')
    @unittest.skipIf(BSD,'Ubuntu-specific')
    def test_repository_repair_and_rollback(self):
        for final_failure in (False,True):
            with self.subTest(final_failure=final_failure):
                (self.etc/'apt/sources.list').write_text('broken-original\n')
                result=self.run_script('''
count=0
apt-get() {
    count=$((count+1))
    if ((count == 1)); then echo 'Malformed entry'; return 100; fi
    if ((count == 2)); then return 0; fi
    return '''+('100' if final_failure else '0')+'''
}
dpkg() { echo amd64; }
repair_apt_repositories
''')
                self.assertEqual(result.returncode == 0,not final_failure,result.stderr)
                if final_failure:
                    self.assertEqual((self.etc/'apt/sources.list').read_text(),'broken-original\n')
                else:
                    self.assertFalse((self.etc/'apt/sources.list').exists())
                    self.assertIn('Signed-By:',(self.etc/'apt/sources.list.d/cyberpatriot-repaired.sources').read_text())
    def test_flags_backed_up_before_cleared(self):
        body='''
find() { printf '%s\\0' "$ETC/environment"; }
'''
        if BSD:
            body+='''stat() { echo uchg; }
chflags() { printf 'clear\\n' >> "$CALLS"; }
pkg() { :; }
startup_repair
'''
        else:
            body+='''lsattr() { echo '----i--------- fixture'; }
chattr() { printf 'clear\\n' >> "$CALLS"; }
repair_immutable_files
'''
        result=self.run_script(body)
        self.assertEqual(result.returncode,0,result.stderr)
        calls=(self.base/'calls').read_text().splitlines()
        self.assertTrue(calls[0].startswith('backup '))
        self.assertEqual(calls[1],'clear')
    def test_repair_failure_blocks_later_steps(self):
        if BSD:
            body='find() { return 1; }; pkg() { touch "$BASE/later"; }; startup_repair'
        else:
            body='repair_immutable_files() { return 1; }; repair_persistent_path() { touch "$BASE/later"; }; startup_repair'
        result=self.run_script(body)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.base/'later').exists())


if __name__=='__main__': unittest.main(verbosity=2)
