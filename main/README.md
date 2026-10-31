# Combined Linux and FreeBSD toolkit

## Additional Linux system components

The scoring launcher exposes general system tasks and startup repairs. Native
equivalents of the system components and hardening are also available in
`platforms/FreeBSD`; see its README for platform-specific behavior.

| Folder | Tasks / scripts | Behavior |
| --- | --- | --- |
Select `sys` for the combined Linux component checks (legacy `netfilter` and
`iptables` selections also run the combined task), `nfs` (alias `nfs-server`), `cups` (alias
`cupsd`), `chrony` (aliases `chronyd` and `crony`), or the other listed task names.
Scripts may also be run individually with `sudo bash path/to/script.sh`.

Validator references: [Chrony `-p`](https://chrony-project.org/doc/4.9/chronyd.html),
[SSSD configuration checker](https://sssd.io/design-pages/config_check_tool.html),
and [Netfilter documentation](https://netfilter.org/documentation/).


Linux and FreeBSD share the launchers in `main/`, inputs, logs, account/media
review, and general configuration auditing.
`platforms/FreeBSD/` contains only native implementations, platform documentation,
and native tests. Shared code is loaded directly; changes do not need to be
copied into a second project tree.

Edit `input/distribution.txt`: select exactly one of `ubuntu`, `debian`, `mint`,
`freebsd`, or `auto`. The selection must match the running OS. On either platform:

- `bash main/run_all.sh`: general hardening and inventories (`sys` combines component checks).
- `bash main/run_all_2.sh`: apply reviewed account and media cleanup.

Run as root. On FreeBSD without Bash, use `sh main/bootstrap.sh` from the repository
root; it backs up configuration before installing prerequisites.

Both platforms use **`input/`**, **`log/`**, and the aggregate logs
**`main/all_logs.txt`** and **`main/all_logs(2).txt`**. Review the shared account
allowlists before running. FreeBSD progress uses `main/.run_all_status.freebsd`;
Linux progress is kept separately.

Native `pkg`, rc, OpenPAM, sysctl, and boot code remains in
`platforms/FreeBSD/`.

See [FreeBSD instructions](platforms/FreeBSD/README.md). All commands there are
relative to the repository root. The separately checked-out FreeBSD repository
is independent; this integration applies to the FreeBSD folder in this project.

# Description
This is a set of scripts to run for CyberPatriot Linux

## Local web dashboard

From the repository root, run `./setup.sh`. This single command creates or
reuses the project `.venv`, installs or updates the website dependencies from
`main/requirements.txt`, and starts the dashboard in the foreground. It
does not run APT updates or CyberPatriot setup tasks. Enter your sudo or doas
password when prompted. The Flask server stays under your desktop account;
script and protected-file operations use sudo/doas when available, with a
graphical pkexec prompt as a Linux fallback. If none is configured, protected
operations report the permission failure.
Open <http://127.0.0.1:5000> in a browser; press Ctrl+C in the terminal to stop
the server. Setup checks for Meld and attempts to install it with APT on Ubuntu,
Debian, or Linux Mint, or `pkg` on FreeBSD when a compatible package is listed.
If installation is unavailable, the dashboard continues to work and reports
that Meld comparisons are unavailable. Meld needs an active graphical session
(`DISPLAY` or `WAYLAND_DISPLAY`) inherited by the dashboard.
If setup cannot install it, use `sudo apt-get install meld` or `doas apt-get install meld` on supported Debian-family systems. On FreeBSD, check with `pkg search meld` before installing with `sudo pkg install meld` or `doas pkg install meld`; availability depends on the configured repository for that release.

The UI reads and writes the original files in `input/` and the package list in
`rm_stuff/bad_pkg.sh`. It stores dashboard status in `main/.webapp_state.json` and
per-run output under `log/webapp-runs/`; both are ignored by Git. Configuration
buttons appear after the app observes a changed file during a dashboard-launched
run. Before a dashboard script runs, the app saves a unique configuration
snapshot and associates it with that run; use **Review Script Changes** or the
**Meld and Configuration Backups** section to compare changed, created, or
deleted paths. Manual snapshots can be created before editing a configuration
outside the dashboard. Backups are stored privately under
`~/.local/share/cyberpatriot/config-backups` by default. Restore is separate from
comparison, requires confirmation, and first saves the current version. The
interface is intended for local practice and should remain bound to localhost.

The authorized-user and authorized-admin lists are edited from buttons in the
User Audit section. The files stay in `input/` and keep their original formats.

ALL NEW COMMENTS GO DOWN HERE(do not edit or change anything above):

Run `sudo bash main/run_all.sh` to select CyberPatriot tasks. `auto` runs every
listed task; Enter resumes unfinished tasks. Package removal uses its fixed list
without prompting. Select `mal` to install ClamAV and Lynis when needed, scan the
filesystem with ClamAV, and run a Lynis system audit. Reports are saved to
`log/clamav.txt` and `log/lynis.txt`.

The launcher, `main` hardening scripts and media-removal script append to
`main/all_logs.txt`, regardless of the working directory. Configuration
edits include old/new lines; service state, backups, permissions, firewall
status and failures are logged. SSH/Apache validate before reloading and restore
their configurations on failure. vsftpd has no validation-only mode, so failed
startup triggers restoration. Backups are retained in private directories under `/var/backups/cyberpatriot`.

Safe checks (temporary fixtures and mocked commands; no system hardening):

```bash
bash tests/backups_test.sh
```

Configuration references: [OpenSSH](https://man.openbsd.org/sshd_config),
[Apache](https://httpd.apache.org/docs/2.4/mod/core.html),
[vsftpd](https://manpages.ubuntu.com/manpages/jammy/man5/vsftpd.conf.5.html),
[UFW](https://manpages.ubuntu.com/manpages/noble/man8/ufw.8.html).

## File descriptions

### Files in `main/`

| File | Description |
| --- | --- |
| `main/README.md` | Explains how to select tasks, configure scenario reference lists, run checks, and understand the project files. |
| `main/.gitattributes` | Tells Git to use Linux-style LF line endings for shell scripts. |
| `main/run_all.sh` | Interactive CyberPatriot scoring tasks with saved progress. |
| `main/all_logs.txt` | Stores the shared, accumulating audit log with script names. Scripts using the logging helper record configuration changes, permissions, actions, and failures here. |
| `main/logging.sh` | Provides shared functions for logging actions, comparing configuration files before and after edits, and recording permission changes. Other scripts source this helper rather than run it as a task. |

### General hardening and removal scripts

| File | Description |
| --- | --- |
| `main/system_hardening.sh` | Runs NSS, OpenSSL, GRUB, SELinux, Netfilter snapshot, and DHCP client checks together (`sys` in the launcher). |
| `main/kernel.sh` | Applies persistent and runtime sysctl hardening for networking and kernel protections. It also adjusts `/tmp` and `/dev/shm` permissions and mount options, including their existing fstab entries. |
| `main/file_permissions.sh` | Sets permissions on selected system files, directories, and user home directories. It also generates a report of world-writable files and directories. |
| `password_management/pwd_policy.sh` | Creates/configures `login.defs`, `pwquality.conf` and `faillock.conf` for account defaults, password complexity and failed-login lockout. Enables and verifies PAM profiles, preserving backups and refusing incompatible custom stacks. |
| `rm_stuff/rm_mp3+.sh` | Writes a read-only MP3/MOV/MP4 inventory to `log/media_files(2).txt`; reviewed removal is performed by `rm_stuff/rm_mp3+_2.sh` in the second launcher. |
| `rm_stuff/bad_pkg.sh` | Removes installed matches from the fixed CyberPatriot package list without prompting. |
| `rm_stuff/malware_scan.sh` | Installs and runs ClamAV and Lynis, writing reports to `log/clamav.txt` and `log/lynis.txt`. |

### Package and service comparisons

The dashboard's Package Comparison and Service Comparison tasks regenerate their
current inventories on every run, then compare names/states with the editable
reference files `compare/pkgs/safe_pkgs.txt` and
`compare/services/safe_services.txt`. The package reference format is one
package name per line. The service reference format is one service name and its
expected boot state (`enabled` or `disabled`) per line. Blank lines and `#`
comments are ignored. Findings are written to
`compare/compare_pkgs.txt` and `compare/compare_services.txt`; the generated
inventories are stored separately under `compare/pkgs/unsafe_pkgs.txt` and
`compare/services/unsafe_services.txt`.

The supplied reference files are empty. Add a reviewed baseline before using the
results. Package names can differ between Ubuntu, Debian, Mint, and FreeBSD, so
maintain separate trusted package lists when their names differ. The tools
compare package names without versions, and compare service boot configuration
without inferring it from whether a service is running. On systemd, static,
generated, indirect, alias, and unknown unit states are treated as present but
not comparable to enabled/disabled; masked units are treated as disabled.
FreeBSD uses `service -r` for ordered service scripts and `service -e` for
boot-enabled scripts. Findings are configuration differences, not claims that
a package or service is malicious.

### User audit files

| File | Description |
| --- | --- |
| `user_management/user_management.sh` | Reads the authorized-user lists, audits interactive local accounts at every UID, flags extra UID-zero identities, and writes second-pass review reports without changing accounts. |
| `input/auth_users.txt` | Input list of authorized local usernames, one per line, based on the competition README. Blank lines and lines beginning with `#` are ignored. |
| `input/auth_admins.txt` | Input list of authorized administrators, with each username on one line and its password on the following line. Readers use the username and ignore the password line. |
| `log/unauth_users(2).txt` | Output list of audited users absent from `auth_users.txt`. The user audit overwrites this file each time it runs. |
| `log/unauth_admins(2).txt` | Output list of audited sudo/wheel members absent from `auth_admins.txt`, excluding accounts already reported as unauthorized users. The user audit overwrites this file each time it runs. |

### Tests

| File | Description |
| --- | --- |
| `tests/logging_test.sh` | Tests configuration-change logs, permission logs, and media-deletion success and failure handling using temporary files and mocked commands. It does not run system hardening. |
| `tests/compare_tools_test.py` | Exercises package and service comparisons with mocked Debian-family and FreeBSD package/service commands. |
| `tests/compare_dashboard_test.py` | Checks comparison dashboard entries and verifies static input paths are passed as separate subprocess arguments. |

### Generated text reports

These files are created when the relevant scripts run and may not exist yet.
The permission report and individual scan reports are overwritten on subsequent
runs, unlike the accumulating `main/all_logs.txt`.

| File | Description |
| --- | --- |
| `log/world_files.txt` | Lists world-writable regular files and directories found by the permission-hardening script, along with the report generation time. |

## Package updates and file locations

After selecting eligible tasks, `main/run_all.sh` runs `sudo apt update` and then
`sudo apt upgrade` before the selected scripts. The upgrade retains its normal
confirmation prompt. If either command fails, the launcher stops and records
the failure in `main/all_logs.txt`.

Edit the scenario input lists in `input/`: `auth_users.txt` and `auth_admins.txt`. Generated reports are stored in `log/`.
The shared audit log is `main/all_logs.txt`.

## Sudo and polkit administrator allowlist

Before running `main/kernel.sh` (or selecting `ker` in the launcher), populate
`input/auth_admins.txt` with each existing administrator username followed by
its password on the next line. Readers ignore the password line.
Blank lines and full-line comments are allowed. Empty lists, invalid names,
missing accounts, and non-root names with UID zero stop the script before
hardening begins. Root remains an administrator for recovery.

The script replaces `/etc/sudoers` with explicit password-required grants for
the listed users and root, with password caching disabled. Existing group grants
and sudoers includes no longer apply; their files remain on disk. It validates
the existing and generated sudoers with `visudo`, validates the installed policy,
and restores the previous policies if installation fails. Root-only backups
are retained under `/var/backups/cyberpatriot-admin-access.*`; the exact path
and policy changes are recorded in `main/all_logs.txt`.

The managed `/etc/polkit-1/rules.d/00-cyberpatriot-admins.rules` limits the
identities available for administrator authentication to root and the list.
It requires a polkit installation with JavaScript rules support and refuses to
proceed if another rules file sorts ahead of it. Polkit automatically reloads
the rule. Existing action rules that grant access without administrator
authentication are not revoked by an administrator-identity rule; review those
separately. See the [polkit authorization rules documentation](https://polkit.pages.freedesktop.org/polkit/polkit.8.html).

Keep a root session open when applying these access changes and verify access
from another session before closing it. To revert, restore the saved `sudoers`
as root with mode `0440` and validate it with `visudo -c`. Restore the saved
`polkit.rules` to the managed rule path if present, otherwise remove that managed
rule to restore the previous administrator selection.

Run `python3 tests/test_admin_access.py` to check allowlist validation, generated
policies, repeat runs, rule ordering, and rollback using temporary fixtures.
The tests require Bash, `visudo`, and Node.js and do not change system policies.

## Configuration and authentication-file permissions

Each service task now applies shared ownership and permission checks to its
configuration before starting the service. SSH daemon configuration, drop-ins,
and host private keys are restricted to root. Apache configuration is protected
from non-root writes, and `/etc/ssl/private` retains existing groups with at most
`0640` files and `0750` directories. VSFTPD configuration and its generated private
key are root-only. UFW configuration is limited to owner/group access while
retaining execute bits for existing hook scripts. The general file-permissions
task applies the same profiles, so it no longer weakens SSH permissions.

Both the `per` (file permissions) and `pol` (password policy) tasks apply the
same account, PAM, and authentication-log protection:

| Requested file or directory | Handling on Ubuntu/Debian/Mint |
| --- | --- |
| `/etc/passwd`, `/etc/group` | Root owner and group; at most `0644`. |
| `/etc/shadow` | Root owner, `shadow` group (root group if unavailable); at most `0640`. `/etc/gshadow` and existing `passwd-`, `group-`, `shadow-`, `gshadow-` copies are protected too. |
| `/usr/lib64/security` | Protect this module directory when present, plus native multiarch module directories; files at most `0755`, preserving existing execute bits. |
| `/etc/pam.d` | Root-owned policy files at most `0644`, directories at most `0755`; the password-policy task also enables and verifies password quality. |
| `/etc/security` | Root-owned configuration at most `0644`; password-history files restricted to `0600` before processing the directory. Password quality is configured in `pwquality.conf`. |
| `/var/log/secure` | Protect existing files and rotations at most `0640`; also protect Ubuntu's `/var/log/auth.log` and its rotations. |

The three core account databases must be regular files; missing or linked
databases stop the task without creating empty replacements. Existing account
records and password hashes are not rewritten by permission hardening. Every
regular-file ownership or mode change requires a successful backup first.
The account-group choices follow the usual
[Ubuntu ownership conventions](https://help.ubuntu.com/community/FilePermissions).

Both file permissions and password management protect `/etc/pam.d`,
`/etc/security`, and PAM module directories including `/usr/lib64/security`
and Debian/Ubuntu multiarch equivalents. Configuration files have at most
`0644`, directories at most `0755`, and password-history files `0600`. Module
execute bits are preserved. Existing stricter read permissions and groups are
retained. Symlinks inside configuration trees are skipped and logged; review
external configuration targets separately. Standard module-directory aliases
are resolved before processing.

Existing `/var/log/secure`, `/var/log/auth.log`, and their rotated files receive
at most `0640`; root/syslog ownership and existing groups are retained as
appropriate for logging. Absent logs are not created or logging destinations
changed. Log rotation settings must also retain these permissions for new logs.

The `pol` task backs up PAM and password configuration under the private
`/var/backups/cyberpatriot/` snapshot directory, then creates any missing files
below (and `/etc/security` if needed). It preserves comments and unrelated
settings, replaces duplicate managed settings, and applies root ownership with
permissions no broader than `0644`.

| File | Managed settings |
| --- | --- |
| `/etc/login.defs` | Password maximum/minimum/warning ages `90/1/7` days; regular UID/GID range `1000–60000`; system UID/GID range `100–999`; `UMASK 027`, `HOME_MODE 0750`, `LOGIN_RETRIES 5`, `LOGIN_TIMEOUT 60`. Retains `YESCRYPT` when present, otherwise selects `SHA512`. |
| `/etc/security/pwquality.conf` | Minimum 12 characters with at least one uppercase, lowercase, digit and special character; four new characters when comparing old/new passwords; at most three identical consecutive characters; dictionary and username checks; enforcement enabled. |
| `/etc/security/faillock.conf` | Five consecutive failures within 900 seconds trigger a 900-second lockout. `silent` avoids revealing account existence; `local_users_only` leaves directory-service lockout to its own provider. Existing root/admin lockout options are retained. |

Password aging and UID/GID settings are defaults for future account creation;
existing account ages and IDs are unchanged. PAM controls password hashing, so
`ENCRYPT_METHOD` does not replace PAM's existing hash policy. Root password-quality
exemption is unchanged unless `enforce_for_root` is already configured. FreeBSD
continues to use its native `login.conf`/PAM policy rather than these Linux files.

The task installs `libpam-pwquality` if needed and enables its packaged profile.
Two bundled `pam-auth-update` profiles place the lockout check before authentication,
failure recording after failed authentication, and counter reset in the account
phase. The task verifies required modules and ordering and rejects policy arguments
that override `pwquality.conf`. Custom PAM stacks are not force-overwritten;
refused, failed or unverifiable updates restore the previous common stacks and
stop for review, with the backup location logged. See the
[PAM profile manager](https://manpages.debian.org/bookworm/libpam-runtime/pam-auth-update.8.en.html),
[password-quality options](https://manpages.debian.org/bookworm/libpwquality-common/pwquality.conf.5.en.html)
and [lockout module configuration](https://manpages.debian.org/bookworm/libpam-modules/pam_faillock.8.en.html).

Run `python3 tests/password_policy_test.py` on Debian/Ubuntu for isolated creation,
repeat-run, preservation, PAM rollback and actual lockout checks. All generated
PAM configurations, debconf data and failure counters stay in temporary directories.

Run `python3 tests/auth_permissions_test.py` for temporary-file checks of account,
PAM, module, and log permissions, backups, symlink handling, and repeat runs. These tests
do not change system ownership, configuration, or running services.

## Backups before system changes

Before each configuration edit or regular-file ownership/permission change,
the scripts save the current file under
`/var/backups/cyberpatriot/<UTC timestamp>.<unique suffix>/`. Each snapshot has
private `0700` parent directories, retains original contents, ownership and
permissions, and is kept after success or failure. Repeated runs create fresh
snapshots; an old backup never suppresses a new one. Directory-only permission
changes are logged without recursively copying the directory.

The same protection covers native password/account commands and package hooks.
Package installation, upgrades and removal first snapshot `/etc`.
UFW rules/defaults, PAM-generated stacks, Apache configuration enablement,
systemd enablement and replaced FTPS keys/certificates are also backed up.
Backups of secrets are kept out of the audit log; only their location is logged.
Existing configuration diffs are still logged for ordinary text-policy edits.

If creating or copying a backup fails, the corresponding change is not run.
The snapshot's `files/` directory mirrors the original absolute paths;
`manifest.txt` lists saved paths and paths that were absent before creation.
Only snapshots with a `COMPLETE` marker finished copying successfully. Backups
are not automatically deleted. Symbolic-link targets passed directly for editing
are refused; links inside a directory snapshot are preserved without following
them. Resolve unusual linked configuration layouts before rerunning.

To recover a single file, locate its backup in `main/all_logs.txt`, inspect the
snapshot, then use `sudo cp -p /var/backups/cyberpatriot/<snapshot>/files/etc/<file> /etc/<file>`
(or run `cp -p` from a root shell). Validate the restored configuration before
reloading its service. An `ABSENT` manifest entry means the file did not exist
before the operation. Restore related account databases together from the same
snapshot while account changes are stopped; do not copy a whole `/etc` tree over
a running system. A configuration snapshot does not roll back installed packages.

`CP_BACKUP_ROOT` can select another private absolute backup directory. Safe
regression checks use a temporary directory and never harden the host:

```bash
bash tests/backups_test.sh
python3 tests/backup_commands_test.py
```

### Initial system repairs

`main/run_all.sh` sets a trusted PATH before its first external command. After validating task selection and root access, it runs `service_helpers/startup_repair.sh` before upgrades or selected non-service tasks, including on resume. Any failed repair stops subsequent tasks.

Ubuntu scans `/etc`, `/var/lib/dpkg`, `/var/lib/apt` and `/var/cache/apt` for immutable/append-only flags. It backs up affected paths, records original flags in the backup, then clears the flags. It also repairs the default login PATH in `/etc/environment`, preserving other variables. Individual shell startup files can still override PATH and need manual review. FreeBSD performs the native flag repair in `/etc`, `/usr/local/etc` and `/var/db/pkg`; securelevel restrictions may require single-user repair. Neither implementation clears flags across the whole filesystem.

Healthy APT sources are left alone. Recognized malformed-source, conflicting-signature or repository-signature/release errors trigger an official source candidate for the selected and verified Ubuntu, Debian or Mint release and architecture. The candidate must pass signature-checked updates before live sources are backed up and disabled under `.disabled-cp-*` filenames. Third-party definitions remain recoverable but need review before reenabling. A failed final update restores original source definitions. Network, clock, lock, storage, missing-keyring and unsupported/EOL-release problems stop with an explanation instead of bypassing authentication. FreeBSD has no APT: it refreshes native `pkg` metadata and preserves custom repository definitions, stopping on failures.

Run the fixture tests instead of executing hardening scripts on a development workstation. Actual native-host testing remains necessary.

### First-pass review and second-pass cleanup

Populate `input/auth_users.txt` and `input/auth_admins.txt` first. At least one existing non-root administrator is required; administrator entries also count as authorized users. In `main/run_all.sh`, select `usr mp3` to generate the account and media inventories. These two first-pass tasks only report; they do not delete users or media. Other first-launcher tasks retain their existing behavior.

Review `log/unauth_users(2).txt`, `log/unauth_admins(2).txt`, and `log/media_files(2).txt`. Remove or comment out whole candidate lines for accounts/files that must be retained, or correct the allowlists and rerun the audit. The account reports contain usernames and their numeric UIDs; the media report contains an identity signature, a tab, and the absolute path. Do not edit those identity fields.

Then run `sudo bash main/run_all_2.sh` on Ubuntu, or `bash main/run_all_2.sh` from a FreeBSD root shell. This explicit second launcher deletes reviewed unauthorized local accounts (retaining home directories), revokes reviewed administrator memberships and local sudo/doas access, leaves global polkit policy unchanged, and removes the reviewed media files after backing them up. It does not rerun upgrades or general hardening. User deletion is not forced: active sessions, UID-zero aliases, the invoking sudo/doas account, identity changes, or failed backups stop or fail cleanup for review. Revoked users must log out of existing sessions; existing root shells and custom polkit action grants require separate review.

Second-pass actions are appended to `log/user_management(2).txt`, `log/media_cleanup(2).txt`, and the combined `main/all_logs(2).txt`. Both cleanup scripts can also be run separately. Current allowlists are checked again, so newly authorized users are preserved. Missing or changed media is not blindly deleted. Root and system service accounts are not automatically treated as unauthorized ordinary users.

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

### Distribution input

Edit `input/distribution.txt` before running. Keep exactly one uncommented line:
`ubuntu`, `debian`, `mint`, `freebsd`, or the default `auto`. Explicit selections must match
`/etc/os-release`; a mismatch stops before launcher repairs. Mint uses its Ubuntu
base codename, or identified Debian base metadata for LMDE. Missing or ambiguous
release metadata stops automatic repair. This does not certify every other
hardening script for every version of these distributions.

Login hardening follows `/etc/X11/default-display-manager`, falling back to one
installed supported manager. LightDM gets the guest-session policy; GDM gets
automatic and timed login disabled in Ubuntu's `custom.conf` or Debian's
`daemon.conf`; SDDM gets automatic login disabled in its main configuration.
Unrelated settings and backups are retained. No display manager is restarted.
Unknown or ambiguous managers require review.

Repository recovery retains healthy sources. Broken sources are replaced only
after a signature-checked candidate update succeeds. Debian gets Debian archive
and security sources; Mint gets both its own archive and its detected base sources.
Trusted archive keyrings must already exist; no trust bypass or release upgrade
is attempted. Unsupported/EOL suites fail candidate validation and leave sources
unchanged. Third-party sources remain backed up for manual review.

All three distributions use systemd capability checks for reloads. Installed
SSH, database and BIND unit aliases are resolved before use. An inactive service,
missing unit or unsupported/failed reload returns an error; there is no start,
restart or reboot fallback.

Configuration references: [Debian APT sources](https://wiki.debian.org/SourcesList),
[Debian GDM](https://manpages.debian.org/bookworm/gdm3/gdm3.8.en.html),
[Ubuntu GDM package files](https://packages.ubuntu.com/noble/all/gdm3/filelist),
[SDDM configuration](https://manpages.debian.org/testing/sddm/sddm.conf.5.en.html),
and [Mint archive components](https://packages.linuxmint.com/list.php?release=una).

## Additional kernel and sensitive-path coverage

`main/kernel.sh` already applied ASLR (`kernel.randomize_va_space=2`), SYN cookies,
IPv4 accept/send redirect restrictions, source-route restrictions, reverse-path
filtering, and the listed ICMP protections. It now also persists and verifies:

- `fs.protected_hardlinks=1` and `fs.protected_symlinks=1`.
- `kernel.sysrq=0`.
- `net.ipv4.conf.all.secure_redirects=0` and the corresponding `default` value.

The `/proc/sys/...` paths correspond to these dotted sysctl names. Settings are
saved in `/etc/sysctl.d/99-hardening.conf` and applied to the running kernel.
IPv4 `net.ipv4.ip_forward` and IPv6 `net.ipv6.conf.all.forwarding` are now
unconditionally persisted and applied as `0` by the `ker` task. The previous
`input/forwarding.txt` option has been removed. Run `ker` explicitly after this
update if it was already marked complete. Both settings are written to
`/etc/sysctl.d/99-hardening.conf`, applied immediately and read back for
verification. Forwarding changes precede the other network settings because
changing IPv4 forwarding resets some defaults; see the
[Linux kernel IP sysctl documentation](https://kernel.org/doc/html/latest/networking/ip-sysctl.html).


The existing `per` task (`main/file_permissions.sh`) now also covers:

| Paths | Action |
| --- | --- |
| Local interactive users' homes and root: `.bash_profile`, `.bashrc`, `.bash_login`, `.profile`, `.zshrc`, `.bash_history` | Owner-only permissions; contents retained. Homes come from `/etc/passwd`, including homes outside `/home`. |
| The same homes: `.ssh/authorized_keys`, `.ssh/config`, `.ssh/id_rsa`, `.ssh/id_ed25519` | Owner-only files and `.ssh` directory; no key/history contents logged. Linked paths are reported for review rather than followed. |
| `/lib/systemd/system/`, `/usr/lib/systemd/system/` | Root ownership and removal of group/other write access for regular units/drop-ins, including sshd, nginx, httpd, rsyslog and auditd when present. Distribution aliases resolve; links inside the trees remain unchanged. Vendor units also join the malware persistence inventory. |
| `/usr/share/ca-certificates/`, `/etc/pki/tls/certs/`, `/etc/pki/ca-trust/source/anchors/`, `/usr/local/share/ca-certificates/` | Protect existing regular certificate files/directories; trust membership and symlink targets remain unchanged. |
| `/boot/grub/grub.cfg`, `/boot/grub2/grub.cfg`, `/boot/efi/EFI/{ubuntu,centos,redhat}/grub.cfg`, `/boot/loader/entries/` | Owner-only regular files/directories on POSIX filesystems. FAT EFI filesystems are reported for mount-permission review instead of ineffective chmod. Also included in the combined `sys` task. |

Absent optional paths are not created. These path checks do not imply CentOS or
Red Hat launcher support. Certificate trust, SSH key authorization and boot-entry
contents still require scenario review; no trust store or bootloader is rebuilt.

The shared `sys` task uses native FreeBSD implementations for NSS, OpenSSL,
boot, MAC applicability, firewall snapshots and DHCP client checks, with persistent IPv4/IPv6 forwarding
disablement, hardlink protection and sensitive-path hardening. See
`platforms/FreeBSD/README.md` for native mappings and Linux-only exclusions.

The shared launcher consolidates the former `nss`, `openssl`, `grub`, `selinux`,
`netfilter`, and `dhclient` tasks into `sys`. Their old selection keywords
(including `iptables`) select the entire consolidated task. Existing completion
records for individual components do not skip the new combined task.

Configuration edits append setting-level entries to `main/all_logs.txt`, in addition
to the original backups and file diffs: `changed SETTING from OLD to NEW` or
`added SETTING with new value VALUE`. Entries include the configuration path and,
for INI files, the section. Removed settings use `changed ... to <unset>`;
unchanged values do not produce setting entries. Partial edits are recorded even
if the editing command fails.

Second-pass cleanup acts only on entries remaining in the three root review logs:

- `log/media_files(2).txt`: files to delete.
- `log/unauth_users(2).txt`: users to delete (home directories retained).
- `log/unauth_admins(2).txt`: users whose privileged groups and local sudo/doas access should be revoked.

Delete a line or prefix it with `#` to preserve that item. Keep the username/UID
or file identity/path fields intact on retained removal entries. Empty or
comment-only logs authorize no actions of that type; missing logs stop cleanup.
Run `bash main/run_all_2.sh` after review. Do not rerun the first-pass inventory tasks
between editing the logs and cleanup, because those tasks regenerate the lists.
Second-pass cleanup never rescans for additional targets or rewrites the global
polkit administrator policy. These rules apply to Linux and FreeBSD.
