#!/usr/bin/env python3
"""Two-pass fixtures: native account commands are replaced; media lives in /tmp."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest
from fixture_sources import read_source, SHARED
ROOT=Path(__file__).resolve().parents[1]
BSD='FreeBSD' in ROOT.name

class SecondPassTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='cp-second-pass-')
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        for name in ('service_helpers','input','log','etc','media','groups'):
            (self.root/name).mkdir()
        (self.root/'logging.sh').write_text(read_source('logging.sh'))
        for name in ('second_pass_accounts.sh','second_pass_media.sh'):
            text=read_source('service_helpers/' + name)
            text=text.replace('/usr/local/etc','@@ETC@@').replace('/etc/sudoers','@@ETC@@/sudoers').replace('/etc/doas.conf','@@ETC@@/doas.conf').replace('@@ETC@@',str(self.root/'etc'))
            text=text.replace('/usr/share/polkit-1/rules.d',str(self.root/'no-polkit')).replace('/usr/local/share/polkit-1/rules.d',str(self.root/'no-polkit'))
            (self.root/'service_helpers'/name).write_text(text)
        (self.root/'input/auth_users.txt').write_text('alice\nbob\n')
        (self.root/'input/auth_admins.txt').write_text('alice\n')
        (self.root/'passwd').write_text('root:*:0:0::/root:/bin/sh\nalice:*:1000:1000::/home/alice:/bin/sh\nbob:*:1001:1001::/home/bob:/bin/sh\ncharlie:*:1002:1002::/home/charlie:/bin/sh\ndaemon:*:2:2::/nonexistent:/usr/sbin/nologin\n')
        (self.root/'etc/sudoers').write_text('root ALL=(ALL:ALL) ALL\nalice ALL=(ALL:ALL) ALL\nbob ALL=(ALL:ALL) ALL\n')
        for user in ('alice','bob','charlie','daemon'):
            (self.root/'groups'/user).write_text(user+(' wheel' if BSD else ' sudo') if user in ('alice','bob') else user)
        self.prelude=r'''
set -euo pipefail
source "$FIXTURE/service_helpers/second_pass_media.sh"
ACCOUNT_PLATFORM="$NATIVE_PLATFORM"
LOG_FILE="$FIXTURE/log/test(2).txt"
local_account_records() { cat "$FIXTURE/passwd"; }
backup_account_databases() {
    [[ "${FAIL_BACKUP:-no}" != yes ]] || return 1
    backup_system_paths "$FIXTURE/passwd" "$FIXTURE/groups"
}
id() {
    case "$1" in
        -nG) cat "$FIXTURE/groups/$2" ;;
        -gn) awk '{print $1}' "$FIXTURE/groups/$2" ;;
        *) return 1 ;;
    esac
}
sudo() {
    if [[ "${*: -1}" == bob ]]; then echo '    (ALL : ALL) ALL'; return 0; fi
    echo 'User is not allowed to run sudo'; return 1
}
visudo() { [[ "${BAD_SUDO:-no}" != yes ]]; }
getent() { [[ "$1" == group ]]; }
assert_backup() { [[ -f "$SYSTEM_BACKUP_DIR/files$FIXTURE/passwd" ]]; }
usermod() {
    assert_backup
    printf '%s\n' "$*" >> "$FIXTURE/changes"
    [[ "$1" == -G ]] || return 1
    printf '%s' "${2//,/ }" > "$FIXTURE/groups/$3"
}
userdel() {
    assert_backup
    printf 'delete %s\n' "$1" >> "$FIXTURE/changes"
    awk -F: -v user="$1" '$1!=user' "$FIXTURE/passwd" > "$FIXTURE/passwd.new"
    mv "$FIXTURE/passwd.new" "$FIXTURE/passwd"
}
pw() {
    case "$1" in
        userdel) userdel "$2" ;;
        usermod) usermod "$3" "$4" "$2" ;;
        *) return 1 ;;
    esac
}
# Use the host's stat for temporary media identities in FreeBSD command fixtures.
media_signature() { command stat -c '%d:%i:%s:%Y:%Z' -- "$1"; }
if [[ "$NATIVE_PLATFORM" == freebsd ]]; then
    find() { command find "$MEDIA_ROOT" -type f \( -iname '*.mp3' -o -iname '*.mov' -o -iname '*.mp4' \) -print0; }
fi
'''
    def run_script(self,body,**extras):
        env=dict(os.environ,FIXTURE=str(self.root),NATIVE_PLATFORM='freebsd' if BSD else 'linux',CP_BACKUP_ROOT=str(self.root/'backups'),MEDIA_ROOT=str(self.root/'media'))
        env.pop('SUDO_USER',None);env.pop('DOAS_USER',None);env.update(extras)
        return subprocess.run(['bash','-c',self.prelude+'\n'+body],env=env,text=True,capture_output=True)
    def ok(self,result): self.assertEqual(result.returncode,0,result.stdout+result.stderr)
    def test_account_first_pass_is_read_only_and_second_applies(self):
        original=(self.root/'passwd').read_text()
        self.ok(self.run_script('account_review'))
        self.assertEqual((self.root/'passwd').read_text(),original)
        self.assertFalse((self.root/'changes').exists())
        self.assertIn('charlie\t1002',(self.root/'log/unauth_users(2).txt').read_text())
        self.assertIn('bob\t1001',(self.root/'log/unauth_admins(2).txt').read_text())
        self.ok(self.run_script('account_cleanup'))
        self.assertNotIn('charlie:',(self.root/'passwd').read_text())
        self.assertIn('alice:',(self.root/'passwd').read_text())
        self.assertEqual((self.root/'groups/bob').read_text(),'bob')
        self.assertIn('bob ALL=(ALL:ALL) !ALL',(self.root/'etc/sudoers').read_text())
    def test_low_uid_and_uid_zero_are_reported_but_root_not_deleted(self):
        with (self.root/'passwd').open('a') as f:f.write('evilroot:*:0:0::/root:/bin/sh\nlowuser:*:900:900::/home/lowuser:/bin/sh\n')
        self.ok(self.run_script('account_review'))
        text=(self.root/'log/unauth_users(2).txt').read_text()
        self.assertIn('evilroot\t0',text);self.assertIn('lowuser\t900',text)
        result=self.run_script('account_cleanup')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.root/'changes').exists())
    def test_current_allowlist_protects_newly_authorized_user(self):
        self.ok(self.run_script('account_review'))
        with (self.root/'input/auth_users.txt').open('a') as f:f.write('charlie\n')
        self.ok(self.run_script('account_cleanup'))
        self.assertIn('charlie:',(self.root/'passwd').read_text())
    def test_account_backup_failure_prevents_native_mutation(self):
        self.ok(self.run_script('account_review'))
        result=self.run_script('account_cleanup',FAIL_BACKUP='yes')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.root/'changes').exists())
    def test_changed_account_identity_blocks_cleanup(self):
        self.ok(self.run_script('account_review'))
        p=self.root/'passwd';p.write_text(p.read_text().replace('charlie:*:1002:','charlie:*:2002:'))
        result=self.run_script('account_cleanup')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.root/'changes').exists())
    def test_media_first_pass_retains_and_second_backs_up_deletes(self):
        media=self.root/'media/first song.mp3';media.write_bytes(b'music')
        keep=self.root/'media/keep.mp4';keep.write_bytes(b'required')
        self.ok(self.run_script('media_review'))
        self.assertTrue(media.exists());self.assertTrue(keep.exists())
        p=self.root/'log/media_files(2).txt';p.write_text('\n'.join(l for l in p.read_text().splitlines() if 'keep.mp4' not in l)+'\n')
        self.ok(self.run_script('media_cleanup'))
        self.assertFalse(media.exists());self.assertTrue(keep.exists())
        self.assertTrue(any(p.read_bytes()==b'music' for p in (self.root/'backups').rglob('first song.mp3')))
    def test_changed_media_and_failed_backup_do_not_delete(self):
        media=self.root/'media/test.mp3';media.write_bytes(b'first')
        self.ok(self.run_script('media_review'))
        media.write_bytes(b'changed size')
        result=self.run_script('media_cleanup')
        self.assertNotEqual(result.returncode,0);self.assertTrue(media.exists())
        self.ok(self.run_script('media_review'))
        result=self.run_script('backup_system_paths() { return 1; }; media_cleanup')
        self.assertNotEqual(result.returncode,0);self.assertTrue(media.exists())
    def test_empty_allowlist_blocks_audit_and_deletion(self):
        (self.root/'input/auth_admins.txt').write_text('')
        result=self.run_script('account_review')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.root/'log/unauth_users(2).txt').exists())

    def test_second_launcher_requires_reviews_and_stops_on_task_failure(self):
        (self.root/'service_helpers/distribution.sh').write_text('load_distribution() { CP_DISTRO=freebsd; }\n')
        (self.root/'run_all_2.sh').write_text(read_source('run_all_2.sh'))
        helper=self.root/'service_helpers/second_pass_accounts.sh'
        with helper.open('a') as f:f.write('\naccount_platform_init() { ACCOUNT_PLATFORM=linux; }\n')
        result=self.run_script('bash "$FIXTURE/run_all_2.sh"')
        self.assertNotEqual(result.returncode,0)
        for name in ('unauth_users(2).txt','unauth_admins(2).txt','media_files(2).txt'):
            (self.root/'log'/name).write_text('# reviewed\n')
        for directory in ('user_management','rm_stuff'):(self.root/directory).mkdir()
        user_task=self.root/'user_management/user_management_2.sh'
        user_task.write_text('echo users >> "$FIXTURE/run-calls"\nexit 1\n')
        (self.root/'rm_stuff/rm_mp3+_2.sh').write_text('echo media >> "$FIXTURE/run-calls"\n')
        result=self.run_script('bash "$FIXTURE/run_all_2.sh"')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.root/'run-calls').read_text(),'users\n')
        user_task.write_text('echo users >> "$FIXTURE/run-calls"\n')
        self.ok(self.run_script('bash "$FIXTURE/run_all_2.sh"'))
        self.assertEqual((self.root/'run-calls').read_text(),'users\nusers\nmedia\n')
        self.assertEqual((self.root/'all_logs(2).txt').stat().st_mode & 0o777,0o600)

    def test_symlink_media_is_not_followed(self):
        media=self.root/'media/test.mp3';media.write_bytes(b'music')
        self.ok(self.run_script('media_review'))
        target=self.root/'required.mp3';target.write_bytes(b'required')
        media.unlink();media.symlink_to(target)
        result=self.run_script('media_cleanup')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(target.read_bytes(),b'required')

if __name__=='__main__': unittest.main(verbosity=2)
