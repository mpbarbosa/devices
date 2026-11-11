#!/usr/bin/env bash
#
# mpd218-config.sh - read, edit and write AKAI MPD218 presets.
#
# A thin front end to mungewell/mpd-utils (GPL-2.0), which does the actual
# SysEx parsing. That clone lives outside this repo because it carries its
# own git history and a machine-specific venv; point MPD_UTILS_DIR at it.
#
# The MPD218 holds 16 presets, addressed 0x01..0x10. Reading one back is
# where the upstream instructions go wrong on Linux: the ALSA port hands
# over whatever performance MIDI it had buffered the first time it is
# opened, and a bare `amidi -r` prepends that to the reply, silently
# producing an oversized and unparseable dump. So the port is drained
# first and the reply is then located by its F0 47 00 34 header.
#
# On success the resulting path is printed on stdout; everything else goes
# to stderr, so this is safe to use as:  f=$(mpd218-config.sh -q read 1)

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

MPD_UTILS_DIR=${MPD_UTILS_DIR:-$HOME/Documents/GitHub/mpd-utils}
BACKUP_DIR=${MPD218_BACKUP_DIR:-$ROOT_DIR/mpd218/backup-$(date +%F)}

usage() {
    cat >&2 <<EOF
Usage: $PROG [options] <command> [args]

Commands:
  port                     print the detected raw ALSA port (for amidi)
  seq                      print the detected sequencer address (for aconnect)
  read <1-16> [outfile]    read one preset off the device
  backup [dir]             read all 16 presets into dir
  write <file>             send a preset file to the device
  dump <file>              print a preset as text
  edit <mpd218.py args>    pass arguments straight through to mpd218.py

Options:
  -n, --dry-run            print what would be done, change nothing
  -q, --quiet              suppress progress output
  -h, --help               this help
  -V, --version            version

Environment:
  MPD_UTILS_DIR            mpd-utils clone (default: ~/Documents/GitHub/mpd-utils)
  MPD218_BACKUP_DIR        default backup directory

Examples:
  $PROG backup
  $PROG read 1 work.mpd218
  $PROG edit -P 1 -o work2.mpd218 work.mpd218
  $PROG write work2.mpd218
EOF
}

# mpd-utils is optional, like every other external tool here: explain rather
# than fail obscurely.
require_utils() {
    local py=$MPD_UTILS_DIR/.venv/bin/python
    [[ -d $MPD_UTILS_DIR ]] || die -"$EX_FAIL" \
        "mpd-utils not found at $MPD_UTILS_DIR; clone https://github.com/mungewell/mpd-utils and set MPD_UTILS_DIR"
    [[ -x $py ]] || die -"$EX_FAIL" \
        "no venv at $py; create it with: uv venv $MPD_UTILS_DIR/.venv && uv pip install --python $py construct qprompt"
    printf '%s' "$py"
}

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

# Pull the preset out of a raw capture, discarding live MIDI that arrived
# alongside it.
extract_preset() {
    local raw=$1 out=$2
    python3 -I -c '
import sys
raw, out, want = sys.argv[1], sys.argv[2], int(sys.argv[3])
data = open(raw, "rb").read()
i = data.find(b"\xf0\x47\x00\x34")
if i < 0:
    sys.exit("no MPD218 sysex header in %d-byte reply" % len(data))
msg = data[i:i + want]
if len(msg) != want:
    sys.exit("truncated sysex: %d bytes, expected %d" % (len(msg), want))
if msg[-1] != 0xF7:
    sys.exit("sysex does not end with F7")
open(out, "wb").write(msg)
' "$raw" "$out" "$MPD218_PRESET_BYTES"
}

cmd_port() { resolve_port; printf '\n'; }

# aconnect and aseqdump address the sequencer, not the raw port, so the two
# namespaces are reported separately.
cmd_seq() {
    local seq
    seq=$(mpd218_seq_port) || die -"$EX_NODEV" "no MPD218 sequencer port found"
    printf '%s\n' "$seq"
}

cmd_read() {
    local n=${1:-} out=${2:-}
    [[ -n $n ]] || die -"$EX_USAGE" "read needs a preset number 1-16"
    local idx port raw
    idx=$(mpd218_preset_hex "$n") || die -"$EX_USAGE" "preset must be 1-16, got '$n'"
    out=${out:-preset_$(printf '%02d' "$n").mpd218}
    port=$(resolve_port)

    info "reading preset $n (0x$idx) from $port"

    if (( DRY_RUN )); then
        run amidi -p "$port" -t 1 -S "F0 47 00 34 12 00 01 $idx F7" -r "$out"
        printf '%s\n' "$out"
        return 0
    fi

    raw=$(mktemp "${TMPDIR:-/tmp}/mpd218.XXXXXX")
    # shellcheck disable=SC2064  # expand $raw now, not at trap time
    trap "rm -f -- '$raw'" RETURN

    # Drain buffered performance MIDI before asking, or it lands in the reply.
    run amidi -p "$port" -t 1 -r /dev/null >/dev/null 2>&1 || true
    run amidi -p "$port" -t 1 -S "F0 47 00 34 12 00 01 $idx F7" -r "$raw"
    extract_preset "$raw" "$out" || die -"$EX_FAIL" "could not extract preset $n from the device reply"

    ok "$(verb read read) preset $n ($MPD218_PRESET_BYTES bytes)"
    printf '%s\n' "$out"
}

cmd_backup() {
    local dir=${1:-$BACKUP_DIR} n
    run mkdir -p -- "$dir"
    for n in $(seq "$MPD218_PRESET_MIN" "$MPD218_PRESET_MAX"); do
        cmd_read "$n" "$dir/preset_$(printf '%02d' "$n").mpd218" >/dev/null
    done
    ok "$(verb back\ up 'backed up') 16 presets"
    printf '%s\n' "$dir"
}

cmd_write() {
    local f=${1:-} port size
    [[ -n $f ]] || die -"$EX_USAGE" "write needs a preset file"
    [[ -f $f ]] || die -"$EX_NODEV" "no such file: $f"
    size=$(stat -c%s -- "$f")
    (( size == MPD218_PRESET_BYTES )) \
        || warn "$f is $size bytes, expected $MPD218_PRESET_BYTES"
    port=$(resolve_port)
    info "sending $f to $port"
    run amidi -p "$port" -s "$f"
    ok "$(verb send sent) $f (lands in the preset slot recorded inside the file)"
}

cmd_dump() {
    local f=${1:-} py
    [[ -n $f ]] || die -"$EX_USAGE" "dump needs a preset file"
    [[ -f $f ]] || die -"$EX_NODEV" "no such file: $f"
    py=$(require_utils)
    run "$py" "$MPD_UTILS_DIR/mpd218.py" -d "$f"
}

cmd_edit() {
    local py
    py=$(require_utils)
    run "$py" "$MPD_UTILS_DIR/mpd218.py" "$@"
}

while (( $# )); do
    case $1 in
        -n|--dry-run) DRY_RUN=1; shift ;;
        -q|--quiet)   QUIET=1; shift ;;
        -h|--help)    usage; exit "$EX_OK" ;;
        -V|--version) printf '%s %s\n' "$PROG" "$VERSION"; exit "$EX_OK" ;;
        --)           shift; break ;;
        -*)           usage; die -"$EX_USAGE" "unknown option: $1" ;;
        *)            break ;;
    esac
done

(( $# )) || { usage; exit "$EX_USAGE"; }

have amidi || die -"$EX_FAIL" "amidi not found; install alsa-utils"

command=$1; shift
case $command in
    port)   cmd_port "$@" ;;
    seq)    cmd_seq "$@" ;;
    read)   cmd_read "$@" ;;
    backup) cmd_backup "$@" ;;
    write)  cmd_write "$@" ;;
    dump)   cmd_dump "$@" ;;
    edit)   cmd_edit "$@" ;;
    *)      usage; die -"$EX_USAGE" "unknown command: $command" ;;
esac
