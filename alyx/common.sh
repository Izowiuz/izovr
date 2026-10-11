#!/usr/bin/env bash
# Shared by the Half-Life: Alyx workarounds in this folder. Sourced, never executed.
# Each one undoes a game bug until Valve fixes it. When a fix ships, delete the
# folder: nothing outside it depends on these scripts.
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"

ALYX_GAME="${ALYX_DIR:-$STEAM_ROOT/steamapps/common/Half-Life Alyx}/game"

alyx_running() {
    local d exe
    for d in /proc/[0-9]*; do
        exe=$(readlink -f "$d/exe" 2>/dev/null) || continue
        [[ "$exe" == */linuxsteamrt64/hlvr ]] && return 0
    done
    return 1
}
