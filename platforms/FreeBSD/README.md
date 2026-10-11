# FreeBSD implementation for the shared toolkit

This toolkit configures **native FreeBSD hosts and virtual machines**. FreeBSD
is a separate operating system from Linux. The scripts use FreeBSD `pkg`,
`service`, `sysrc`, `pw`, OpenPAM, login classes, BSD utilities, and PF. Hardening
tasks refuse to run on other operating systems or inside a jail.

The normal FreeBSD base-system layout and packages under `/usr/local` are
required. Bash 4.3 or newer is required; the bootstrap installs the FreeBSD Bash
package. Neither sudo nor GNU coreutils is required to launch the toolkit.

## Shared project layout

All paths and commands below are relative to the repository root. Clone the
whole project: this folder is a native backend, not a standalone copy.
`input/`, `log/`, `all_logs.txt`, all three `run_all*.sh` launchers, account/media
review, common service policy, and logging are shared with Linux. Changes to
those root files apply on both platforms. FreeBSD-specific operations stay here.

## Start on FreeBSD

1. Copy or clone the entire repository onto FreeBSD, retaining LF line endings.
2. Edit these scenario lists first (one entry per line; comments are allowed):
   - `input/auth_users.txt`: authorized local login names.
   - `input/auth_admins.txt`: existing authorized administrator names.
   - `input/critical_services.txt`: required services and extra firewall ports.
3. Open a root shell using `su -`, change into the repository root, and run:

   ```sh
   sh bootstrap.sh
   ```

The bootstrap installs `pkg` and Bash if needed, then opens the interactive menu.
Installation and upgrades require access to configured package repositories.
Once Bash is installed, run the launcher or an individual task as root with:

```sh
/usr/local/bin/bash run_all.sh
/usr/local/bin/bash run_all_services.sh
/usr/local/bin/bash services/ssh.sh
```

Only `bootstrap.sh` uses base `/bin/sh`. Other `.sh` files use Bash. Helpers are
sourced by tasks; the password-policy task invokes its `.awk` helpers. Executable
file bits are not necessary when using the commands above. Keep console or root
access available while changing administrator access or firewall rules.

## Menu and progress

Enter keywords separated by spaces, `all` to rerun every eligible task, or a blank
line to resume unfinished tasks. Command-line task arguments are not supported.
Before general tasks run, `run_all.sh` executes `pkg update` and `pkg upgrade`;
the upgrade retains its normal confirmation prompt. This is not a FreeBSD release
upgrade tool; maintain the base system using the method appropriate to your image.

| Keyword | Task |
| --- | --- |
| `mal` | Inspect packages, scheduled jobs, startup files, processes, sockets, and temporary files. |
| `ker` | Configure native sysctl settings, temporary mounts, and administrator policy. |
| `log` | Disable the local guest account and optional LightDM guest access. |
| `pol` | Set native passwd PAM quality checks and default login-class password aging. |
| `usr` | Audit local users and wheel/UID-zero administrators without deleting accounts. |
| `adm` | Prompt separately to reset each authorized administrator's password. |
| `mp3` | Inventory MP3/MOV/MP4 files for review; only run_all_2.sh deletes reviewed files. |
| `pkg` | Review installed packages; remove only after typing `REMOVE`. |
| `per` | Apply native file permissions and report world-writable paths. |
| `sys` | Run the combined native system-component checks described below. |

Service keywords below belong to `run_all_services.sh`:

| Keyword | Task |
| --- | --- |
| `ssh` | Configure and enable base-system `sshd`. |
| `apache2` or `apache24` | Install/configure the `apache24` package and service. |
| `vsftpd` | Install/configure `vsftpd-ssl` and the `vsftpd` service. |
| `pf` | Configure the native PF firewall. |

Legacy aliases: `cra` means `mal`, and `ufw` means `pf`. The old
`services/ufw.sh` filename forwards to PF; it never installs or invokes UFW.

Services run only if listed as critical, even when explicitly selected. Selecting
a service also selects PF if PF is critical. Selecting PF configures listed
services first to discover their listener ports. A service failure blocks PF.

Successful general tasks are stored in `.run_all_status.freebsd`, and service
tasks in `.run_all_services_status.freebsd`, at the repository root. Linux progress in
`.run_all_status` is ignored. The menu shows `ran`, `not_run`, or `N/a` for unlisted
services. Explicit selections rerun completed tasks. Failed or cancelled tasks
remain retryable. Delete `.run_all_status.freebsd` to start a new scenario.
Other general tasks continue after an individual failure; check the final summary.

## Services and firewall

Example `input/critical_services.txt`:

```text
ssh
apache24
vsftpd
pf
allow 8443/tcp
allow 5000:5010/udp
```

Names are case-insensitive. Aliases include `sshd`, `apache2`, `http`, `httpd`,
`https`, `vsftp`, `ftp`, and `ufw`. Use `none` when no supported services are
required, without mixing it with service names. Unknown names and invalid ports
stop the launcher. Configure other services separately and add their firewall
ports explicitly. The shared list enables the platform firewall by default; `ufw` selects PF on
FreeBSD. Edit the list for your scenario.

PF discovers supported live listeners and preserves the current SSH server port
when `SSH_CONNECTION` is available. It uses deny-incoming/allow-outgoing rules
with stateful connections, loopback, and IPv4/IPv6 control traffic. It validates
rules before loading and does not flush connection states. Opening a port does
not install or configure a service.

Existing nonempty PF configuration not managed by this toolkit is preserved.
The task writes a private `/etc/pf.cyberpatriot.*` candidate and stops for manual
integration. Review NAT, VPN, routing, jails, anchors, and custom access rules in
that case. Linux UFW rules are not automatically translated.

SSH applies global root-login and empty-password restrictions, preserving ports,
keys, authentication methods, and Match sections. Review Match-specific overrides.
Apache limits version disclosure and disables TRACE while retaining existing
sites, content, listeners, and TLS. The `https` alias does not provision TLS.
Custom SSH `-f` files or Apache profiles/configuration overrides require manual
configuration; the tasks use the standard configuration paths.

FTP disables anonymous access, permits local accounts, logs transfers, and uses
passive ports 40000–40100. It preserves upload policy. Explicit FTPS is required
by default, with a self-signed certificate clients must trust. The FreeBSD
`vsftpd` rc script requires standalone `listen=YES`, so this task configures an
IPv4 listener; add a separate IPv6 service configuration when the scenario
requires it. For a scenario that requires plaintext FTP:

```sh
env VSFTPD_TLS_REQUIRED=NO /usr/local/bin/bash run_all_services.sh
```

Filesystem permissions, `/etc/ftpusers`, NAT, and client settings still apply.
SSH and Apache validate before reload. Failed service startup restores the prior
configuration and service state; vsftpd uses startup checks because it has no
configuration-validation-only command.

## Accounts and hardening

The kernel task validates a nonempty administrator list, installs/configures sudo,
and applies password-required grants for root and those users in
`/usr/local/etc/sudoers`. Previous sudo group grants and includes become inactive.
It integrates with polkit only when installed. Wheel, `su`, doas, and independent
polkit action rules need their own review; this is not a complete privilege audit.
Backups and policy changes are logged. For recovery, restore the saved sudoers as
root with mode `0440` and validate it using `visudo -c`.

Native sysctl settings are probed before application. Dedicated temporary mounts
are handled using FreeBSD UFS/tmpfs mount options or ZFS dataset properties.
The script does not apply Linux sysctls or create a `/dev/shm` mount.

Password policy uses base `pam_passwdqc.so` in `/etc/pam.d/passwd` for a 12-character
minimum and strength checks, including root. The default login class gets a
90-day lifetime and 7-day warning; `cap_mkdb` rebuilds `login.conf.db`. Aging takes
effect after the next password change. Other login classes, existing expiration
dates, and other PAM service stacks are retained. Unsupported custom passwd
stacks stop before active policy changes. Administrator resets use interactive
`passwd`; passwords are never hardcoded or written to the audit log.

The user audit includes interactive local accounts at every UID and flags UID-zero aliases. Fill in both allowlists before running; authorized administrators also count as authorized users. Non-login service accounts are preserved unless separately flagged for unauthorized administrator access.

Both `per` (file permissions) and `pol` (password policy) protect the following
native paths. Linux-only paths are not created on FreeBSD:

| Requested Linux path | FreeBSD coverage |
| --- | --- |
| `/etc/passwd`, `/etc/group` | Both databases are owned by `root:wheel`, at most `0644`; `/etc/pwd.db` receives the same protection. |
| `/etc/shadow` | Native `/etc/master.passwd` and `/etc/spwd.db` are owned by `root:wheel`, at most `0600`. |
| `/usr/lib64/security` | Native PAM modules `/usr/lib/pam_*.so*` and `/usr/local/lib/pam_*.so*` are root-owned, at most `0755`, preserving existing execute bits. |
| `/etc/pam.d` | Protect `/etc/pam.d` and `/usr/local/etc/pam.d`: root-owned files at most `0644`, directories at most `0755`. |
| `/etc/security` | Native policy uses `/etc/login.conf`, `/etc/login.conf.db`, and `/etc/pam.d/passwd`; `pol` configures password quality and aging. |
| `/var/log/secure` | Protect native `/var/log/auth.log` and its existing rotations at most `0640`. |

The core `/etc/passwd`, `/etc/group`, and `/etc/master.passwd` files must exist as
regular files; missing or linked databases stop the task. File-permission
hardening preserves account records and password hashes. File ownership and
permission changes require backups first. Absent optional paths and logs are
not fabricated. See the [FreeBSD PAM documentation](https://docs.freebsd.org/en/articles/pam/)
and [password policy guidance](https://docs.freebsd.org/en/books/handbook/security/).
Run `python3 platforms/FreeBSD/tests/auth_permissions_test.py` for isolated coverage, repeat-run,
backup-failure, and symlink checks without changing host authentication.

Permission handling protects `/etc/master.passwd` and `/etc/spwd.db`, uses native
`/etc/pam.d` and `/usr/local/etc` paths, retains groups and stricter permissions
where appropriate, and skips symbolic links in configuration trees. Review
external configuration targets separately. Home permissions are adjusted only
for local interactive accounts using `/home` or `/usr/home`.

Package removal protects toolkit packages, supported critical services, base
packages, and packages with reverse dependencies. It does not run autoremove.
Media cleanup skips pseudo-filesystems, remote/read-only mounts, and ZFS snapshot
directories; use `MEDIA_ROOT` to narrow the search. Malware inspection never
executes or deletes discovered files. Findings require review and cannot prove
that a system is clean.

## Reports, backups, and checks

`all_logs.txt` accumulates actions, configuration diffs, permission
changes, and errors at the repository root with mode `0600`. Reports under `log/`
are overwritten on each corresponding run:

| File | Contents |
| --- | --- |
| `unauth_users(2).txt` | Unlisted interactive local accounts. |
| `unauth_admins(2).txt` | Unlisted wheel/UID-zero administrators, excluding already reported users. |
| `world_files.txt` | World-writable paths; inspect `.errors` for incomplete scans. |
| `malware_search.txt` | Inspection transcript, findings, errors, and completion status. |

System-file backups use private directories under `/var/backups/cyberpatriot`.
Additional authentication and policy rollback copies remain under `/var/backups`. The audit log
records exact backup locations. Configuration rollback does not uninstall newly
installed packages or reverse earlier successful tasks.

Safe checks (temporary fixtures and mocks; no host hardening):

```sh
/usr/local/bin/bash platforms/FreeBSD/tests/regression.sh
/usr/local/bin/bash platforms/FreeBSD/tests/services_freebsd.sh
/usr/local/bin/bash platforms/FreeBSD/tests/hardening_freebsd.sh
/usr/local/bin/bash platforms/FreeBSD/tests/freebsd_audits_test.sh
/usr/local/bin/bash platforms/FreeBSD/tests/native_freebsd.sh
```

The native smoke test additionally checks BSD utilities, permission handling,
login database generation, and socket inspection on FreeBSD; it skips other
operating systems. Runtime verification on a disposable FreeBSD VM is still
required before competition use. Mocked tests do not verify installed daemons or
all possible custom configurations.

References: [FreeBSD for Linux users](https://docs.freebsd.org/en/articles/linux-users/),
[packages](https://docs.freebsd.org/en/books/handbook/ports/),
[services](https://docs.freebsd.org/en/books/handbook/config/),
[PF](https://docs.freebsd.org/en/books/handbook/firewalls/),
[login.conf](https://man.freebsd.org/cgi/man.cgi?query=login.conf&sektion=5), and
[pam_passwdqc](https://man.freebsd.org/cgi/man.cgi?query=pam_passwdqc&sektion=8).

## Backups before system changes

Before each configuration edit or regular-file ownership/permission change,
the scripts save the current file under
`/var/backups/cyberpatriot/<UTC timestamp>.<unique suffix>/`. Each snapshot has
private `0700` parent directories, retains original contents, ownership and
permissions, and is kept after success or failure. Repeated runs create fresh
snapshots; an old backup never suppresses a new one. Directory-only permission
changes are logged without recursively copying the directory.

The same protection covers native password/account commands and package hooks.
Package installation, upgrades and removal first snapshot `/etc` and `/usr/local/etc`.
FreeBSD startup-setting changes snapshot all configuration files reported by
[`sysrc -l`](https://man.freebsd.org/cgi/man.cgi?query=sysrc&sektion=8), including
custom locations. The initial `sh bootstrap.sh` installation uses a separate
private `/var/backups/cyberpatriot-bootstrap.*` snapshot before Bash is available.
Backups of secrets are kept out of the audit log; only their location is logged.
Existing configuration diffs are still logged for ordinary text-policy edits.

If creating or copying a backup fails, the corresponding change is not run.
The snapshot's `files/` directory mirrors the original absolute paths;
`manifest.txt` lists saved paths and paths that were absent before creation.
Only snapshots with a `COMPLETE` marker finished copying successfully. Backups
are not automatically deleted. Symbolic-link targets passed directly for editing
are refused; links inside a directory snapshot are preserved without following
them. Resolve unusual linked configuration layouts before rerunning.

To recover a single file, locate its backup in `all_logs.txt`, inspect the
snapshot, then use `sudo cp -p /var/backups/cyberpatriot/<snapshot>/files/etc/<file> /etc/<file>`
(or run `cp -p` from a root shell). Validate the restored configuration before
reloading its service. An `ABSENT` manifest entry means the file did not exist
before the operation. Restore related account databases together from the same
snapshot while account changes are stopped; do not copy a whole `/etc` tree over
a running system. A configuration snapshot does not roll back installed packages.

`CP_BACKUP_ROOT` can select another private absolute backup directory. Safe
regression checks use a temporary directory and never harden the host:

```bash
bash platforms/FreeBSD/tests/backups_test.sh
python3 platforms/FreeBSD/tests/backup_commands_test.py
```

### Managed service policy

`run_all.sh` runs general tasks only. Use the shared `run_all_services.sh` for
reconciliation, service configuration, and PF. `RUN_SERVICES` is no longer used.

### Initial system repairs

`run_all.sh` sets a trusted PATH before its first external command. After validating task selection and root access, it runs `service_helpers/startup_repair.sh` before upgrades or selected general tasks, including on resume. Any failed repair stops subsequent tasks.

Ubuntu scans `/etc`, `/var/lib/dpkg`, `/var/lib/apt` and `/var/cache/apt` for immutable/append-only flags. It backs up affected paths, records original flags in the backup, then clears the flags. It also repairs the default login PATH in `/etc/environment`, preserving other variables. Individual shell startup files can still override PATH and need manual review. FreeBSD performs the native flag repair in `/etc`, `/usr/local/etc` and `/var/db/pkg`; securelevel restrictions may require single-user repair. Neither implementation clears flags across the whole filesystem.

Healthy APT sources are left alone. Recognized malformed-source, conflicting-signature or repository-signature/release errors trigger an official Ubuntu source candidate for the detected release and architecture. The candidate must pass signature-checked updates before live sources are backed up and disabled under `.disabled-cp-*` filenames. Third-party definitions remain recoverable but need review before reenabling. A failed final update restores original source definitions. Network, clock, lock, storage, missing-keyring and unsupported/EOL-release problems stop with an explanation instead of bypassing authentication. FreeBSD has no APT: it refreshes native `pkg` metadata and preserves custom repository definitions, stopping on failures.

Run the fixture tests instead of executing hardening scripts on a development workstation. Actual native-host testing remains necessary.

### Suspicious-services log

`suspicious_services.txt` is a separate, private, timestamped log appended on every service-policy run, before services are disabled (including launcher resume). It reports installed packages and discovered services from a review catalog when their family is absent from `input/critical_services.txt`. For example, installed or running Apache is reported when `apache2` is not critical. Entries distinguish installed packages from runtime and boot state; disabled services are still listed for review. These findings indicate unnecessary exposure to investigate, not confirmed malware.

The catalog includes the managed web, database, mail, file-sharing and VPN services, plus SSH, other FTP servers, Telnet/rsh/TFTP, NFS/rpcbind, SNMP, Avahi, printing, Redis, MongoDB, PostgreSQL, Tor, RDP/VNC, proxies, rsync, inetd/xinetd and container runtimes. The scan only logs findings; it does not expand the automatic disabling policy. Custom service names and unpackaged applications need manual review. Inventory errors are logged as incomplete and stop the service-policy run. Run `bash misc/suspicious_services.sh` as root for the audit alone.

### First-pass review and second-pass cleanup

Populate `input/auth_users.txt` and `input/auth_admins.txt` first. At least one existing non-root administrator is required; administrator entries also count as authorized users. In `run_all.sh`, select `usr mp3` to generate the account and media inventories. These two first-pass tasks only report; they do not delete users or media. Other first-launcher tasks retain their existing behavior.

Review `log/unauth_users(2).txt`, `log/unauth_admins(2).txt`, and `log/media_files(2).txt`. Remove or comment out whole candidate lines for accounts/files that must be retained, or correct the allowlists and rerun the audit. The account reports contain usernames and their numeric UIDs; the media report contains an identity signature, a tab, and the absolute path. Do not edit those identity fields.

Then run `sudo bash run_all_2.sh` on Ubuntu, or `bash run_all_2.sh` from a FreeBSD root shell. This explicit second launcher deletes reviewed unauthorized local accounts (retaining home directories), revokes reviewed administrator memberships and local sudo/doas access, leaves global polkit policy unchanged, and removes the reviewed media files after backing them up. It does not rerun upgrades or general hardening. User deletion is not forced: active sessions, UID-zero aliases, the invoking sudo/doas account, identity changes, or failed backups stop or fail cleanup for review. Revoked users must log out of existing sessions; existing root shells and custom polkit action grants require separate review.

Second-pass actions are appended to `log/user_management(2).txt`, `log/media_cleanup(2).txt`, and the combined `all_logs(2).txt`. Both cleanup scripts can also be run separately. Current allowlists are checked again, so newly authorized users are preserved. Missing or changed media is not blindly deleted. Root and system service accounts are not automatically treated as unauthorized ordinary users.

The media inventory covers MP3, MOV and MP4 under `/`, including separate local `/home` partitions. It excludes backups, remote/pseudo-filesystems, and conventional `/media` and `/mnt` mount trees. Use `MEDIA_ROOT=/home bash rm_stuff/rm_mp3+.sh` as root to narrow the inventory; each inventory replaces the previous media review file. Files with embedded newlines/carriage returns are logged for manual review instead of automatic removal.

### Audit corrections

Public account databases (`passwd`, `group`, and FreeBSD `pwd.db`) are restored to `0644` when too restrictive; password-hash files retain their separate private permission policy. The account audit includes low-UID interactive accounts and extra UID-zero identities. Ubuntu skips absent LightDM, uses seat-scoped guest settings without restarting the desktop, queries exact installed-package status, propagates failed kernel changes, and supports `/etc/openvpn/client/*.conf` with template unmasking. FreeBSD already uses native package queries, optional LightDM and verified kernel changes. Run the fixture suites before native-host testing.

### Refresh-only service changes

Service configuration changes request reloads only. There is no automatic restart
or reboot fallback, including after configuration rollback. Inactive services are
left inactive; unsupported or failed reloads are logged as pending/failed and return
an error instead of claiming the new configuration is active. Critical services
remain enabled at boot. Noncritical services are still stopped and disabled.
Package installers may run their own service hooks; this policy covers explicit
service actions in these scripts, not arbitrary third-party package hooks.

## Native system-component hardening

Select `sys` in the shared `run_all.sh`, or run `bash misc/system_hardening.sh`.
The shared runner invokes all components below using the native FreeBSD backend.
Legacy component keywords also select the entire combined task.

| Component | FreeBSD behavior |
| --- | --- |
| `nss` | Protect `/etc/nsswitch.conf`; check root, wheel and localhost lookups with timeouts. Keep configured lookup order. |
| `openssl` | Protect existing OpenSSL configuration and private-key permissions; check the selected OpenSSL binary's cipher loading and protect native certificate directories. |
| `grub` | Protect `/boot/loader.conf`, `loader.conf.local`, `loader.rc` and `loader.conf.d`. If GRUB configurations exist, protect and syntax-check them with `grub-script-check`. No bootloader is installed or regenerated. |
| `selinux` | Report **not applicable**: FreeBSD does not implement Linux SELinux. Native MAC policy is not configured automatically. |
| `netfilter` | Snapshot already-loaded PF/IPFW rules instead of invoking Linux Netfilter. Keep rules unchanged; `platforms/FreeBSD/services/pf.sh` remains the firewall policy writer. |
| `dhclient` | Protect existing native `/etc/dhclient.conf`, enter/exit hooks, and corresponding `/usr/local/etc` files. Preserve hook execute bits, leases and interface settings. |

The `ker` task now always disables both `net.inet.ip.forwarding` and
`net.inet6.ip6.forwarding`, reads them back, and persists zero values in
`/etc/sysctl.conf`. It also sets `gateway_enable=NO` and
`ipv6_gateway_enable=NO` in `/etc/rc.conf` and existing standard local/routing
overrides, then verifies the rc settings. Required forwarding controls failing
or being unavailable stops the task; they are not silently skipped. This turns
off packet routing, not IPv4/IPv6 host networking. Rerun `ker` explicitly if it
was already marked complete. Backups precede configuration changes.

Existing native ASLR, SYN-cookie and redirect/source-route protections remain.
The task now also applies `security.bsd.hardlink_check_uid=1` and
`security.bsd.hardlink_check_gid=1` where supported. Linux `protected_symlinks`,
SysRq and `rp_filter` are not copied as nonexistent FreeBSD sysctls.

The `per` task additionally protects local users' shell startup/history files
(including native `.cshrc`, `.login`, `.history`) and SSH files, root included.
It supports the standard `/home` to `/usr/home` alias, refuses other linked
user paths, and does not log secret contents. Native `rc.d` scripts retain
execute permissions, certificate trees retain trust membership, and loader
configuration is protected without changing boot binaries. EFI FAT mount
permissions still require manual review.

Certificate roots checked: `/usr/share/certs`, `/usr/local/share/certs`,
`/usr/local/etc/ssl/certs`, `/etc/ssl/certs`, `/etc/ssl/untrusted`. Internal
certificate symlinks are retained. Missing optional paths are not created.
The firewall snapshot can include private `pf-status.txt`, `pf-filter.rules`,
`pf-nat.rules` and `ipfw.rules` files under the standard backup directory.

Fixture validation (no host hardening):

```sh
python3 platforms/FreeBSD/tests/system_components_test.py
bash platforms/FreeBSD/tests/regression.sh
bash platforms/FreeBSD/tests/hardening_freebsd.sh
```

References: [FreeBSD routing](https://docs.freebsd.org/en/books/handbook/advanced-networking/),
[DHCP client](https://docs.freebsd.org/en/books/handbook/network-servers/),
[certificate management](https://man.freebsd.org/cgi/man.cgi?manpath=FreeBSD+12.4-RELEASE&query=certctl).

Configuration edits made by `misc` scripts and their shared helpers append
setting-level entries to `all_logs.txt`: `changed SETTING from OLD to NEW` or
`added SETTING with new value VALUE`. Each setting includes its file path and
INI section where applicable. This covers sysctl and rc settings, LightDM,
sudoers/polkit policies, and fstab mount options. Removed settings are recorded
as `changed ... to <unset>`; unchanged values do not produce setting entries.
Backups and full diffs remain available, including after partial edit failures.
Run `python3 platforms/FreeBSD/tests/settings_logging_test.py` for isolated logging checks.

Second-pass cleanup acts only on entries remaining in the three root review logs:

- `log/media_files(2).txt`: files to delete.
- `log/unauth_users(2).txt`: users to delete (home directories retained).
- `log/unauth_admins(2).txt`: users whose privileged groups and local sudo/doas access should be revoked.

Delete a line or prefix it with `#` to preserve that item. Keep the username/UID
or file identity/path fields intact on retained removal entries. Empty or
comment-only logs authorize no actions of that type; missing logs stop cleanup.
Run `bash run_all_2.sh` after review. Do not rerun the first-pass inventory tasks
between editing the logs and cleanup, because those tasks regenerate the lists.
Second-pass cleanup never rescans for additional targets or rewrites the global
polkit administrator policy. These rules apply to Linux and FreeBSD.
