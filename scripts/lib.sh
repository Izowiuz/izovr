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
