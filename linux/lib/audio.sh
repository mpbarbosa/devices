#!/usr/bin/env bash
# Microphone and sound-server detection for the devices script suite.
# Source this file after common.sh, do not execute it.
#
#   . "$ROOT_DIR/lib/common.sh"
#   . "$ROOT_DIR/lib/audio.sh"
#
# Pure detection: every helper here reads and prints, none of them changes
# a volume, a default device or a process. Records are joined by
# $DEVICES_FS, as everywhere in this suite.
#
# The one fact this library exists for: a Chromium-based program (Chrome,
# Chromium, every Electron app) does not talk to the sound server from the
# browser process. It runs a separate "audio service" utility process, and
# that process holds the PulseAudio connection. When the sound server
# restarts, the audio service can be left holding nothing - and from then
# on every page in that browser sees no microphone and no loudspeaker at
# all, getUserMedia fails with NotFoundError ("Requested device not
# found"), while every other program on the host records fine. Nothing in
# the browser's own UI says so. See audio_service_connected.

# shellcheck shell=bash

[[ -n ${_DEVICES_AUDIO_SOURCED:-} ]] && return 0
_DEVICES_AUDIO_SOURCED=1

# Seams, so each probe can be pointed at a fixture.
AUDIO_PROC_ASOUND=${AUDIO_PROC_ASOUND:-/proc/asound}
AUDIO_PULSE_SOCKET=${AUDIO_PULSE_SOCKET:-${XDG_RUNTIME_DIR:-/run/user/${UID}}/pulse/native}
# The argument that marks a Chromium audio service. The browser passes it,
# whole, to the utility process it spawns, whatever the product. It is
# matched as one complete argument, never as a substring - see
# audio_services for the process that a substring match once killed.
AUDIO_SERVICE_ARG=${AUDIO_SERVICE_ARG:---utility-sub-type=audio.mojom.AudioService}
# The sound servers that speak the PulseAudio protocol, in preference order.
AUDIO_PULSE_SERVERS=${AUDIO_PULSE_SERVERS:-pipewire-pulse pulseaudio}

# ALSA capture devices the kernel exposes, one record each:
#   id  name
# Read from /proc/asound/pcm, whose lines look like
#   00-00: ALC3204 Analog : ALC3204 Analog : playback 1 : capture 1
# and carry "capture N" only for a device that can record. An empty result
# means the kernel never offered the sound server anything to record from,
# which no setting above the kernel can fix.
audio_capture_devices() {
    local pcm=$AUDIO_PROC_ASOUND/pcm line id name
    [[ -r $pcm ]] || return 0
    while IFS= read -r line; do
        [[ $line == *": capture "* ]] || continue
        id=${line%%:*}
        name=${line#*: }
        name=${name%% : *}
        printf '%s%s%s\n' "$id" "$DEVICES_FS" "$name"
    done < "$pcm"
}

# The PulseAudio-protocol server, as one record:
#   pid  name  age-in-seconds
# Returns 1 when none is running. PipeWire serves the protocol through
# pipewire-pulse; on a host still running PulseAudio itself the process is
# pulseaudio. Browsers on Linux reach the microphone only through this.
audio_pulse_server() {
    local name pid age
    for name in $AUDIO_PULSE_SERVERS; do
        pid=$(pgrep -u "$UID" -x -- "$name" 2>/dev/null | head -n 1) || true
        [[ -n $pid ]] || continue
        age=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ') || true
        printf '%s%s%s%s%s\n' "$pid" "$DEVICES_FS" "$name" "$DEVICES_FS" "${age:-}"
        return 0
    done
    return 1
}

# The default capture source, as one record:
#   node-name  description  volume  muted(0|1)
# Asked of WirePlumber through wpctl. Returns 1 when wpctl is absent or
# there is no default source - the second is what a host with no working
# microphone looks like from above the kernel.
audio_default_source() {
    have wpctl || return 1
    local inspect vol name desc muted=0
    inspect=$(wpctl inspect @DEFAULT_AUDIO_SOURCE@ 2>/dev/null) || return 1
    name=$(sed -n 's/^[[:space:]]*\*\{0,1\}[[:space:]]*node\.name = "\(.*\)"$/\1/p' <<<"$inspect" | head -n 1)
    desc=$(sed -n 's/^[[:space:]]*\*\{0,1\}[[:space:]]*node\.description = "\(.*\)"$/\1/p' <<<"$inspect" | head -n 1)
    [[ -n $name ]] || return 1
    # "Volume: 0.80" or "Volume: 0.80 [MUTED]"
    vol=$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null) || vol=''
    [[ $vol == *MUTED* ]] && muted=1
    vol=${vol#Volume: }
    vol=${vol%% *}
    printf '%s%s%s%s%s%s%s\n' "$name" "$DEVICES_FS" "${desc:-$name}" "$DEVICES_FS" \
        "$vol" "$DEVICES_FS" "$muted"
}

# Chromium audio services belonging to this user, one record each:
#   pid  program  age-in-seconds
# The program is the executable's name (chrome for both Google Chrome and
# the Chromium snap, the app's own name for an Electron app), which is what
# tells the user which window to reload. A browser starts its audio service
# only when something asks for sound and may let an idle one exit, so none
# running is a normal state, not a fault.
#
# pgrep -f is only the first sieve: it matches anywhere in the joined
# command line, so it also catches any shell whose script merely mentions
# the marker - a terminal that just ran `pkill -f '...AudioService'`, or
# the shell running this suite's own test. An early version filtered on
# substrings, and its --fix killed exactly such a shell. So each candidate
# must carry --type=utility and the marker as two whole arguments of its
# own, which a shell's `-c` script, being one argument, never does.
audio_services() {
    local pid prog age arg is_utility is_audio
    while read -r pid; do
        [[ -n $pid ]] || continue
        [[ -r /proc/$pid/cmdline ]] || continue
        is_utility=0 is_audio=0
        # NUL-separated, one argument per field. `read -d ''` rather than
        # `mapfile -d ''`, which needs bash 4.4; the floor here is 4.2.
        while IFS= read -r -d '' arg; do
            [[ $arg == --type=utility ]] && is_utility=1
            [[ $arg == "$AUDIO_SERVICE_ARG" ]] && is_audio=1
        done < "/proc/$pid/cmdline" 2>/dev/null || true
        (( is_utility && is_audio )) || continue
        prog=$(cat "/proc/$pid/comm" 2>/dev/null) || prog='?'
        age=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ') || age=''
        printf '%s%s%s%s%s\n' "$pid" "$DEVICES_FS" "$prog" "$DEVICES_FS" "$age"
    done < <(pgrep -u "$UID" -f -- "$AUDIO_SERVICE_ARG" 2>/dev/null)
}

# Pids of this user's processes connected to the PulseAudio socket, one per
# line. Two passes over `ss -xp`: the server side of each connection is the
# line whose local address is the socket path, and its peer inode is the
# local inode of the client's line, which carries the client's pid. Needs
# ss (iproute2); returns 2 when it is absent, so the caller can tell
# "nobody is connected" from "could not look".
audio_pulse_clients() {
    have ss || return 2
    ss -xpH 2>/dev/null | awk -v sock="$AUDIO_PULSE_SOCKET" '
        { line[NR] = $0; local_ino[NR] = $6 }
        $5 == sock { want[$8] = 1 }
        END {
            for (n = 1; n <= NR; n++) {
                if (!(local_ino[n] in want)) continue
                rest = line[n]
                while (match(rest, /pid=[0-9]+/)) {
                    print substr(rest, RSTART + 4, RLENGTH - 4)
                    rest = substr(rest, RSTART + RLENGTH)
                }
            }
        }' | sort -un
}

# True when the given pid holds a connection to the PulseAudio socket.
# Returns 2 when that cannot be determined (no ss).
#
# Measured on this host: a healthy Chrome audio service holds one such
# connection for as long as it runs, from the moment it starts, whether or
# not a page is using sound. The one found broken - "Requested device not
# found" on every page - held none, and had started eight minutes before
# pipewire-pulse last restarted.
audio_service_connected() {
    local want=$1 clients rc=0
    clients=$(audio_pulse_clients) || rc=$?
    (( rc == 2 )) && return 2
    grep -qx -- "$want" <<<"$clients"
}
