#!/usr/bin/env bash
# Isolated fixtures and mocked FreeBSD commands; never changes system policy.
set -euo pipefail
CP_DISTRO=freebsd
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cyberpatriot-audits-test.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/user_management" "$work/rm_stuff" "$work/input" "$work/log" "$work/media"
printf 'alice\r\n jane  # authorized account\n' > "$work/input/auth_users.txt"
printf 'alice\n' > "$work/input/auth_admins.txt"
printf 'ssh\napache24\nvsftpd\npf\n' > "$work/input/critical_services.txt"

(
    source "$ROOT/../../user_management/user_management.sh"
    SCRIPT_DIR="$work/user_management"
    SECOND_ROOT="$work"
    account_platform_init() { ACCOUNT_PLATFORM=freebsd; }
    init_logging() { :; }
    log() { printf '%s\n' "$*"; }
    sudo() { echo 'User is not allowed to run sudo'; return 1; }
    require_freebsd_root() { :; }
    require_commands() { :; }
    pw() {
        [[ "$*" == 'usershow -7 -a' ]] || return 1
        printf '%s\n' 'root:*:0:0:root:/root:/bin/sh' 'alice:*:1001:1001::/home/alice:/bin/sh' \
            'bob:*:1002:1002::/home/bob:/bin/sh' 'jane:*:1003:1003::/home/jane:/bin/sh' \
            'lowadmin:*:900:0::/home/lowadmin:/bin/sh' 'toor:*:0:0::/root:' \
            'daemon:*:2000:2000::/nonexistent:/usr/sbin/nologin'
    }
    getent() { [[ "$*" == 'group wheel' ]]; }
    id() {
        [[ "$1" == -nG ]] || return 1
        case "$2" in alice|bob|jane|lowadmin|toor) printf '%s wheel\n' "$2" ;; *) printf '%s\n' "$2" ;; esac
    }
    main <<< n
) > "$work/users-output"
printf 'bob\t1002\nlowadmin\t900\ntoor\t0\n' > "$work/expected-users"
printf 'jane\t1003\n' > "$work/expected-admins"
diff -u "$work/expected-users" <(grep -v '^#' "$work/log/unauth_users(2).txt")
diff -u "$work/expected-admins" <(grep -v '^#' "$work/log/unauth_admins(2).txt")

(
    source "$ROOT/rm_stuff/bad_pkg.sh"
    SCRIPT_DIR="$work/platforms/FreeBSD/rm_stuff"
    mkdir -p "$SCRIPT_DIR"
    require_freebsd_root() { :; }
    require_commands() { :; }
    init_logging() { :; }
    log() { printf '%s\n' "$*"; }
    mktemp() { command mktemp "$work/package-list.XXXXXX"; }
    test_editor() { printf '%s\n' nmap john apache24 vsftpd-ssl pkg FreeBSD-base > "$1"; }
    EDITOR=test_editor
    pkg() {
        printf '%s\n' "$*" >> "$work/pkg-calls"
        case "$*" in
            "query -a %n") printf '%s\n' nmap john apache24 vsftpd-ssl pkg FreeBSD-base ;;
            "query -C %rn nmap") : ;;
            "query -C %rn john") printf 'apache24\n' ;;
            'delete -Cn nmap'|'delete -Cy nmap') : ;;
            *) printf 'Unexpected pkg call: %s\n' "$*" >&2; return 1 ;;
        esac
    }
    backup_package_configuration() { :; }
    main <<< $'y\nREMOVE'
) > "$work/packages-output"
[[ $(grep -c '^delete -Cy ' "$work/pkg-calls") == 1 ]]
grep -q '^delete -Cy nmap$' "$work/pkg-calls"
grep -q 'PRESERVED package required by installed software: john' "$work/packages-output"
for name in apache24 vsftpd-ssl pkg FreeBSD-base; do
    grep -q "PRESERVED protected package: $name" "$work/packages-output"
done

touch "$work/media/first song.mp3" "$work/media/second.mov"
(
    source "$ROOT/../../rm_stuff/rm_mp3+.sh"
    SECOND_ROOT="$work"
    account_platform_init() { ACCOUNT_PLATFORM=freebsd; }
    media_signature() { command stat -c '%d:%i:%s:%Y:%Z' "$1"; }
    backup_system_paths() { SYSTEM_BACKUP_DIR="$work/backup"; mkdir -p "$SYSTEM_BACKUP_DIR"; }
    require_freebsd_root() { :; }
    require_commands() { :; }
    init_logging() { :; }
    log() { printf '%s\n' "$*"; }
    mktemp() { command mktemp "$work/media-inventory.XXXXXX"; }
    MEDIA_ROOT="$work/media"
    find() {
        printf '%s\n' "$*" >> "$work/find-calls"
        printf '%s\0' "$work/media/first song.mp3" "$work/media/second.mov"
    }
    rm() {
        if [[ "$1" == -- ]]; then
            printf '%s\n' "$2" >> "$work/media-deletions"
            [[ "$2" != *second.mov ]]
        else
            command rm "$@"
        fi
    }
    main
    [[ -f "$work/log/media_files(2).txt" ]]
    [[ ! -e "$work/media-deletions" ]]
    if media_cleanup; then echo 'Media deletion failure was lost' >&2; exit 1; fi
) > "$work/media-output"
[[ $(wc -l < "$work/media-deletions" | tr -d ' ') == 2 ]]
grep -q -- '-fstype devfs' "$work/find-calls"
grep -q -- '-fstype linprocfs' "$work/find-calls"
grep -q -- '-fstype rdonly' "$work/find-calls"
grep -q 'FAILED deleting media:' "$work/media-output"

(
    source "$ROOT/rm_stuff/malware_search.sh"
    ps() { [[ "$*" == '-axww -o user,pid,ppid,command' ]] || return 1; printf 'root 12 1 nc -l 1234\n'; }
    sockstat() { [[ "$*" == -46l ]] || return 1; printf 'root sshd 1 4 tcp4 *:22 *:*\n'; }
    procstat() { [[ "$*" == '-a -b' ]] || return 1; printf '12 demo 1403000 /tmp/demo\n'; }
    scan_processes
    ((SCAN_ERRORS == 0))
    sockstat() { return 1; }
    scan_processes
    ((SCAN_ERRORS == 1))
) > "$work/process-output" 2>&1
grep -q '/tmp/demo' "$work/process-output"
grep -q 'INCOMPLETE: socket query failed' "$work/process-output"
printf 'PASS: FreeBSD account audits, protected-package removal, two-pass media inventory/failure, process scan failures.\n'
