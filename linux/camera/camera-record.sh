#!/usr/bin/env bash
#
# camera-record.sh - record video from the webcam straight to a file.
#
# The GUI route is camera-open.sh; this is the one that needs no desktop, so
# it works over ssh and in a script. ffmpeg does the work, with this host's
# defaults baked in: 1920x1080 at 30fps, H.264 (veryfast) and AAC audio from
# the PulseAudio shim that PipeWire provides.
#
# Three things it does that the bare ffmpeg command line cannot.
#
# It resolves the device instead of hardcoding /dev/video0. That node number
# is not stable across reboots, and this laptop's webcam registers four
# nodes of which only one is the colour camera - the other capture node is
# the infrared face-recognition sensor, which records a dim grey picture
# that looks like broken hardware (see lib/camera.sh). So the node comes
# from camera_primary_node, and picking the infrared one with --device is
# warned about rather than silently obeyed.
#
# It refuses to overwrite. ffmpeg would ask, or clobber the file outright
# with -y; a recording is not reproducible, so an existing file is an error
# here until --force says otherwise.
#
# And it reports the stop honestly. Measured with ffmpeg 8.0.1 on this host:
# interrupting a capture with Ctrl-C (SIGINT) finalises the file properly -
# a 2-second run cut at 1.2s produced valid, playable H.264 - but ffmpeg
# still exits 255. Under `set -e` that would abort the script and the report
# would never print, making a perfectly good recording look like a failure.
# So 255 and 130 are a normal stop when no --duration was asked for, and a
# failure when one was, because then ffmpeg should have stopped by itself.
#
# One piece of expected noise, so it is not mistaken for a fault: a capture
# with audio opens two inputs whose clocks start a few milliseconds apart,
# and ffmpeg says so once per recording - "Queue input is backward in time"
# and "Non-monotonic DTS". The log level stays at `warning` rather than
# hiding them, because the same level is what reports a dropped frame or a
# failing encoder, and those are worth seeing.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR/..

_self=${BASH_SOURCE[0]}
_self=$(readlink -f -- "$_self" 2>/dev/null || printf '%s' "$_self")
ROOT_DIR=$(cd -- "$(dirname -- "$_self")/.." && pwd -P)
# shellcheck source=lib/common.sh
. "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/camera.sh
. "$ROOT_DIR/lib/camera.sh"

VERSION=1.0.0
PROG=${0##*/}

DEVICE=''
OUTPUT=''
DURATION=0
FORCE=0
AUDIO=1

SIZE=${CAMERA_RECORD_SIZE:-1920x1080}
FPS=${CAMERA_RECORD_FPS:-30}
AUDIO_SOURCE=${CAMERA_AUDIO_SOURCE:-default}
VIDEO_CODEC=${CAMERA_VIDEO_CODEC:-libx264}
VIDEO_PRESET=${CAMERA_VIDEO_PRESET:-veryfast}
AUDIO_CODEC=${CAMERA_AUDIO_CODEC:-aac}

# xdg-user-dir knows the localised name of the videos folder; on this host
# in pt_BR it is still ~/Videos, but it is asked rather than assumed.
default_dir() {
    local dir=''
    if [[ -n ${CAMERA_RECORD_DIR:-} ]]; then
        printf '%s' "$CAMERA_RECORD_DIR"
        return 0
    fi
    if have xdg-user-dir; then
        dir=$(xdg-user-dir VIDEOS 2>/dev/null) || dir=''
    fi
    [[ -n $dir && $dir != "$HOME" ]] || dir=$HOME/Videos
    printf '%s' "$dir"
}

usage() {
    cat >&2 <<EOF
Usage: $PROG [options]

Records video and audio from the webcam to a file. Runs until Ctrl-C (or q)
unless --duration is given.

Options:
  -d, --device NODE    capture node (default: the colour camera, resolved)
  -o, --output FILE    output file (default: <videos dir>/camera-<date>.mp4)
  -t, --duration SECS  stop after SECS seconds (default: run until stopped)
  -s, --size WxH       frame size (default: $SIZE)
  -r, --framerate FPS  frames per second (default: $FPS)
  -a, --audio SOURCE   PulseAudio source (default: $AUDIO_SOURCE)
  -A, --no-audio       record video only
  -f, --force          overwrite the output file if it exists
  -n, --dry-run        print what would be done, record nothing
  -q, --quiet          suppress progress output
  -h, --help           this help
  -V, --version        version

Output:
  stdout is the result, so it carries the path of the file that was written:

    f=\$($PROG -t 10 -q) && mpv "\$f"

Exit codes:
  0 ok   1 ffmpeg missing or output exists   2 bad usage   3 no camera
  4 the camera is in use by something else

Environment:
  CAMERA_RECORD_DIR, CAMERA_RECORD_SIZE, CAMERA_RECORD_FPS,
  CAMERA_AUDIO_SOURCE, CAMERA_VIDEO_CODEC, CAMERA_VIDEO_PRESET,
  CAMERA_AUDIO_CODEC
EOF
}

# The kind ("colour", "ir", "unknown") recorded for one node, or empty when
# the node is not a capture node at all.
node_kind() {
    local want=$1 node kind
    while IFS=$DEVICES_FS read -r node kind _; do
        [[ $node == "$want" ]] || continue
        printf '%s' "$kind"
        return 0
    done < <(camera_capture_nodes)
    return 1
}

resolve_device() {
    local kind
    if [[ -n $DEVICE ]]; then
        [[ -c $DEVICE ]] || die -"$EX_NODEV" "not a device node: $DEVICE"
        if kind=$(node_kind "$DEVICE"); then
            [[ $kind == ir ]] && warn \
                "$DEVICE is the infrared sensor, so the video will be grey and dim"
        else
            warn "$DEVICE does not look like a capture node; recording anyway"
        fi
        printf '%s' "$DEVICE"
        return 0
    fi
    if ! camera_any_capture_node; then
        die -"$EX_NODEV" "no camera found (try $ROOT_DIR/camera/camera-open.sh --list)"
    fi
    DEVICE=$(camera_primary_node) || die -"$EX_NODEV" \
        "the only capture node is the infrared sensor; pass --device to use it anyway"
    printf '%s' "$DEVICE"
}

# Another process streaming from the node makes v4l2 refuse the open, and
# ffmpeg's own message for that is just "Device or resource busy". Measured
# on this host: GNOME Camera being open does NOT hold the node, because it
# goes through PipeWire, so this fires only for a real second reader.
check_not_busy() {
    local node=$1 holders
    have fuser || return 0
    holders=$(fuser -- "$node" 2>/dev/null) || return 0
    [[ -n ${holders// /} ]] || return 0
    warn "$node is open by pid(s):${holders}"
    report_blockers "$node"
    die -"$EX_BUSY" "the camera is in use; stop the other reader first"
}

check_audio() {
    local sock=/run/user/${UID}/pulse/native
    (( AUDIO )) || return 0
    [[ -S $sock ]] && return 0
    warn "no PulseAudio socket at $sock; audio may fail - use --no-audio for video only"
}

main() {
    local node out rc=0 dir
    local -a cmd=()

    if ! have ffmpeg; then
        (( DRY_RUN )) || die -"$EX_FAIL" \
            "ffmpeg not found; install it with: sudo apt install ffmpeg"
        warn "ffmpeg not installed; install with: sudo apt install ffmpeg"
    fi

    node=$(resolve_device)
    check_not_busy "$node"
    check_audio

    out=$OUTPUT
    if [[ -z $out ]]; then
        dir=$(default_dir)
        out=$dir/camera-$(date +%Y%m%d-%H%M%S).mp4
    fi
    out=$(normalize_path "$out")

    if [[ -e $out ]] && ! (( FORCE )); then
        die -"$EX_FAIL" "refusing to overwrite $out (pass --force to replace it)"
    fi

    dir=${out%/*}
    [[ -d $dir ]] || run mkdir -p -- "$dir"

    cmd=(ffmpeg -hide_banner -loglevel warning
         -f v4l2 -framerate "$FPS" -video_size "$SIZE" -i "$node")
    (( AUDIO )) && cmd+=(-f pulse -i "$AUDIO_SOURCE")
    (( DURATION > 0 )) && cmd+=(-t "$DURATION")
    cmd+=(-c:v "$VIDEO_CODEC" -preset "$VIDEO_PRESET")
    (( AUDIO )) && cmd+=(-c:a "$AUDIO_CODEC")
    cmd+=(-y "$out")

    info "camera    $node"
    info "size      $SIZE @ ${FPS}fps"
    info "audio     $( (( AUDIO )) && printf '%s' "$AUDIO_SOURCE" || printf 'none')"
    info "output    $out"
    if (( DURATION > 0 )); then
        info "duration  ${DURATION}s"
    else
        info "duration  until you stop it (Ctrl-C, or q)"
    fi

    run "${cmd[@]}" || rc=$?

    if (( rc != 0 )); then
        # 255 is ffmpeg's exit after SIGINT; the file is finalised and valid.
        # Only a stop that was asked for counts as normal.
        if (( DURATION == 0 )) && { (( rc == 255 )) || (( rc == 130 )); }; then
            info "stopped"
        else
            die -"$EX_FAIL" "ffmpeg failed (exit $rc)"
        fi
    fi

    if (( DRY_RUN )); then
        ok "$(verb record recorded) to $out"
        printf '%s\n' "$out"
        return 0
    fi

    [[ -s $out ]] || die -"$EX_FAIL" "ffmpeg wrote nothing to $out"

    if have ffprobe; then
        local secs
        secs=$(ffprobe -hide_banner -loglevel error \
                 -show_entries format=duration -of csv=p=0 -- "$out" 2>/dev/null) || secs=''
        [[ -n $secs ]] && info "recorded  ${secs}s"
    fi
    ok "recorded to $out ($(du -h -- "$out" | cut -f1))"
    printf '%s\n' "$out"
}

while (( $# )); do
    case $1 in
        -d|--device)    DEVICE=${2:?--device needs a node}; shift 2 ;;
        -o|--output)    OUTPUT=${2:?--output needs a path}; shift 2 ;;
        -t|--duration)  DURATION=${2:?--duration needs seconds}; shift 2 ;;
        -s|--size)      SIZE=${2:?--size needs WxH}; shift 2 ;;
        -r|--framerate) FPS=${2:?--framerate needs a number}; shift 2 ;;
        -a|--audio)     AUDIO_SOURCE=${2:?--audio needs a source}; AUDIO=1; shift 2 ;;
        -A|--no-audio)  AUDIO=0; shift ;;
        -f|--force)     FORCE=1; shift ;;
        -n|--dry-run)   DRY_RUN=1; shift ;;
        -q|--quiet)     QUIET=1; shift ;;
        -h|--help)      usage; exit "$EX_OK" ;;
        -V|--version)   printf '%s %s\n' "$PROG" "$VERSION"; exit "$EX_OK" ;;
        --)             shift; break ;;
        *)              usage; die -"$EX_USAGE" "unknown option: $1" ;;
    esac
done

(( $# == 0 )) || { usage; die -"$EX_USAGE" "unexpected argument: $1"; }

[[ $DURATION =~ ^[0-9]+$ ]] || die -"$EX_USAGE" "--duration needs whole seconds, got '$DURATION'"
[[ $FPS =~ ^[0-9]+$ ]] || die -"$EX_USAGE" "--framerate needs a number, got '$FPS'"
[[ $SIZE =~ ^[0-9]+x[0-9]+$ ]] || die -"$EX_USAGE" "--size needs WxH, got '$SIZE'"

main
