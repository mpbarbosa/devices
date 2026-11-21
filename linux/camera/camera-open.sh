#!/usr/bin/env bash
#
# camera-open.sh - open GNOME Camera on the webcam.
#
# GNOME Camera (the "snapshot" binary, desktop id org.gnome.Snapshot) takes
# no device argument. It gets its camera list from PipeWire through the
# org.freedesktop.portal.Camera portal and switches between cameras in its
# own UI, so this script cannot point it at a node and does not try to.
#
# What it does instead is everything around the launch, because when a
# webcam "does not work" the app itself is the last place the fault is. It
# checks that the app is installed, that there is a graphical session to put
# the window on, that a capture node exists and is readable by this user,
# and that the camera portal is on the session bus - then reports which of
# those failed rather than leaving a window showing black.
#
# The one check worth knowing about: this laptop's webcam presents two
# capture nodes, the colour camera and the infrared face-recognition sensor,
# and nothing in udev tells them apart (see lib/camera.sh). A host where the
# only capture node is the infrared one shows a dim grey picture that looks
# like broken hardware, so that case is warned about explicitly.
#
# The app is detached by default: it is a GUI program and closing the
# terminal should not take the window with it. --wait keeps it in the
# foreground instead, which is how to see its own diagnostics.

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

LIST=0
WAIT=0

usage() {
    cat >&2 <<EOF
Usage: $PROG [options]

Opens $CAMERA_APP_NAME, after checking that there is a camera for it to show.

Options:
  -l, --list       list the capture nodes on stdout and exit, launching nothing
  -w, --wait       keep the app in the foreground (default: detach it)
  -n, --dry-run    print what would be done, change nothing
  -q, --quiet      suppress progress output
  -h, --help       this help
  -V, --version    version

Output:
  stdout is the result and stderr the conversation, so stdout carries the
  process id of the app that was started - or, with --list, one capture node
  path per line, the colour camera first:

    pid=\$($PROG -q)                       # start it, keep the pid
    ffmpeg -i "\$($PROG -l -q | head -1)" ...   # just the device path

Exit codes:
  0 ok   1 app or session missing   2 bad usage   3 no camera found

Environment:
  CAMERA_APPS, CAMERA_APP_ID, CAMERA_SYSFS_V4L, CAMERA_DEV_DIR
EOF
}

# Capture nodes in the order a caller wants them: the colour camera first,
# then anything unidentified, with the infrared sensor last.
#
# Preference cannot be a plain sort on the kind field - "ir" sorts before
# "unknown", which put the infrared sensor at the head of --list and so at
# the head of the ffmpeg pipeline the help recommends. The rank is explicit
# for that reason, and matches camera_primary_node's own preference.
ranked_capture_nodes() {
    local record kind rank
    while IFS= read -r record; do
        IFS=$DEVICES_FS read -r _ kind _ <<<"$record"
        case $kind in
            colour)  rank=0 ;;
            unknown) rank=1 ;;
            *)       rank=2 ;;
        esac
        printf '%s%s%s\n' "$rank" "$DEVICES_FS" "$record"
    done < <(camera_capture_nodes) | sort -n -k1,1 | cut -d"$DEVICES_FS" -f2-
}

# One line per capture node on stderr, so --list keeps stdout machine-readable.
describe_nodes() {
    local node kind name _serial _path label inferred=0
    while IFS=$DEVICES_FS read -r node kind name _serial _path; do
        case $kind in
            colour)  label='colour camera' ;;
            ir)      label='infrared sensor (greyscale; not the camera you want)' ;;
            *)       label='colour camera, most likely - first stream on this unit'
                     inferred=1 ;;
        esac
        info "  $node  $label${name:+  [$name]}"
    done < <(ranked_capture_nodes)
    (( inferred )) && info \
        "  (install v4l-utils to read the pixel formats instead of inferring)"
    return 0
}

# Everything that is wrong when no capture node turned up.
diagnose_no_camera() {
    local nodes
    nodes=$(camera_video_nodes | wc -l)
    if (( nodes > 0 )); then
        warn "$nodes /dev/video* node(s) exist but none of them captures;"
        warn "those are UVC metadata nodes, so the camera itself never registered"
    fi
    if ! grep -qw uvcvideo /proc/modules 2>/dev/null; then
        warn "the uvcvideo module is not loaded; try: sudo modprobe uvcvideo"
    fi
    if have lsusb && ! lsusb 2>/dev/null | grep -qiE 'camera|webcam'; then
        info "no camera on the USB bus either - an internal webcam can also be"
        info "switched off in firmware, or behind a hardware privacy shutter"
    fi
}

main() {
    local -a app=()
    local node primary='' pid

    if ! mapfile -t app < <(camera_app_argv) || (( ${#app[@]} == 0 )); then
        die -"$EX_FAIL" \
            "$CAMERA_APP_NAME not found; install it with: sudo apt install gnome-snapshot"
    fi

    if ! camera_any_capture_node; then
        diagnose_no_camera
        die -"$EX_NODEV" "no camera found"
    fi

    if (( LIST )); then
        info "capture nodes:"
        describe_nodes
        while IFS=$DEVICES_FS read -r node _; do
            printf '%s\n' "$node"
        done < <(ranked_capture_nodes)
        return 0
    fi

    if primary=$(camera_primary_node); then
        info "camera    $primary"
        camera_user_can_open "$primary" || warn \
            "$primary is not readable by this user; add yourself to the video group:
         sudo usermod -aG video $USER   (then log out and back in)"
    else
        # Capture nodes exist, but every one of them is the IR sensor.
        warn "the only capture node is the infrared sensor, so the picture will be"
        warn "grey and dim - that is the face-recognition camera, not the webcam"
        describe_nodes
    fi

    camera_display_available || die -"$EX_FAIL" \
        "no graphical session (DISPLAY and WAYLAND_DISPLAY are both unset)"

    camera_portal_available || warn \
        "the desktop portal is not on the session bus; $CAMERA_APP_NAME reaches the
         camera only through it, so install xdg-desktop-portal if it shows nothing"

    if pgrep -x "${app[0]##*/}" >/dev/null 2>&1; then
        info "$CAMERA_APP_NAME is already running; this will raise its window"
    fi

    info "app       $(quote_cmd "${app[@]}")"

    if (( WAIT )) || (( DRY_RUN )); then
        # Dry run reports through run(); --wait replaces this shell so Ctrl-C
        # reaches the app directly.
        if (( DRY_RUN )); then
            run "${app[@]}"
            ok "$(verb open opened) $CAMERA_APP_NAME"
            return 0
        fi
        debug "$(quote_cmd "${app[@]}")"
        exec "${app[@]}"
    fi

    # Detached: a new session, so closing the terminal leaves the window up.
    debug "$(quote_cmd setsid "${app[@]}")"
    setsid "${app[@]}" >/dev/null 2>&1 &
    pid=$!
    ok "opened $CAMERA_APP_NAME (pid $pid)"
    printf '%s\n' "$pid"
}

while (( $# )); do
    case $1 in
        -l|--list)    LIST=1; shift ;;
        -w|--wait)    WAIT=1; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -q|--quiet)   QUIET=1; shift ;;
        -h|--help)    usage; exit "$EX_OK" ;;
        -V|--version) printf '%s %s\n' "$PROG" "$VERSION"; exit "$EX_OK" ;;
        --)           shift; break ;;
        *)            usage; die -"$EX_USAGE" "unknown option: $1" ;;
    esac
done

(( $# == 0 )) || { usage; die -"$EX_USAGE" "unexpected argument: $1"; }

main
