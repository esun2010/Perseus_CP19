#!/usr/bin/env bash
# Resolve only explicit native overrides. Everything else uses the shared tree.
# Called after load_distribution; SCRIPT_DIR is the repository root launcher dir.
resolve_task_paths() {
    [[ "$CP_DISTRO" == freebsd ]] || return 0
    local key native
    for key in "${ORDER[@]}"; do
        native="platforms/FreeBSD/${SCRIPT_MAP[$key]}"
        if [[ -f "$SCRIPT_DIR/$native" ]]; then SCRIPT_MAP[$key]="$native"; fi
    done
}

require_launcher_platform() {
    if [[ "$CP_DISTRO" == freebsd ]]; then
        source "$SCRIPT_DIR/platforms/FreeBSD/service_helpers/platform.sh"
        require_freebsd_root || return 1
    fi
}
