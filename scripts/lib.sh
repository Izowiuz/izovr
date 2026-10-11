#!/usr/bin/env bash
# Shared helpers. Sourced, never executed.
#
# Every script here follows the same contract:
#   <script>              check current state, change nothing
#   <script> --apply      make the change
#   <script> --restore    undo it (only where undoing makes sense)

IZOVR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_DIR="$IZOVR_ROOT/reports"
mkdir -p "$REPORT_DIR"

# iw, rfkill and setcap live in /usr/sbin, which is not in a normal user PATH.
case ":$PATH:" in *":/usr/sbin:"*) ;; *) PATH="$PATH:/usr/sbin:/sbin" ;; esac
export PATH

if [[ -t 1 ]]; then
    C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_B=$'\033[1m'; C_D=$'\033[2m'; C_0=$'\033[0m'
else
    C_G=''; C_Y=''; C_R=''; C_B=''; C_D=''; C_0=''
fi

MODE=check
for a in "$@"; do
    case "$a" in
        --apply)   MODE=apply ;;
        --restore) MODE=restore ;;
        -h|--help) MODE=help ;;
    esac
done

ok()   { printf '  %s[ ok ]%s %s\n'   "$C_G" "$C_0" "$*"; }
miss() { printf '  %s[ -- ]%s %s\n'   "$C_Y" "$C_0" "$*"; }
bad()  { printf '  %s[fail]%s %s\n'   "$C_R" "$C_0" "$*"; }
info() { printf '  %s%s%s\n'          "$C_D" "$*" "$C_0"; }
title(){ printf '\n%s%s%s\n' "$C_B" "$*" "$C_0"; }

# hint <script-name> - printed when something is not applied and we are only checking
hint() { info "to change this:  ./scripts/$(basename "$1") --apply"; }

# probe <what was read> - shows the exact command or path behind a verdict, so
# nothing has to be taken on trust. Suppress with IZOVR_BRIEF=1.
# cmp_state <label> <now> <want> [opt|ok|miss]
# Always shows the current value next to the wanted one, so a verdict never
# stands on its own. Pass "opt" as the 4th argument for optional settings:
# they are reported without being called a failure.
cmp_state() {
    local label="$1" now="$2" want="$3" kind="${4:-}"
    local line; line=$(printf '%-20s now: %-24s want: %s' "$label" "$now" "$want")
    case "$kind" in
        ok)   ok "$line" ;;
        miss) miss "$line" ;;
        opt)  [[ "$now" == "$want" ]] && ok "$line" || info "$line  (optional)" ;;
        *)    [[ "$now" == "$want" ]] && ok "$line" || miss "$line" ;;
    esac
}

probe() { [[ "${IZOVR_BRIEF:-0}" == "1" ]] || printf '  %s  reads: %s%s\n' "$C_D" "$*" "$C_0"; }

confirm() {
    [[ "${IZOVR_YES:-0}" == "1" ]] && return 0
    local a; read -r -p "  ?  $1 [y/N] " a
    [[ "$a" =~ ^([yY]|yes)$ ]]
}

have() { command -v "$1" >/dev/null 2>&1; }

dongle_iface() {
    nmcli -t -f DEVICE,TYPE dev status 2>/dev/null \
        | awk -F: '$2=="wifi" && $1 ~ /u[0-9]+$/ {print $1; exit}'
}

other_wifi_ifaces() {
    nmcli -t -f DEVICE,TYPE dev status 2>/dev/null \
        | awk -F: '$2=="wifi" && $1 !~ /u[0-9]+$/ {print $1}'
}

STEAM_ROOT="${STEAM_ROOT:-$HOME/.steam/steam}"
STEAM_USERDATA="$HOME/.local/share/Steam/userdata"
REMOTE_PLAY_UDP="27031-27036"
REMOTE_PLAY_TCP="27036-27037"
VRLINK_UDP="10400-10401"

# SteamVR renames its own processes - a live vrserver has been seen reporting itself
# as "vrwebhe" - so `pgrep -x vrserver` misses it entirely. Going the other way,
# `pgrep -f` on the install path matches any shell whose command line merely mentions
# it, the scripts in this repo included, which reads as a false positive. Resolving
# /proc/<pid>/exe dodges both: that is the real binary on disk, whatever the process
# has renamed itself to. Prints one "<pid> <binary>" line per SteamVR process.
steamvr_procs() {
    local d exe
    for d in /proc/[0-9]*; do
        exe=$(readlink -f "$d/exe" 2>/dev/null) || continue
        case "$exe" in */SteamVR/bin/linux64/*) printf '%s %s\n' "${d#/proc/}" "${exe##*/}" ;; esac
    done
}
steamvr_pids()    { steamvr_procs | awk '{print $1}'; }
steamvr_running() { [[ -n "$(steamvr_pids)" ]]; }
export -f steamvr_procs steamvr_pids steamvr_running

# A `sudo cmd && ok "..."` pair prints nothing at all when the command fails: the &&
# short-circuits, the script still exits 0, and a change that never happened looks
# exactly like a silent success. run_priv runs the command and owns the failure
# report, so the caller only supplies its own success line and the fact to state.
#
#   run_priv "<success line>" "<fact if it failed>" sudo some-command --flag
priv_failed() {
    local fact="$1"; shift
    bad "The command failed.${fact:+ $fact}"
    info "Run the command yourself to see the error."
    info "    $*"
    return 1
}

run_priv() {
    local okmsg="$1" fact="$2"; shift 2
    if "$@"; then ok "$okmsg"; else priv_failed "$fact" "$@"; fi
}

VPN_UNIT=wg-quick@wg0-client
STEAMVR_APPID=250820

# --- SteamVR process tree -------------------------------------------------------
# Steam keeps the STOP button lit while the reaper it started is alive.
# To kill only the binaries under SteamVR/bin/linux64 leaves that reaper running.
#
# This code does not use `pkill -f`. That command compares command lines.
# It also kills a shell whose arguments mention SteamVR.
# This code reads /proc/<pid>/exe and the AppId, then walks the process tree.
# It always spares the calling script and its own parents.

# PPid comes from /proc/<pid>/status, not from field 4 of stat: a process name
# may contain spaces and parentheses, which shifts every field of that line.
ppid_of() { sed -n 's/^PPid:[[:space:]]*//p' "/proc/$1/status" 2>/dev/null; }

_steamvr_spared() {
    local p=$$
    while [[ -n "$p" && "$p" != 0 ]]; do
        echo "$p"; p=$(ppid_of "$p")
    done
}

_steamvr_seeds() {
    local d pid exe cl
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        exe=$(readlink -f "$d/exe" 2>/dev/null)
        case "$exe" in */SteamVR/bin/linux64/*) echo "$pid"; continue ;; esac
        # The process can exit between the glob and this read. The shell reports a
        # failed input redirection itself, so stderr must be closed around the
        # whole group: a trailing 2>/dev/null arrives too late to catch it.
        cl=$( { tr '\0' ' ' < "$d/cmdline"; } 2>/dev/null )
        case "$cl" in *"AppId=$STEAMVR_APPID"*) echo "$pid" ;; esac
    done
}

# Prints one "<pid> <name>" line per process of the SteamVR app and its children.
steamvr_tree() {
    local keep out n d pid ppid nm
    keep=" $(_steamvr_spared | tr '\n' ' ') "
    out=$(_steamvr_seeds | sort -un)
    while :; do
        n=$(for d in /proc/[0-9]*; do
                pid=${d#/proc/}
                ppid=$(ppid_of "$pid") || continue
                [[ -n "$ppid" ]] && grep -qx "$ppid" <<< "$out" && echo "$pid"
            done)
        n=$(printf '%s\n%s\n' "$out" "$n" | grep -v '^$' | sort -un)
        [[ "$n" == "$out" ]] && break
        out="$n"
    done
    for pid in $out; do
        [[ "$keep" == *" $pid "* ]] && continue
        [[ -r "/proc/$pid/stat" ]] || continue
        nm=$(basename "$(readlink -f "/proc/$pid/exe" 2>/dev/null)" 2>/dev/null)
        # pressure-vessel runs some helpers where /proc/<pid>/exe is unreadable
        # from outside its namespace; comm still names them.
        [[ -z "$nm" ]] && nm=$(cat "/proc/$pid/comm" 2>/dev/null)
        echo "$pid ${nm:-?}"
    done
}

# Closes every SteamVR process with SIGTERM, then SIGKILL for the rest. No prompt.
steamvr_stop() {
    local found left pid nm
    found=$(steamvr_tree)
    [[ -z "$found" ]] && { ok "No SteamVR process runs."; return 0; }

    while read -r pid nm; do kill -TERM "$pid" 2>/dev/null; done <<< "$found"
    for _ in $(seq 8); do [[ -z "$(steamvr_tree)" ]] && break; sleep 1; done

    left=$(steamvr_tree)
    if [[ -n "$left" ]]; then
        info "Some processes ignore SIGTERM. The script sends SIGKILL."
        while read -r pid nm; do kill -KILL "$pid" 2>/dev/null; done <<< "$left"
        sleep 2
    fi

    left=$(steamvr_tree)
    if [[ -z "$left" ]]; then
        ok "all SteamVR processes stopped"
    else
        bad "Some processes still run. Check them with ps."
        echo "$left" | while read -r pid nm; do info "$pid ${nm:-?}"; done
        return 1
    fi
}

# --- Headset session ------------------------------------------------------------
# SteamVR does not always start a new log file on startup: a run can append to the
# log of the previous one. So everything that reads a log here reads only the
# lines after the last startup marker of that log.
#   vrserver.txt        "vrserver <version> startup with PID=<pid>"
#   driver_vrlink.txt   a banner line that starts with "//====="
vrserver_run()      { awk '/vrserver .* startup with PID=/ {n = 0} {buf[++n] = $0} END {for (i = 1; i <= n; i++) print buf[i]}' "$STEAM_ROOT/logs/vrserver.txt" 2>/dev/null; }
driver_vrlink_run() { awk '/\[Info\] - \/\/=====/ {n = 0} {buf[++n] = $0} END {for (i = 1; i <= n; i++) print buf[i]}' "$STEAM_ROOT/logs/driver_vrlink.txt" 2>/dev/null; }

# Prints the PID that the current vrserver.txt run reports for itself.
vrserver_run_pid() { vrserver_run | sed -n 's/.*vrserver .* startup with PID=\([0-9]*\).*/\1/p' | head -1; }

# True when the vrserver of the current log run is alive. A quit can leave an
# orphan vrserver behind: steamvr_running then says yes, but that process holds
# the IPC socket and serves nothing.
steamvr_live() {
    local pid; pid=$(vrserver_run_pid)
    [[ -n "$pid" ]] || return 1
    [[ "$(readlink -f "/proc/$pid/exe" 2>/dev/null)" == */SteamVR/bin/linux64/vrserver ]]
}

# vr_session prints "<link> <hmd> <controllers>" for the current SteamVR run:
# link 1 while vrlink reports the connection active, hmd 1 while device 0 is
# out of standby, controllers the count of other devices that are active.
vr_session() {
    vrserver_run | awk -F' - ' '
        /vrlink: Connection active/   { link = 1 }
        /vrlink: Connection inactive/ { link = 0 }
        /Activating controller on TrackedDeviceIndex_t/ {
            n = $NF; sub(/.* /, "", n); up[n] = 1
        }
        $NF ~ /^(leaving|entering) standby$/ && $(NF-1) ~ /^[0-9]+$/ {
            up[$(NF-1)] = ($NF ~ /^leaving/)
        }
        END {
            c = 0
            for (d in up) if (d != 0 && up[d]) c++
            hmd = (0 in up) ? up[0] : link
            printf "%d %d %d\n", link, hmd, c
        }'
}

# --- WayVR ----------------------------------------------------------------------
# WayVR writes this file itself to keep a single instance.
WAYVR_PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/wayvr.pid"
WAYVR_STATE="$HOME/.config/wayvr/conf.d/zz-saved-state.json5"

# Prints the PID of the running WayVR. A stale file from a crash can hold a PID
# that a different process uses now, so the PID counts only if its binary is wayvr.
wayvr_pid() {
    local pid
    pid=$(cat "$WAYVR_PIDFILE" 2>/dev/null) || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ "$(readlink -f "/proc/$pid/exe" 2>/dev/null)" == */wayvr ]] || return 1
    echo "$pid"
}

# --- Dongle link ----------------------------------------------------------------
# True when the dongle is up and associated with the access point in the headset.
dongle_connected() {
    local d; d=$(dongle_iface)
    [[ -n "$d" ]] || return 1
    [[ "$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null | awk -F: -v d="$d" '$1==d {print $2}')" == connected ]]
}

# True when the running vrlink bound the dongle. vrlink logs one
# "SVLDataLinkTransferUDP::Init <addr> dev <iface>" line per interface at startup.
vrlink_uses_dongle() {
    local d; d=$(dongle_iface)
    [[ -n "$d" ]] || return 1
    driver_vrlink_run | grep -q "SVLDataLinkTransferUDP::Init .* dev $d "
}
