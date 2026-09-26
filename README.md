# Description
This is a set of scripts to run for CyberPatriot Linux

changes admin password to ChangeMe123!

ALL NEW COMMENTS GO DOWN HERE(do not edit or change anything above):

Service setup requires Debian/Ubuntu (including compatible Mint versions),
`apt-get`, and a running systemd system. Run scripts with `sudo bash`.

Edit `input/critical_services.txt` using the competition README. Remove `none` and
list the required services, one per line: `ssh`, `apache2`, `vsftpd`, and/or `ufw`.
Aliases such as `sshd`, `http`, and `vsftp` work too. Keep `none` if none are
required. Installed software is not automatically treated as authorized.
For other required services, configure them separately and add firewall entries
such as `allow 3306/tcp` or `allow 5000:5010/udp`. Unknown names and invalid ports
stop the launcher before any scripts run.

```bash
sudo bash run_all.sh
```

The launcher only accepts interactive selection; command-line arguments and
the former `services` mode are removed. Every task script is shown in the menu.
Enter its displayed keywords separated by spaces, or enter `all` to select
every task. Press Enter without keywords to resume unfinished eligible tasks in
order, starting with the first `not_run` task. Explicit keywords (or `all`)
rerun completed tasks. Shared helper libraries and test scripts are not runnable tasks.
All service scripts, including UFW, are automatically skipped unless listed
in `input/critical_services.txt`, even if explicitly selected. The menu and final
status list show `ran` for tasks completed successfully across launcher runs,
`not_run` for tasks that have not completed successfully, and `N/a` for services
not listed as critical. Failed tasks and tasks blocked by a failed service stay
`not_run`; the result summary gives the failure or skip reason. Progress is saved after each successful task in the local, Git-ignored
`.run_all_status` file. A rerun clears its previous success before starting, so
failure or interruption leaves it retryable. Remove `.run_all_status` to reset
all progress for a new scenario.
`all` includes account/password changes, package removal, and a media inventory;
their existing prompts remain. Selecting an eligible service also selects UFW
if UFW is critical. Selecting critical UFW also sets up all listed
services so their actual ports can be discovered. When resuming, already
completed services are skipped; UFW is refreshed when a service is retried. A failed service causes UFW
to be skipped, and the launcher returns a failure summary. Other existing
scripts may also affect service accounts and files; review the scenario first.

- SSH installs OpenSSH, prohibits root and empty-password login globally, limits
  authentication attempts, validates configuration, and starts/enables SSH at
  boot. Existing ports, authentication methods, keys and Match rules remain;
  review Match-specific exceptions for the scenario.
- Apache installs Apache2, limits server-version disclosure, disables TRACE,
  validates configuration, and starts/enables it at boot. Existing virtual
  hosts, content, ports and TLS remain. HTTPS requires an existing TLS site and
  certificate; opening a firewall port alone does not configure HTTPS.
- vsftpd installs the FTP server, disables anonymous access, enables local
  accounts and transfer logging, and sets passive ports to 40000–40100. It
  preserves the local upload policy (a fresh install is read-only). Explicit
  FTPS is required by default, using a generated self-signed certificate that
  clients must trust. For a scenario requiring plaintext FTP, use
  `sudo env VSFTPD_TLS_REQUIRED=NO bash run_all.sh`, then select `vsftpd` or `all`. Existing filesystem
  permissions, account restrictions and NAT forwarding still apply.
- UFW installs/enables the firewall and boot startup, allows required ports
  before enabling deny-incoming/allow-outgoing defaults, and preserves existing
  rules. It discovers SSH ports (including active socket activation), active
  Apache listeners, and vsftpd control/passive ports. It also preserves the
  current SSH connection port when `SSH_CONNECTION` is available. Existing
  unrelated allow rules are retained and should be reviewed.

The launcher, service scripts, `misc` scripts and media-removal script append to
the root `all_logs.txt`, regardless of the working directory. Configuration
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

### Root files and shared helpers

| File | Description |
| --- | --- |
| `README.md` | Explains how to select tasks, configure critical services, run checks, and understand the project files. |
| `.gitattributes` | Tells Git to use Linux-style LF line endings for shell scripts. |
| `run_all.sh` | Shows an interactive menu for all 13 task scripts and runs selected tasks in order. It skips unlisted services and skips UFW if a required service fails. |
| `input/critical_services.txt` | Lists the services required by the scenario and any additional firewall ports to allow. Use one service per line, including `ufw` when needed, or `none` when no services are required. |
| `all_logs.txt` | Stores the shared, accumulating audit log with timestamps and script names. Scripts using the logging helper record configuration changes, permissions, actions, and failures here. |
| `logging.sh` | Provides shared functions for logging actions, comparing configuration files before and after edits, and recording permission changes. Other scripts source this helper rather than run it as a task. |
| `service_helpers/critical_services.sh` | Parses and validates the critical-service list, service aliases, and extra firewall port rules. It treats the text file as data rather than executable shell commands. |
| `service_helpers/service_common.sh` | Provides shared service prerequisites, package installation, startup checks, configuration backups, restoration, and setting-editing functions. The service scripts source this helper. |

### General hardening and removal scripts

| File | Description |
| --- | --- |
| `misc/kernel.sh` | Applies persistent and runtime sysctl hardening for networking and kernel protections. It also adjusts `/tmp` and `/dev/shm` permissions and mount options, including their existing fstab entries. |
| `misc/login.sh` | Locks the optional guest account and disables its shell. Configures guest protection only if LightDM is installed, without restarting the active desktop. SSH policy remains in `services/ssh.sh`. |
| `misc/file_permissions.sh` | Sets permissions on selected system files, directories, and user home directories. It also generates a report of world-writable files and directories. |
| `password_management/pwd_policy.sh` | Sets password-aging defaults in `/etc/login.defs` and a minimum password length of 12 in `/etc/security/pwquality.conf`. It installs libpam-pwquality if needed and enables the packaged PAM profile without forcing replacement of custom PAM stacks. |
| `password_management/reset_admin_pwd.sh` | Reads `auth_admins.txt` and resets each existing listed account to the script's `NEW_PASSWORD` value, currently `ChangeMe123!`. Edit that value before running if a different password is required. |
| `rm_stuff/rm_mp3+.sh` | Writes a read-only MP3/MOV/MP4 inventory to `log/media_files(2).txt`; reviewed removal is performed by `rm_stuff/rm_mp3+_2.sh` in the second launcher. |
| `rm_stuff/bad_pkg.sh` | Presents a list of potentially unwanted packages for optional editing and asks for confirmation before purging installed matches. After removal, it runs package autoremove. |
| `rm_stuff/malware_search.sh` | Scans cracking/remote-access tools and packages, cron/at jobs, startup persistence, processes, listeners, and writable temporary locations. All output and errors go to `log/malware_search.txt`; findings are not removed or executed. |

### User audit files

| File | Description |
| --- | --- |
| `user_management/user_management.sh` | Reads the authorized-user lists, audits interactive local accounts at every UID, flags extra UID-zero identities, and writes second-pass review reports without changing accounts. |
| `input/auth_users.txt` | Input list of authorized local usernames, one per line, based on the competition README. Blank lines and lines beginning with `#` are ignored. |
| `input/auth_admins.txt` | Input list of authorized administrator usernames, one per line. Both the user audit and administrator password-reset script read this file. |
| `log/unauth_users(2).txt` | Output list of audited users absent from `auth_users.txt`. The user audit overwrites this file each time it runs. |
| `log/unauth_admins(2).txt` | Output list of audited sudo/wheel members absent from `auth_admins.txt`, excluding accounts already reported as unauthorized users. The user audit overwrites this file each time it runs. |

### Service scripts

| File | Description |
| --- | --- |
| `services/ssh.sh` | Installs OpenSSH, applies global login restrictions, validates its configuration, and starts/enables SSH at boot. It backs up and restores the main configuration if validation or startup fails. |
| `services/apache2.sh` | Installs Apache2 and adds a configuration that reduces version disclosure and disables TRACE while retaining existing sites. It validates the configuration, starts/enables Apache at boot, and rolls back its configuration changes on failure. |
| `services/vsftpd.sh` | Installs vsftpd, disables anonymous access, enables local logins and transfer logging, and configures passive ports 40000–40100. It requires FTPS by default, starts/enables the service at boot, and restores its configuration if startup fails. |
| `services/ufw.sh` | Installs UFW, discovers required service ports, adds allow rules, and enables the firewall now and at boot. It applies deny-incoming/allow-outgoing defaults while retaining existing rules and supported SSH access ports. |

### Tests

| File | Description |
| --- | --- |
| `tests/logging_test.sh` | Tests configuration-change logs, permission logs, and media-deletion success and failure handling using temporary files and mocked commands. It does not run system hardening. |
| `tests/services_test.sh` | Tests service-list parsing, interactive task selection, automatic service skipping, rejected command-line modes, and failure handling. It also checks firewall port discovery using temporary fixtures and mocked system commands. |

### Generated text reports

These files are created when the relevant scripts run and may not exist yet.
The permission report and individual scan reports are overwritten on subsequent
runs, unlike the accumulating `all_logs.txt`.

| File | Description |
| --- | --- |
| `log/world_files.txt` | Lists world-writable regular files and directories found by the permission-hardening script, along with the report generation time. |

## Package updates and file locations

After selecting eligible tasks, `run_all.sh` runs `sudo apt update` and then
`sudo apt upgrade` before the selected scripts. The upgrade retains its normal
confirmation prompt. If either command fails, the launcher stops and records
the failure in `all_logs.txt`.

Edit the scenario input lists in `input/`: `critical_services.txt`,
`auth_users.txt`, and `auth_admins.txt`. Generated reports are stored in `log/`.
The shared audit log remains at the repository root as `all_logs.txt`.

## Sudo and polkit administrator allowlist

Before running `misc/kernel.sh` (or selecting `ker` in the launcher), populate
`input/auth_admins.txt` with existing administrator usernames, one per line.
Blank lines and full-line comments are allowed. Empty lists, invalid names,
missing accounts, and non-root names with UID zero stop the script before
hardening begins. Root remains an administrator for recovery.

The script replaces `/etc/sudoers` with explicit password-required grants for
the listed users and root, with password caching disabled. Existing group grants
and sudoers includes no longer apply; their files remain on disk. It validates
the existing and generated sudoers with `visudo`, validates the installed policy,
and restores the previous policies if installation fails. Root-only backups
are retained under `/var/backups/cyberpatriot-admin-access.*`; the exact path
and policy changes are recorded in `all_logs.txt`.

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

Password management backs up PAM and password configuration to a root-only
`/var/backups/cyberpatriot-password-policy.*` directory, configures 12-character
password quality without length credits, enables the packaged pwquality profile,
and checks that it is required by `common-password`. Custom PAM stacks are not
force-overwritten; failures stop the task for review with the backup location
logged. Existing account expiration settings and PAM module binaries are not
rewritten. Module arguments can override configuration-file settings; inspect
custom overrides. See [pam-auth-update](https://manpages.debian.org/bookworm/libpam-runtime/pam-auth-update.8.en.html).

Run `python3 tests/auth_permissions_test.py` for temporary-file checks of account,
PAM, module, and log permissions, backups, symlink handling, and repeat runs. These tests
do not change system ownership, configuration, or running services.

## Malware indicator scan

Run `sudo bash rm_stuff/malware_search.sh` directly, or select `mal` in
`run_all.sh`. The old `cra` selection remains an alias. `all` includes the new
scan before cleanup tasks. Old `cra` completion records do not mark `mal`
complete, so resuming will run the replacement scan. The launcher installs
`procps`, `iproute2`, `file`, `findutils`, `grep`, `sed`, and `coreutils` when
the scan is selected. It does not install cracking tools or enable cron.

Each run overwrites `log/malware_search.txt` with one transcript containing
stdout, stderr, findings, and completion status. The report has mode `0600`
because cron entries and process arguments may contain sensitive information.
Existing old numbered reports are retained as historical files. The launcher's
normal start/pass/fail records still go to `all_logs.txt`.

The scan queries installed packages and tool locations, reads system and every
local user's cron spool plus at jobs, inspects local startup entries, lists
network listeners, and looks for suspicious process command lines and executable
paths. It recursively inventories regular files in `/tmp`, `/var/tmp`,
`/dev/shm`, and `/run/user/<uid>`, including nested or non-executable payloads.
Text files up to 1 MiB are checked for tool names and backdoor indicators;
larger and binary files still receive metadata/type reporting. It never runs
or deletes discovered files. Missing commands and scan errors produce a failed
status so the launcher can retry. Findings require review: legitimate tools
and cron jobs can match, and this heuristic scan cannot prove a system clean.

Run `python3 tests/test_malware_search.py` for isolated scanner and launcher
checks without installing packages, scanning the host, or running hardening.

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
bash tests/backups_test.sh
python3 tests/backup_commands_test.py
```

### Managed service policy

Before each launcher run (including resume), unlisted BIND9, MySQL/MariaDB, Postfix, Sendmail, Samba, WordPress, Joomla, OpenVPN and Nginx are **disabled, never automatically uninstalled**. Packages, databases and site files remain in place. Review `input/critical_services.txt` against the competition README first. Empty lists are rejected; `none` explicitly disables all managed services. Ubuntu stops, disables and persistently masks systemd units; FreeBSD stops native services, writes boot flags and checks that services are no longer boot-enabled. Custom service names/startup jobs need manual review.

WordPress/Joomla have no separate daemon. Their discovered document roots are backed up and made inaccessible with mode `000`, which survives reboot and blocks ordinary unprivileged web workers. Original modes are saved privately in `/var/lib/cyberpatriot/disabled-sites` and restored when the application becomes critical again. This assumes normal, unprivileged web workers; custom root-running web applications need manual isolation. Overlap with a critical site's root stops the operation. Usual locations are `/var/www`, `/usr/share/wordpress`, `/usr/local/www`; add custom roots in `input/web_apps.txt`. Existing critical CMS configuration is checked only when Apache or Nginx is explicitly critical. No web/database dependency becomes critical implicitly.

Each managed service has a script under `services/`; `mariadb.sh` and `smb.sh` are aliases. Native settings and database engines are preserved. Configuration checks precede enabling services. OpenVPN needs existing scenario-specific profiles and certificates; CMS deployment, database credentials and virtual hosts remain scenario-specific. FreeBSD uses available native packages or logs an unavailable implementation as skipped. Firewalls use actual critical-service listeners. The separate interactive package-removal task still removes packages you explicitly approve.

### Initial system repairs

`run_all.sh` sets a trusted PATH before its first external command. After validating task selection and root access, it runs `service_helpers/startup_repair.sh` before service reconciliation, upgrades or selected tasks, including on resume. Any failed repair stops subsequent tasks.

Ubuntu scans `/etc`, `/var/lib/dpkg`, `/var/lib/apt` and `/var/cache/apt` for immutable/append-only flags. It backs up affected paths, records original flags in the backup, then clears the flags. It also repairs the default login PATH in `/etc/environment`, preserving other variables. Individual shell startup files can still override PATH and need manual review. FreeBSD performs the native flag repair in `/etc`, `/usr/local/etc` and `/var/db/pkg`; securelevel restrictions may require single-user repair. Neither implementation clears flags across the whole filesystem.

Healthy APT sources are left alone. Recognized malformed-source, conflicting-signature or repository-signature/release errors trigger an official Ubuntu source candidate for the detected release and architecture. The candidate must pass signature-checked updates before live sources are backed up and disabled under `.disabled-cp-*` filenames. Third-party definitions remain recoverable but need review before reenabling. A failed final update restores original source definitions. Network, clock, lock, storage, missing-keyring and unsupported/EOL-release problems stop with an explanation instead of bypassing authentication. FreeBSD has no APT: it refreshes native `pkg` metadata and preserves custom repository definitions, stopping on failures.

Run the fixture tests instead of executing hardening scripts on a development workstation. Actual native-host testing remains necessary.

### Suspicious-services log

`suspicious_services.txt` is a separate, private, timestamped log appended on every service-policy run, before services are disabled (including launcher resume). It reports installed packages and discovered services from a review catalog when their family is absent from `input/critical_services.txt`. For example, installed or running Apache is reported when `apache2` is not critical. Entries distinguish installed packages from runtime and boot state; disabled services are still listed for review. These findings indicate unnecessary exposure to investigate, not confirmed malware.

The catalog includes the managed web, database, mail, file-sharing and VPN services, plus SSH, other FTP servers, Telnet/rsh/TFTP, NFS/rpcbind, SNMP, Avahi, printing, Redis, MongoDB, PostgreSQL, Tor, RDP/VNC, proxies, rsync, inetd/xinetd and container runtimes. The scan only logs findings; it does not expand the automatic disabling policy. Custom service names and unpackaged applications need manual review. Inventory errors are logged as incomplete and stop the service-policy run. Run `bash misc/suspicious_services.sh` as root for the audit alone.

### First-pass review and second-pass cleanup

Populate `input/auth_users.txt` and `input/auth_admins.txt` first. At least one existing non-root administrator is required; administrator entries also count as authorized users. In `run_all.sh`, select `usr mp3` to generate the account and media inventories. These two first-pass tasks only report; they do not delete users or media. Other first-launcher tasks retain their existing behavior.

Review `log/unauth_users(2).txt`, `log/unauth_admins(2).txt`, and `log/media_files(2).txt`. Remove whole candidate lines for accounts/files that must be retained, or correct the allowlists and rerun the audit. The account reports contain usernames and their numeric UIDs; the media report contains an identity signature, a tab, and the absolute path. Do not edit those identity fields.

Then run `sudo bash run_all_2.sh` on Ubuntu, or `bash run_all_2.sh` from a FreeBSD root shell. This explicit second launcher deletes reviewed unauthorized local accounts (retaining home directories), revokes reviewed administrator memberships and local sudo/doas access, restricts installed polkit administrator identities, and removes the reviewed media files after backing them up. It does not rerun upgrades or general hardening. User deletion is not forced: active sessions, UID-zero aliases, the invoking sudo/doas account, identity changes, or failed backups stop or fail cleanup for review. Revoked users must log out of existing sessions; existing root shells and custom polkit action grants require separate review.

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
