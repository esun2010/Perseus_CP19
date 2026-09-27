#!/usr/bin/env bash
# Read metadata as data: never execute os-release or user input.
distro_value() {
    local key="$1" file="$2"
    sed -n "s/^${key}=//p" "$file" | sed "s/^[\"']//; s/[\"']$//"
}
load_distribution() {
    local root selection detected
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    selection=$(sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^[[:space:]]*$/d' "$root/input/distribution.txt") || return 1
    case "$selection" in ubuntu|debian|mint|freebsd|auto) ;; *) echo 'Select exactly one distribution: ubuntu, debian, mint, freebsd or auto.' >&2; return 1 ;; esac
    if [[ $(uname -s) == FreeBSD ]]; then
        [[ "$selection" == auto || "$selection" == freebsd ]] || {
            echo "Distribution input ($selection) does not match this system (freebsd)." >&2; return 1;
        }
        CP_DISTRO=freebsd; CP_BASE=freebsd; CP_CODENAME=; CP_BASE_CODENAME=
        return 0
    fi
    [[ $(uname -s) == Linux ]] || { echo 'Unsupported operating system.' >&2; return 1; }
    detected=$(distro_value ID /etc/os-release) || return 1
    case "$detected" in ubuntu|debian) ;; linuxmint) detected=mint ;; *) echo "Unsupported distribution: $detected" >&2; return 1 ;; esac
    [[ "$selection" == auto || "$selection" == "$detected" ]] || {
        echo "Distribution input ($selection) does not match this system ($detected)." >&2; return 1;
    }
    CP_DISTRO=$detected
    CP_CODENAME=$(distro_value VERSION_CODENAME /etc/os-release) || return 1
    CP_BASE=$detected; CP_BASE_CODENAME=$CP_CODENAME
    if [[ "$detected" == mint ]]; then
        CP_BASE_CODENAME=$(distro_value UBUNTU_CODENAME /etc/os-release) || return 1
        CP_BASE=ubuntu
        if [[ -z "$CP_BASE_CODENAME" ]]; then
            CP_BASE=$(distro_value ID /etc/upstream-release/os-release) || return 1
            CP_BASE_CODENAME=$(distro_value VERSION_CODENAME /etc/upstream-release/os-release) || return 1
        fi
    fi
    [[ "$CP_BASE" == ubuntu || "$CP_BASE" == debian ]] &&
        [[ "$CP_CODENAME" =~ ^[a-z]+$ && "$CP_BASE_CODENAME" =~ ^[a-z]+$ ]] || {
        echo 'Cannot safely identify distribution release/base; no changes made.' >&2; return 1;
    }
}

write_distribution_sources() {
    [[ "$CP_BASE" != freebsd ]] || { echo "FreeBSD uses pkg, not APT." >&2; return 1; }
    local arch mirror security keyring components
    local codename="$CP_BASE_CODENAME"
    if [[ "$CP_BASE" == ubuntu ]]; then
        keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg
        components='main restricted universe multiverse'
        arch=$(dpkg --print-architecture) || return 1
        case "$arch" in
            amd64|i386) mirror=https://archive.ubuntu.com/ubuntu; security=https://security.ubuntu.com/ubuntu ;;
            arm64|armhf|ppc64el|s390x|riscv64) mirror=https://ports.ubuntu.com/ubuntu-ports; security=$mirror ;;
            *) echo "Unsupported Ubuntu architecture: $arch" >&2; return 1 ;;
        esac
    else
        keyring=/usr/share/keyrings/debian-archive-keyring.gpg
        components='main contrib non-free'
        case "$codename" in buster|bullseye) ;; *) components+=' non-free-firmware' ;; esac
        mirror=https://deb.debian.org/debian
        security=https://security.debian.org/debian-security
    fi
    [[ -f "$keyring" ]] || { echo "Missing trusted archive keyring: $keyring" >&2; return 1; }
    cat <<SOURCES
Types: deb
URIs: $mirror
Suites: $codename $codename-updates $codename-backports
Components: $components
Signed-By: $keyring

Types: deb
URIs: $security
Suites: $codename-security
Components: $components
Signed-By: $keyring
SOURCES
    if [[ "$CP_DISTRO" == mint ]]; then
        keyring=/usr/share/keyrings/linuxmint-keyring.gpg
        [[ -f "$keyring" ]] || { echo "Missing trusted Mint archive keyring: $keyring" >&2; return 1; }
        cat <<SOURCES

Types: deb
URIs: https://packages.linuxmint.com
Suites: $CP_CODENAME
Components: main upstream import backport
Signed-By: $keyring
SOURCES
    fi
}

# Debian-family services share systemd semantics. Resolve installed aliases instead
# of assuming every edition ships the same daemon/unit name.
distribution_service_unit() {
    local requested="$1" candidate
    local -a candidates=("$requested")
    case "$CP_DISTRO:$requested" in
        ubuntu:ssh|debian:ssh|mint:ssh) candidates=(ssh sshd) ;;
        ubuntu:mysql|debian:mysql|mint:mysql) candidates=(mysql mariadb) ;;
        ubuntu:bind9|debian:bind9|mint:bind9) candidates=(bind9 named) ;;
    esac
    for candidate in "${candidates[@]}"; do
        if [[ $(systemctl show --property=LoadState --value "$candidate" 2>/dev/null) == loaded ]]; then
            printf '%s\n' "$candidate"; return 0
        fi
    done
    echo "No installed $CP_DISTRO service unit for $requested" >&2
    return 1
}
