#!/usr/bin/env bash
#
# mpd218-synth.sh - make the MPD218 audible by routing it into FluidSynth.
#
# The MPD218 has no sound engine: it only emits MIDI. Nothing is heard until
# something is listening, which is what this script arranges.
#
# It can also work around the note range, which differs per preset on this
# unit. The VirtualDJ presets send bank A on notes 0-15 (C-1 to D#0), below
# most instrument ranges and at the bottom edge of hearing, so those pads are
# effectively silent even once a synth is connected; the chroma10 preset sends
# notes 36-51 on channel 10 and is audible as a GM drum kit as it is. The
# device gives no way to ask which preset is selected - sysex index 0x00 is not
# "current preset" on the MPD218 - so nothing is transposed by default and
# --transpose is there for when the pads turn out to be silent.
#
# FluidSynth is left in the foreground deliberately. Given -i (no shell) and no
# MIDI file it has nothing to do and exits at once, so it is its own command
# shell that keeps it alive; Ctrl-C there stops it and drops the connection.
# Because the synth is exec'd, the ALSA connection is made by a helper forked
# beforehand, which waits for the synth's sequencer port to appear.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR/..

_self=${BASH_SOURCE[0]}
_self=$(readlink -f -- "$_self" 2>/dev/null || printf '%s' "$_self")
ROOT_DIR=$(cd -- "$(dirname -- "$_self")/.." && pwd -P)
# shellcheck source=lib/common.sh
. "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/mpd218.sh
. "$ROOT_DIR/lib/mpd218.sh"

VERSION=1.2.0
PROG=${0##*/}

# Faithful by default: the selected preset cannot be read back, so guessing a
# shift would break the presets that are already in range.
TRANSPOSE=${MPD218_TRANSPOSE:-0}
GAIN=${MPD218_GAIN:-0.8}
SOUNDFONT=${MPD218_SOUNDFONT:-}
AUDIO_DRIVER=${MPD218_AUDIO_DRIVER:-}

# PipeWire runs the audio on this host and FluidSynth 2.4 links libpipewire,
# so the native driver is the default rather than going through the Pulse shim.
# There is deliberately no pre-flight probe and no fallback list: FluidSynth
# announces each driver differently ("Using PipeWire audio driver", "Using
# PulseAudio driver") and the ALSA driver announces nothing at all while still
# working, so there is no string that reliably means success. If there is no
# sound, --audio switches driver and FluidSynth reports its own failure more
# clearly than a guess here could.
AUDIO_DRIVER_DEFAULT=pipewire

SOUNDFONT_CANDIDATES=(
    /usr/share/sounds/sf2/default-GM.sf2
    /usr/share/sounds/sf2/FluidR3_GM.sf2
    /usr/share/sounds/sf2/TimGM6mb.sf2
    /usr/share/soundfonts/default.sf2
)

usage() {
    cat >&2 <<EOF
Usage: $PROG [options]

Starts FluidSynth and connects the MPD218 to it. Runs until Ctrl-C.

Options:
  -t, --transpose N    shift incoming notes by N semitones (default: $TRANSPOSE)
  -s, --soundfont F    SoundFont to load (default: first one found)
  -a, --audio DRIVER   FluidSynth audio driver (default: $AUDIO_DRIVER_DEFAULT;
                       try pulseaudio or alsa if there is no sound)
  -g, --gain G         output gain, 0.0-10.0 (default: $GAIN)
  -n, --dry-run        print what would be done, change nothing
  -q, --quiet          suppress progress output
  -h, --help           this help
  -V, --version        version

When to use --transpose:
  Nothing is shifted by default, because which preset is selected cannot be
  read back from the device. The chroma10 preset (notes 36-51, channel 10) is
  audible as a GM drum kit as it is. The VirtualDJ presets put bank A on notes
  0-15, which is inaudible -- pass --transpose 36 for those, which moves bank
  A to C2..D#3.

Environment:
  MPD218_TRANSPOSE, MPD218_GAIN, MPD218_SOUNDFONT, MPD218_AUDIO_DRIVER
EOF
}

find_soundfont() {
    local f
    if [[ -n $SOUNDFONT ]]; then
        [[ -r $SOUNDFONT ]] || die -"$EX_NODEV" "cannot read SoundFont: $SOUNDFONT"
        printf '%s' "$SOUNDFONT"
        return 0
    fi
    for f in "${SOUNDFONT_CANDIDATES[@]}"; do
        [[ -r $f ]] && { printf '%s' "$f"; return 0; }
    done
    die -"$EX_NODEV" \
        "no SoundFont found; install one (apt install fluid-soundfont-gm) or pass --soundfont"
}

# FluidSynth's router replaces its default rules wholesale, so every event
# class that should still pass has to be restated.
write_router() {
    local out=$1
    if (( TRANSPOSE == 0 )); then
        printf 'router_default\n' > "$out"
        return 0
    fi
    cat > "$out" <<EOF
router_clear
router_begin note
router_par1 0 127 1.0 $TRANSPOSE
router_end
router_begin cc
router_end
router_begin pbend
router_end
router_begin prog
router_end
EOF
}

# The synth's own sequencer client, which only exists once it has started.
fluid_seq_port() {
    local line client
    while IFS= read -r line; do
        [[ $line == client\ * ]] || continue
        case ${line,,} in *fluid*) ;; *) continue ;; esac
        client=${line#client }; client=${client%%:*}
        printf '%s:0\n' "$client"
        return 0
    done < <(aconnect -l 2>/dev/null)
    return 1
}

# Forked before the synth is exec'd: waits for its port, connects the
# controller to it, then clears away the router file the synth has read.
connect_when_ready() {
    local seq_port=$1 work=$2 i fluid=''
    for (( i = 0; i < 50; i++ )); do
        if fluid=$(fluid_seq_port); then break; fi
        sleep 0.2
    done
    if [[ -z $fluid ]]; then
        err "fluidsynth exposed no sequencer port; controller not connected"
        rm -rf -- "$work"
        return 1
    fi
    if run aconnect "$seq_port" "$fluid"; then
        ok "connected $seq_port -> $fluid"
        info "hit the pads. Ctrl-C to stop."
    else
        err "could not connect $seq_port to $fluid"
    fi
    rm -rf -- "$work"
}

main() {
    # Optional like every other external tool here: a dry run should still be
    # able to show the plan on a host where the synth is not installed yet.
    if ! have fluidsynth; then
        (( DRY_RUN )) || die -"$EX_FAIL" \
            "fluidsynth not found; install it with: sudo apt install fluidsynth"
        warn "fluidsynth not installed; install with: sudo apt install fluidsynth"
    fi
    have aconnect || die -"$EX_FAIL" "aconnect not found; install alsa-utils"

    local sf seq_port driver work router
    sf=$(find_soundfont)
    seq_port=$(mpd218_seq_port) || {
        if mpd218_usb_present; then
            die -"$EX_NODEV" "MPD218 is on USB but ALSA exposes no sequencer port for it"
        fi
        die -"$EX_NODEV" "no MPD218 found (is it plugged in?)"
    }

    if (( DRY_RUN )); then
        driver=${AUDIO_DRIVER:-$AUDIO_DRIVER_DEFAULT}
        info "device    $seq_port"
        info "soundfont $sf"
        info "transpose $TRANSPOSE semitones"
        run fluidsynth -a "$driver" -m alsa_seq -g "$GAIN" "$sf"
        run aconnect "$seq_port" '<fluidsynth>:0'
        return 0
    fi

    driver=${AUDIO_DRIVER:-$AUDIO_DRIVER_DEFAULT}

    work=$(mktemp -d "${TMPDIR:-/tmp}/mpd218-synth.XXXXXX")
    router=$work/router.txt
    write_router "$router"

    info "device    $seq_port"
    info "soundfont $sf"
    info "transpose $TRANSPOSE semitones"
    info "audio     $driver"

    connect_when_ready "$seq_port" "$work" &

    # Replaces this shell, so Ctrl-C reaches the synth directly. No -i: with
    # no shell and no MIDI file FluidSynth would exit immediately.
    debug "fluidsynth -a $driver -m alsa_seq -g $GAIN -f $router $sf"
    exec fluidsynth -a "$driver" -m alsa_seq -g "$GAIN" -f "$router" "$sf"
}

while (( $# )); do
    case $1 in
        -t|--transpose) TRANSPOSE=${2:?--transpose needs a value}; shift 2 ;;
        -s|--soundfont) SOUNDFONT=${2:?--soundfont needs a path}; shift 2 ;;
        -a|--audio)     AUDIO_DRIVER=${2:?--audio needs a driver}; shift 2 ;;
        -g|--gain)      GAIN=${2:?--gain needs a value}; shift 2 ;;
        -n|--dry-run)   DRY_RUN=1; shift ;;
        -q|--quiet)     QUIET=1; shift ;;
        -h|--help)      usage; exit "$EX_OK" ;;
        -V|--version)   printf '%s %s\n' "$PROG" "$VERSION"; exit "$EX_OK" ;;
        --)             shift; break ;;
        *)              usage; die -"$EX_USAGE" "unknown option: $1" ;;
    esac
done

[[ $TRANSPOSE =~ ^-?[0-9]+$ ]] || die -"$EX_USAGE" "--transpose needs an integer, got '$TRANSPOSE'"

main
