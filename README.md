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
every task. Shared helper libraries and test scripts are not runnable tasks.
All service scripts, including UFW, are automatically skipped unless listed
in `critical_services.txt`, even if explicitly selected. The menu marks them.
`all` includes account/password changes, package removal, and media deletion;
their existing prompts remain. Selecting an eligible service also selects UFW
if UFW is critical. Selecting critical UFW also sets up all listed
services so their actual ports can be discovered. A failed service causes UFW
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
