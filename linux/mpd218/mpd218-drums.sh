#!/usr/bin/env bash
#
# mpd218-drums.sh - put a classic drum kit on the AKAI MPD218's pads.
#
# The presets this unit carries are no use for drumming: the VirtualDJ ones
# send bank A on notes 0-15, and the chroma10 one is chromatic over notes
# 36-83, which walks through the General MIDI percussion map in numerical
# order rather than musical order - kick, side stick, snare, clap, snare,
# tom... Playable, but nothing lands where a drummer's hands expect it.
#
# This builds a preset that does: the kit laid out as a drum machine, groove
# row at the bottom, and writes it to the device. Everything is on MIDI
# channel 10, which General MIDI reserves for percussion, so any GM synth
# (FluidSynth with the stock SoundFont included) plays it as a kit with no
# program change needed.
#
# A preset is generated here rather than edited through mpd-utils because the
# upstream pad editor is interactive - 48 pads of qprompt answers - and this
# layout should be reproducible. The 549-byte dump format is simple enough to
# emit directly, and is the same structure mpd218.py parses:
#
#   0x00  F0 47 00 34 10 04 1D   SysEx header, Akai, MPD218, load preset, len
#   0x07  preset slot 0x01..0x10
#   0x08  name, 8 ASCII bytes, space padded
#   0x10  tempo, 14 bits 7-bit stuffed across two bytes
#   0x12  note-repeat division, then swing
#   0x14  48 pads x 8 bytes: type, channel, note, trigger, aftertouch,
#         program, bank MSB, bank LSB   (banks A, B, C in order)
#   0x194 18 dials x 8 bytes: type, channel, CC, min, max, MSB, LSB, value
#   0x224 F7
#
# Every byte must be <= 0x7F or it is not legal SysEx, which the whole GM
# percussion range (35-81) satisfies comfortably.
#
# Pad 1 is bottom-left, counting up in rows, as on an MPC. The device cannot be
# asked which pad is which, so that began as an assumption; it is measured on
# this unit. Playing the pads under aseqdump returned all sixteen bank A notes
# exactly as laid out below, on channel 10. A unit that disagrees puts the kit
# upside down, which is the first thing to check:
#
#   aseqdump -p "$(./mpd218-config.sh seq)"     # hit the bottom-left pad,
#                                               # expect note 36 on channel 9
#                                               # (aseqdump counts from 0)
#
# On success the preset slot is printed on stdout; everything else goes to
# stderr.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR/..

_self=${BASH_SOURCE[0]}
_self=$(readlink -f -- "$_self" 2>/dev/null || printf '%s' "$_self")
ROOT_DIR=$(cd -- "$(dirname -- "$_self")/.." && pwd -P)
# shellcheck source=lib/common.sh
. "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/mpd218.sh
. "$ROOT_DIR/lib/mpd218.sh"

VERSION=1.0.0
PROG=${0##*/}

SLOT=${MPD218_DRUMS_SLOT:-1}
TEMPO=${MPD218_DRUMS_TEMPO:-90}
OUTFILE_DEFAULT=classic-drums.mpd218

# Eight ASCII bytes, space padded. The MPD218 has no display, so this is only
# ever seen in an editor or a dump.
KIT_NAME=CLASSIC

# General MIDI reserves channel 10 for percussion. The device stores the
# channel one-based, which is why a dump says 10 where aseqdump says 9.
PAD_CHANNEL=10

# Note repeat: 1/16 at no swing. These only affect the device's own repeat
# and roll, never the notes the pads send.
DIVISION_1_16=4
SWING_OFF=50

# Pad entries are "<note> <name>", in pad order, pad 1 first.
#
# Bank A is the kit: the groove on the bottom row under your fingers,
# accents above it, toms rising left to right, cymbals on top.
KIT_A=(
    "36 Bass Drum"
    "38 Snare"
    "42 Closed Hat"
    "46 Open Hat"
    "37 Side Stick"
    "39 Hand Clap"
    "44 Pedal Hat"
    "54 Tambourine"
    "41 Low Floor Tom"
    "45 Low Tom"
    "47 Mid Tom"
    "50 High Tom"
    "49 Crash 1"
    "51 Ride 1"
    "53 Ride Bell"
    "56 Cowbell"
)

# Bank B is the second kit voices and the hand percussion.
KIT_B=(
    "35 Acoustic Kick"
    "40 Electric Snare"
    "43 High Floor Tom"
    "48 Hi-Mid Tom"
    "52 Chinese Cymbal"
    "55 Splash Cymbal"
    "57 Crash 2"
    "59 Ride 2"
    "60 Hi Bongo"
    "61 Low Bongo"
    "62 Mute Hi Conga"
    "63 Open Hi Conga"
    "64 Low Conga"
    "65 High Timbale"
    "66 Low Timbale"
    "58 Vibraslap"
)

# Bank C is the rest of the GM percussion map. Banks A and B together cover
# notes 35-66 exactly, so C holds 67-81 and the three banks between them
# reach every one of the 47 GM percussion sounds, with one pad left over -
# spent on another kick, so a beat is always within reach.
KIT_C=(
    "67 High Agogo"
    "68 Low Agogo"
    "69 Cabasa"
    "70 Maracas"
    "71 Short Whistle"
    "72 Long Whistle"
    "73 Short Guiro"
    "74 Long Guiro"
    "75 Claves"
    "76 Hi Wood Block"
    "77 Low Wood Block"
    "78 Mute Cuica"
    "79 Open Cuica"
    "80 Mute Triangle"
    "81 Open Triangle"
    "36 Bass Drum"
)

# Dial entries are "<CC> <name>", dial 1 first. Bank 1 is what a GM synth
# actually responds to while a kit is playing; bank 3 is left free because
# GM assigns nothing to CC 20-25, so a DAW can take them.
DIALS_A=(
    "7 Volume"
    "10 Pan"
    "91 Reverb"
    "93 Chorus"
    "74 Cutoff"
    "71 Resonance"
)
DIALS_B=(
    "73 Attack"
    "72 Release"
    "75 Decay"
    "76 Vibrato Rate"
    "77 Vibrato Depth"
    "11 Expression"
)
DIALS_C=(
    "20 Free 1"
    "21 Free 2"
    "22 Free 3"
    "23 Free 4"
    "24 Free 5"
    "25 Free 6"
)

usage() {
    cat >&2 <<EOF
Usage: $PROG [options] <command>

Puts a classic drum-machine kit on the pads: General MIDI percussion on
channel 10, kick and snare and hats on the bottom row.

Commands:
  map                      print the pad layout and change nothing
  build [outfile]          write the preset to a file (default: $OUTFILE_DEFAULT)
  apply                    send the preset to the device
  play                     send the preset, then start the synth

Options:
  -p, --preset N           preset slot to build for, 1-16 (default: $SLOT)
  -t, --tempo N            note-repeat tempo, 30-300 (default: $TEMPO)
  -n, --dry-run            print what would be done, change nothing
  -q, --quiet              suppress progress output
  -h, --help               this help
  -V, --version            version

Environment:
  MPD218_DRUMS_SLOT        default preset slot
  MPD218_DRUMS_TEMPO       default note-repeat tempo

Examples:
  $PROG map
  $PROG apply                       # into preset 1
  $PROG -p 2 apply                  # keep preset 1, use preset 2
  $PROG play                        # apply, then FluidSynth

apply overwrites the preset in that slot on the device, and the slot cannot
be read back afterwards. Keep what is there first with:

  ./mpd218-config.sh read N old.mpd218
EOF
}

# All 48 pads and all 18 dials, in the order the dump stores them.
pad_entries()  { printf '%s\n' "${KIT_A[@]}" "${KIT_B[@]}" "${KIT_C[@]}"; }
dial_entries() { printf '%s\n' "${DIALS_A[@]}" "${DIALS_B[@]}" "${DIALS_C[@]}"; }

# Both tables are "<number> <name>": a note for a pad, a CC for a dial.
num_of()   { printf '%s' "${1%% *}"; }
label_of() { printf '%s' "${1#* }"; }

# Emit the 549-byte preset. Bytes are collected as numbers and written in one
# pass, because a NUL cannot travel through a bash string but a "\x00" can.
write_preset() {
    local slot=$1 out=$2
    local -a bytes=()
    local entry padded esc i byte raw

    bytes+=( 0xF0 0x47 0x00 0x34 0x10 0x04 0x1D )
    bytes+=( "$slot" )

    printf -v padded '%-8.8s' "$KIT_NAME"
    for (( i = 0; i < 8; i++ )); do
        printf -v byte '%d' "'${padded:i:1}"
        bytes+=( "$byte" )
    done

    # 14-bit tempo stuffed into two 7-bit bytes.
    raw=$(( (TEMPO & 0x7F) | ((TEMPO & 0x3F80) << 1) ))
    bytes+=( $(( (raw >> 8) & 0x7F )) $(( raw & 0x7F )) )
    bytes+=( "$DIVISION_1_16" "$SWING_OFF" )

    # type NOTE, channel, note, trigger MOMENTARY, aftertouch OFF, then the
    # program and bank bytes the NOTE type does not use. Aftertouch is off
    # because a GM kit ignores channel pressure and a leaned-on pad would
    # otherwise flood the port with it.
    while IFS= read -r entry; do
        bytes+=( 0x00 "$PAD_CHANNEL" "$(num_of "$entry")" 0x00 0x00 0x00 0x00 0x00 )
    done < <(pad_entries)

    # type CC, channel, CC number, min 0, max 127, then the unused bank bytes.
    while IFS= read -r entry; do
        bytes+=( 0x00 "$PAD_CHANNEL" "$(num_of "$entry")" 0x00 0x7F 0x00 0x00 0x00 )
    done < <(dial_entries)

    bytes+=( 0xF7 )

    (( ${#bytes[@]} == MPD218_PRESET_BYTES )) || die \
        "built ${#bytes[@]} bytes, expected $MPD218_PRESET_BYTES (this is a bug)"

    printf -v esc '\\x%02x' "${bytes[@]}"
    printf '%b' "$esc" > "$out"
}

check_slot() {
    mpd218_preset_hex "$SLOT" >/dev/null \
        || die -"$EX_USAGE" "--preset must be $MPD218_PRESET_MIN-$MPD218_PRESET_MAX, got '$SLOT'"
}

# Same diagnostics as the other MPD218 scripts: "not plugged in" and "plugged
# in but ALSA never claimed it" are different problems.
resolve_port() {
    local port
    if ! port=$(mpd218_midi_port); then
        if mpd218_usb_present; then
            die -"$EX_NODEV" "MPD218 is on USB but ALSA exposes no MIDI port for it"
        fi
        die -"$EX_NODEV" "no MPD218 found (is it plugged in?)"
    fi
    printf '%s' "$port"
}

# Rows top down, as the pads sit under your hands.
cmd_map() {
    local -a kit
    local bank label row col idx entry
    printf 'Classic kit - preset %d, MIDI channel %d, GM percussion\n' \
        "$SLOT" "$PAD_CHANNEL"
    for bank in A B C; do
        case $bank in
            A) kit=( "${KIT_A[@]}" ); label='the kit' ;;
            B) kit=( "${KIT_B[@]}" ); label='second voices and hand percussion' ;;
            C) kit=( "${KIT_C[@]}" ); label='the rest of the GM percussion map' ;;
        esac
        printf '\nBank %s - %s\n' "$bank" "$label"
        for (( row = 3; row >= 0; row-- )); do
            for (( col = 0; col < 4; col++ )); do
                idx=$(( row * 4 + col ))
                entry=${kit[idx]}
                printf '  %2d %3d %-17s' \
                    "$(( idx + 1 ))" "$(num_of "$entry")" "$(label_of "$entry")"
            done
            printf '\n'
        done
    done
    printf '\nDials\n'
    for (( col = 0; col < 6; col++ )); do
        printf '  %d  %-19s %-19s %s\n' "$(( col + 1 ))" \
            "CC $(num_of "${DIALS_A[col]}") $(label_of "${DIALS_A[col]}")" \
            "CC $(num_of "${DIALS_B[col]}") $(label_of "${DIALS_B[col]}")" \
            "CC $(num_of "${DIALS_C[col]}") $(label_of "${DIALS_C[col]}")"
    done
}

cmd_build() {
    local out=${1:-$OUTFILE_DEFAULT}
    check_slot
    info "building the classic kit for preset $SLOT at tempo $TEMPO"
    if (( DRY_RUN )); then
        printf '%swould write:%s %s bytes to %s\n' \
            "$C_DIM" "$C_RESET" "$MPD218_PRESET_BYTES" "$out" >&2
    else
        write_preset "$SLOT" "$out"
        ok "wrote $out ($MPD218_PRESET_BYTES bytes)"
    fi
    printf '%s\n' "$out"
}

cmd_apply() {
    local port work file
    check_slot
    have amidi || die -"$EX_FAIL" "amidi not found; install alsa-utils"
    port=$(resolve_port)

    info "sending the classic kit to preset $SLOT on $port"
    warn "preset $SLOT on the device is being replaced; it cannot be read back afterwards"

    if (( DRY_RUN )); then
        run amidi -p "$port" -s "$OUTFILE_DEFAULT"
    else
        work=$(mktemp -d "${TMPDIR:-/tmp}/mpd218-drums.XXXXXX")
        # shellcheck disable=SC2064  # expand $work now, not at trap time
        trap "rm -rf -- '$work'" RETURN
        file=$work/$OUTFILE_DEFAULT
        write_preset "$SLOT" "$file"
        run amidi -p "$port" -s "$file"
    fi

    ok "$(verb apply applied) the classic kit to preset $SLOT"
    info "select preset $SLOT on the device (PRESET, then the pad for $SLOT);"
    info "writing to the slot already selected takes effect at once."
    printf '%s\n' "$SLOT"
}

# The synth replaces this process, so it must be the last thing done.
cmd_play() {
    local synth=$ROOT_DIR/mpd218/mpd218-synth.sh
    [[ -x $synth ]] || die "not executable: $synth"
    cmd_apply >/dev/null
    info "starting the synth; the kit is already in range, so nothing is transposed"
    if (( DRY_RUN )); then
        run "$synth" -n
        return 0
    fi
    exec "$synth"
}

while (( $# )); do
    case $1 in
        -p|--preset)  SLOT=${2:?--preset needs a slot}; shift 2 ;;
        -t|--tempo)   TEMPO=${2:?--tempo needs a value}; shift 2 ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -q|--quiet)   QUIET=1; shift ;;
        -h|--help)    usage; exit "$EX_OK" ;;
        -V|--version) printf '%s %s\n' "$PROG" "$VERSION"; exit "$EX_OK" ;;
        --)           shift; break ;;
        -*)           usage; die -"$EX_USAGE" "unknown option: $1" ;;
        *)            break ;;
    esac
done

if [[ ! $TEMPO =~ ^[0-9]+$ ]] || (( TEMPO < 30 || TEMPO > 300 )); then
    die -"$EX_USAGE" "--tempo needs an integer 30-300, got '$TEMPO'"
fi

(( $# )) || { usage; exit "$EX_USAGE"; }

command=$1; shift
case $command in
    map)   cmd_map "$@" ;;
    build) cmd_build "$@" ;;
    apply) cmd_apply "$@" ;;
    play)  cmd_play "$@" ;;
    *)     usage; die -"$EX_USAGE" "unknown command: $command" ;;
esac
