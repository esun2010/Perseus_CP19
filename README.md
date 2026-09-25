# Description
This is a set of scripts to run for CyberPatriot Linux

TO-DO:
1. make all config file management input changes into a big log file
2. review scenario-specific settings before running scripts
3. pwd_cracking_search sucks

changes admin password to ChangeMe123!



AI COMMENTS GO DOWN HERE(do not edit or change anything above):

Service setup requires Debian/Ubuntu (including compatible Mint versions),
`apt-get`, and a running systemd system. Run scripts with `sudo bash`.

Edit `critical_services.txt` using the competition README. Remove `none` and
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
in `critical_services.txt`, even if explicitly selected. The menu and final
status list show `ran` for tasks completed successfully across launcher runs,
`not_run` for tasks that have not completed successfully, and `N/a` for services
not listed as critical. Failed tasks and tasks blocked by a failed service stay
`not_run`; the result summary gives the failure or skip reason. Progress is saved after each successful task in the local, Git-ignored
`.run_all_status` file. A rerun clears its previous success before starting, so
failure or interruption leaves it retryable. Remove `.run_all_status` to reset
all progress for a new scenario.
`all` includes account/password changes, package removal, and media deletion;
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
status and failures are logged. SSH/Apache validate before restarting and restore
their configurations on failure. vsftpd has no validation-only mode, so failed
startup triggers restoration. Backups are stored next to the changed files.

Safe checks (temporary fixtures and mocked commands; no system hardening):

```bash
bash tests/logging_test.sh
bash tests/services_test.sh
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
| `critical_services.txt` | Lists the services required by the scenario and any additional firewall ports to allow. Use one service per line, including `ufw` when needed, or `none` when no services are required. |
| `all_logs.txt` | Stores the shared, accumulating audit log with timestamps and script names. Scripts using the logging helper record configuration changes, permissions, actions, and failures here. |
| `logging.sh` | Provides shared functions for logging actions, comparing configuration files before and after edits, and recording permission changes. Other scripts source this helper rather than run it as a task. |
| `service_helpers/critical_services.sh` | Parses and validates the critical-service list, service aliases, and extra firewall port rules. It treats the text file as data rather than executable shell commands. |
| `service_helpers/service_common.sh` | Provides shared service prerequisites, package installation, startup checks, configuration backups, restoration, and setting-editing functions. The service scripts source this helper. |

### General hardening and removal scripts

| File | Description |
| --- | --- |
| `misc/kernel.sh` | Applies persistent and runtime sysctl hardening for networking and kernel protections. It also adjusts `/tmp` and `/dev/shm` permissions and mount options, including their existing fstab entries. |
| `misc/login.sh` | Attempts to lock and delete the guest account, sets LightDM's `allow-guest=false`, and restarts LightDM. SSH configuration is handled separately by `services/ssh.sh`. |
| `misc/file_permissions.sh` | Sets permissions on selected system files, directories, and user home directories. It also generates a report of world-writable files and directories. |
| `password_management/pwd_policy.sh` | Sets password-aging defaults in `/etc/login.defs` and a minimum password length of 12 in `/etc/security/pwquality.conf`. It does not install or enable a PAM password-quality module. |
| `password_management/reset_admin_pwd.sh` | Reads `auth_admins.txt` and resets each existing listed account to the script's `NEW_PASSWORD` value, currently `ChangeMe123!`. Edit that value before running if a different password is required. |
| `rm_stuff/rm_mp3+.sh` | Deletes MP3, MOV, and MP4 files beneath `/`, excluding `/proc`, `/sys`, `/dev`, and `/run`. Each successful deletion or deletion failure is recorded in the shared log. |
| `rm_stuff/bad_pkg.sh` | Presents a list of potentially unwanted packages for optional editing and asks for confirmation before purging installed matches. After removal, it runs package autoremove. |
| `rm_stuff/pwd_cracking_search.sh` | Audits tools, packages, processes, hardware, remote access, scheduled jobs, and network listeners for indicators worth investigating. It prints findings and writes separate text reports under `rm_stuff/logs/` without automatically removing the findings. |

### User audit files

| File | Description |
| --- | --- |
| `user_management/user_management.sh` | Opens the authorized-user lists in nano, then audits local accounts with UID 1000 or higher and a usable login shell. It reports unauthorized users and sudo/wheel administrators without deleting accounts or changing group membership. |
| `user_management/auth_users.txt` | Input list of authorized local usernames, one per line, based on the competition README. Blank lines and lines beginning with `#` are ignored. |
| `user_management/auth_admins.txt` | Input list of authorized administrator usernames, one per line. Both the user audit and administrator password-reset script read this file. |
| `user_management/unauth_users.txt` | Output list of audited users absent from `auth_users.txt`. The user audit overwrites this file each time it runs. |
| `user_management/unauth_admins.txt` | Output list of audited sudo/wheel members absent from `auth_admins.txt`, excluding accounts already reported as unauthorized users. The user audit overwrites this file each time it runs. |

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
| `misc/world_files.txt` | Lists world-writable regular files and directories found by the permission-hardening script, along with the report generation time. |
| `rm_stuff/logs/01_tools_in_path.txt` | Reports whether the scan's configured cracking-tool commands can be found in the command search path. |
| `rm_stuff/logs/02_package_manager_check.txt` | Lists installed package records matching cracking-tool or GPU-computing keywords. |
| `rm_stuff/logs/03_suspicious_processes.txt` | Lists running processes whose command lines match the scan's cracking-tool and GPU-computing keywords. |
| `rm_stuff/logs/04_top_cpu.txt` | Shows the processes with the highest reported CPU usage. |
| `rm_stuff/logs/05_gpu_pci_devices.txt` | Lists PCI graphics and display devices detected by `lspci`. |
| `rm_stuff/logs/06_nvidia_gpu.txt` | Reports NVIDIA GPU memory information and process activity when `nvidia-smi` is available. |
| `rm_stuff/logs/07_opencl_rocm.txt` | Records OpenCL device details and ROCm status when their inspection tools are available. |
| `rm_stuff/logs/08_block_devices.txt` | Lists storage devices, models, connection types, sizes, and mount points. |
| `rm_stuff/logs/09_usb_devices.txt` | Lists connected USB devices when `lsusb` is available. |
| `rm_stuff/logs/10_usb_kernel_log.txt` | Collects matching USB and storage-related kernel messages from the previous 24 hours. |
| `rm_stuff/logs/11_media_mounts.txt` | Lists mounted filesystems under `/media` or `/run/media`. |
| `rm_stuff/logs/12_ssh_authorized_keys.txt` | Reports the presence and file metadata of SSH authorized-key files in user home directories and `/root`. It does not print the key contents. |
| `rm_stuff/logs/13_ssh_sessions.txt` | Shows logged-in sessions and network connections matching SSH port 22. |
| `rm_stuff/logs/14_cron_jobs.txt` | Shows the root crontab and directory listings for system cron locations and stored user crontabs. |
| `rm_stuff/logs/15_systemd_units.txt` | Lists running services after filtering out several familiar service-name prefixes for manual review. |
| `rm_stuff/logs/16_apt_dpkg_log.txt` | Extracts installation, upgrade, and removal entries from the last 200 lines of the available apt or dpkg log. |
| `rm_stuff/logs/17_tmp_executables.txt` | Lists executable regular files found within two directory levels of `/tmp`, `/var/tmp`, and `/dev/shm`. |
| `rm_stuff/logs/18_listening_sockets.txt` | Reports listening TCP and UDP sockets and associated process information where available. |
| `rm_stuff/logs/19_nvidia_processes.txt` | Lists NVIDIA compute processes and their GPU-memory usage. This report is generated only when `nvidia-smi` is available. |
| `rm_stuff/logs/20_summary.txt` | Summarizes simple indicators involving cracking tools, GPUs, and mounted storage to guide further investigation. These indicators do not establish whether activity is unauthorized. |
| `rm_stuff/logs/21_remediation_steps.txt` | Contains suggested investigation and remediation steps for reviewing scan findings. These instructions are written to the report, not executed automatically. |
