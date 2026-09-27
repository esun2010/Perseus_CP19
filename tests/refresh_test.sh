#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/service_helpers/service_common.sh"
log() { :; }
load_distribution() { CP_DISTRO=debian; }
active=yes
reloadable=yes
reload_ok=yes
calls=()
systemctl() {
    calls+=("$1")
    case "$1" in
        is-active) [[ $active == yes ]] ;;
        show) if [[ "$2" == --property=LoadState ]]; then echo loaded; else echo "$reloadable"; fi ;;
        reload) [[ $reload_ok == yes ]] ;;
        *) return 99 ;;
    esac
}
refresh_service ssh
[[ " ${calls[*]} " == *' reload '* ]]
active=no; calls=()
if refresh_service ssh; then exit 1; fi
[[ " ${calls[*]} " != *' reload '* ]]
active=yes; reloadable=no; calls=()
if refresh_service ssh; then exit 1; fi
[[ " ${calls[*]} " != *' reload '* ]]
reloadable=yes; reload_ok=no
if refresh_service ssh; then exit 1; fi
printf 'PASS refresh only: active, inactive, unsupported and failed reloads\n'
