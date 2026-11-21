#!/usr/bin/env bash
#
# mic-check.sh - say why a browser cannot hear the microphone, and fix the
# one cause that needs no settings changed.
#
# Walks the path a browser's microphone request takes, bottom up: a capture
# device the kernel exposes, a PulseAudio-protocol server (pipewire-pulse),
# a default source that is neither muted nor near silent, and - the step
# nothing else on the desktop checks - each Chromium audio service still
# connected to that server.
#
# That last step is why this script exists. Chrome, Chromium and every
# Electron app keep the sound-server connection in a separate audio-service
# process. When pipewire-pulse restarts, that process can be left holding
# nothing, and from then on every page in the browser gets "Requested
# device not found" (NotFoundError) for a microphone every other program
# records from. The browser shows no sign of it and does not recover by
# itself. Stopping the stale process is the whole fix: the browser starts a
# new one, connected, the next time a page asks for sound. --fix does
# exactly that and nothing else; volumes and default devices are reported,
# never changed.
#
# On success the default source's node name is printed on stdout, and
# everything else goes to stderr.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR/..

_self=${BASH_SOURCE[0]}
_self=$(readlink -f -- "$_self" 2>/dev/null || printf '%s' "$_self")
ROOT_DIR=$(cd -- "$(dirname -- "$_self")/.." && pwd -P)
# shellcheck source=lib/common.sh
. "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/audio.sh
. "$ROOT_DIR/lib/audio.sh"

VERSION=1.0.0
PROG=${0##*/}

FIX=0
# Below this the source is reported as too quiet. Speech recognition at
# arm's length from a laptop's built-in microphone wants more than the 0.35
# this host was found at; 0.5 is a warning, not a verdict.
MIN_VOLUME=${AUDIO_MIN_VOLUME:-0.5}

usage() {
    cat <<EOF
Usage: $PROG [options]

Check the path from the microphone to the browser, and print the default
capture source's name on stdout.

Options:
  -f, --fix       stop any browser audio service that lost the sound server;
                  the browser starts a fresh one when a page next asks for
                  sound (reload the page afterwards)
  -n, --dry-run   with --fix, print the kill instead of running it
  -q, --quiet     print only the source name, and warnings
  -h, --help      this help
  -V, --version   version

Exit codes:
  0 the path is whole                   2 bad usage
  1 a fault was found (and not fixed)   3 no capture device or source

Examples:
  $PROG                    # what is wrong, if anything
  $PROG --fix              # and repair a stale browser audio service
  $PROG -f -n              # show what --fix would stop
EOF
}

# shellcheck disable=SC2034  # QUIET and DRY_RUN are read by lib/common.sh
while (( $# )); do
    case $1 in
        -f|--fix)     FIX=1; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -q|--quiet)   QUIET=1; shift ;;
        -h|--help)    usage; exit "$EX_OK" ;;
        -V|--version) printf '%s %s\n' "$PROG" "$VERSION"; exit "$EX_OK" ;;
        --)           shift; break ;;
        *)            usage >&2; die -"$EX_USAGE" "unexpected argument: $1" ;;
    esac
done
(( $# == 0 )) || { usage >&2; die -"$EX_USAGE" "unexpected argument: $1"; }

FAULTS=0

# "1h 04m", "8m 12s", "40s" - an age a person can compare at a glance.
human_age() {
    local s=${1:-}
    [[ $s =~ ^[0-9]+$ ]] || { printf '?'; return; }
    if (( s >= 86400 )); then printf '%dd %02dh' $(( s / 86400 )) $(( s % 86400 / 3600 ))
    elif (( s >= 3600 )); then printf '%dh %02dm' $(( s / 3600 )) $(( s % 3600 / 60 ))
    elif (( s >= 60 )); then printf '%dm %02ds' $(( s / 60 )) $(( s % 60 ))
    else printf '%ds' "$s"
    fi
}

# ------------------------------------------------------------------ kernel
mapfile -t CAPTURE < <(audio_capture_devices)
if (( ${#CAPTURE[@]} == 0 )); then
    err "the kernel exposes no capture device ($AUDIO_PROC_ASOUND/pcm lists none)"
    info "  nothing above the kernel can record without one. On a laptop whose"
    info "  built-in microphone is a digital array, the sound card may need the"
    info "  SOF driver instead of snd_hda_intel; check: lspci -k | grep -A3 -i audio"
    exit "$EX_NODEV"
fi
for rec in "${CAPTURE[@]}"; do
    IFS=$DEVICES_FS read -r id name <<<"$rec"
    info "capture    $name (pcm $id)"
done

# ------------------------------------------------------------ sound server
SERVER_PID='' SERVER_AGE='' server_name=''
if rec=$(audio_pulse_server); then
    IFS=$DEVICES_FS read -r SERVER_PID server_name SERVER_AGE <<<"$rec"
    info "server     $server_name, pid $SERVER_PID, up $(human_age "$SERVER_AGE")"
    if [[ ! -S $AUDIO_PULSE_SOCKET ]]; then
        err "no PulseAudio socket at $AUDIO_PULSE_SOCKET"
        info "  browsers reach the microphone only through it"
        FAULTS=$(( FAULTS + 1 ))
    fi
else
    err "no PulseAudio-protocol server is running (looked for: $AUDIO_PULSE_SERVERS)"
    info "  browsers on Linux reach the microphone through it; with PipeWire:"
    info "  systemctl --user start pipewire-pulse.socket"
    FAULTS=$(( FAULTS + 1 ))
fi

# ----------------------------------------------------------- default source
SOURCE=''
if rec=$(audio_default_source); then
    IFS=$DEVICES_FS read -r SOURCE desc vol muted <<<"$rec"
    if [[ $muted == 1 ]]; then
        info "source     $desc, volume ${vol:-?}, MUTED"
    else
        info "source     $desc, volume ${vol:-?}"
    fi
    if [[ $muted == 1 ]]; then
        err "the default source is muted - every program records silence"
        info "  unmute: wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 0"
        FAULTS=$(( FAULTS + 1 ))
    elif [[ $vol =~ ^[0-9.]+$ ]] && awk -v v="$vol" -v m="$MIN_VOLUME" 'BEGIN { exit !(v < m) }'; then
        warn "the default source is at $vol - speech recognition may miss words"
        info "  raise it: wpctl set-volume @DEFAULT_AUDIO_SOURCE@ 0.8"
    fi
elif have wpctl; then
    err "there is no default capture source"
    info "  the kernel offers ${#CAPTURE[@]} capture device(s) but the sound server"
    info "  made none of them a source; see: wpctl status"
    exit "$EX_NODEV"
else
    warn "wpctl not found; the default source cannot be checked (install wireplumber)"
fi

# --------------------------------------------------------- browser services
mapfile -t SERVICES < <(audio_services)
if (( ${#SERVICES[@]} == 0 )); then
    info "browsers   no audio service running - a browser starts one when a page asks for sound"
fi
STALE=()
for rec in "${SERVICES[@]}"; do
    IFS=$DEVICES_FS read -r pid prog age <<<"$rec"
    rc=0
    audio_service_connected "$pid" || rc=$?
    older=0
    if [[ $age =~ ^[0-9]+$ && $SERVER_AGE =~ ^[0-9]+$ ]] && (( age > SERVER_AGE )); then
        older=1
    fi
    case $rc in
        0)  info "browser    $prog audio service, pid $pid, up $(human_age "$age"): connected" ;;
        1)  STALE+=("$pid")
            err "$prog audio service, pid $pid, holds no connection to the sound server"
            if (( older )); then
                info "  it started $(human_age $(( age - SERVER_AGE ))) before $server_name last restarted"
                info "  and never reconnected"
            fi
            info "  every page in $prog sees no microphone and no loudspeaker"
            info "  (getUserMedia: NotFoundError, \"Requested device not found\")" ;;
        *)  if (( older )); then
                STALE+=("$pid")
                warn "$prog audio service, pid $pid, started before $server_name last restarted;"
                info "  its connection cannot be checked without ss (iproute2), so it is"
                info "  treated as stale"
            else
                info "browser    $prog audio service, pid $pid, up $(human_age "$age") (connection not checked: no ss)"
            fi ;;
    esac
done

if (( ${#STALE[@]} )); then
    if (( FIX )); then
        for pid in "${STALE[@]}"; do
            run kill -- "$pid"
            ok "$(verb stop stopped) audio service $pid"
        done
        info "  the browser starts a new one when a page next asks for sound: reload it"
    else
        FAULTS=$(( FAULTS + ${#STALE[@]} ))
        info "  fix: $PROG --fix   (stops only the stale audio service; the browser"
        info "       starts a fresh one, connected, and your tabs stay open)"
    fi
fi

(( FAULTS == 0 )) || exit "$EX_FAIL"
[[ -n $SOURCE ]] && printf '%s\n' "$SOURCE"
exit "$EX_OK"
