#!/usr/bin/env bash
#
# lib/camera.sh - detection for video capture devices (webcams).
#
# Pure detection: every helper prints records and none of them opens the
# camera or launches anything. Fields are separated by $DEVICES_FS, never a
# tab, so an empty field cannot shift the later fields left.
#
# A camera is unlike the other devices in this suite: there is nothing to
# mount and nothing to configure, so the whole job is working out which node
# is the camera a human means - and on a modern laptop that is not obvious.
#
# The central domain fact: ONE webcam presents FOUR /dev/video* nodes, and
# only one of them is the camera anybody wants. Measured on the Integrated
# Webcam FHD in this host (vendor 0bda, product 5586, one serial for all
# four nodes):
#
#   /dev/video0   ID_V4L_CAPABILITIES=:capture:   MJPG, YUYV   <- the camera
#   /dev/video1   ID_V4L_CAPABILITIES=:           no formats   metadata
#   /dev/video2   ID_V4L_CAPABILITIES=:capture:   GREY only    infrared
#   /dev/video3   ID_V4L_CAPABILITIES=:           no formats   metadata
#
# Two separate traps are hiding in that table.
#
# The metadata nodes are not capture devices at all. UVC registers a second
# node per stream to carry per-frame metadata, and opening it yields no
# image. udev labels them: ID_V4L_CAPABILITIES is ":capture:" for a real
# capture node and bare ":" for metadata, which is what camera_capture_nodes
# filters on. The node numbers interleave, so "the lowest /dev/video*" is
# right here only by luck and "video1" is wrong on every such webcam.
#
# The infrared sensor is the harder one, because udev calls it a capture
# node too - correctly, it does capture. It is the face-recognition camera,
# it offers GREY (8-bit greyscale) and nothing else, and software that opens
# it shows a dim grey picture that looks exactly like a broken webcam. No
# udev property distinguishes it; the two differ only in the pixel formats
# they enumerate, which needs a VIDIOC_ENUM_FMT ioctl that bash cannot make.
# So camera_node_kind asks v4l2-ctl (package v4l-utils) when it is
# installed, and otherwise
# falls back on the USB interface number: both nodes share one serial, the
# colour camera sits on the lower interface (here :1.0 against :1.2) because
# UVC puts the primary stream first. That ordering held on this hardware and
# is the usual UVC layout, but it is an inference rather than a reading -
# the kind field says "colour" or "ir" when it was measured and "unknown"
# when it was guessed, so callers can tell the two apart.
#
# None of this reaches GNOME Camera, which takes no device argument: it gets
# its camera list from PipeWire through the org.freedesktop.portal.Camera
# portal and offers a switcher in its own UI. Detection here is therefore
# for diagnostics - telling "no camera attached" apart from "camera attached
# but only the infrared sensor answers" - and for callers like ffmpeg that
# do need a node path.

[[ -n ${DEVICES_CAMERA_LIB:-} ]] && return 0
DEVICES_CAMERA_LIB=1

# Overridable so detection can be pointed at a fixture (see CLAUDE.md).
CAMERA_SYSFS_V4L=${CAMERA_SYSFS_V4L:-/sys/class/video4linux}
CAMERA_DEV_DIR=${CAMERA_DEV_DIR:-/dev}

# GNOME Camera ships as the binary "snapshot" (Debian package
# gnome-snapshot, desktop id org.gnome.Snapshot). gnome-snapshot is listed
# too because the binary has been named both ways across distributions.
CAMERA_APPS=${CAMERA_APPS:-'snapshot gnome-snapshot'}
CAMERA_APP_ID=${CAMERA_APP_ID:-org.gnome.Snapshot}
CAMERA_APP_NAME=${CAMERA_APP_NAME:-GNOME Camera}

# ------------------------------------------------------------------- nodes

# Print one record per /dev/video* node, whether it captures or not:
#
#   node<FS>caps<FS>name<FS>serial<FS>devpath
#
# caps is the raw udev ID_V4L_CAPABILITIES string (":capture:" for a real
# capture node, ":" for a metadata node, empty when udevadm is unavailable).
camera_video_nodes() {
    local dir base node name caps serial devpath props fs=$DEVICES_FS
    [[ -d $CAMERA_SYSFS_V4L ]] || return 0
    for dir in "$CAMERA_SYSFS_V4L"/video*; do
        [[ -d $dir ]] || continue
        base=${dir##*/}
        node=$CAMERA_DEV_DIR/$base
        name=''
        [[ -r $dir/name ]] && IFS= read -r name < "$dir/name"
        caps='' serial='' devpath=''
        if have udevadm; then
            props=$(udevadm info --query=property --name="$node" 2>/dev/null) || props=''
            caps=$(printf '%s\n' "$props" | sed -n 's/^ID_V4L_CAPABILITIES=//p')
            serial=$(printf '%s\n' "$props" | sed -n 's/^ID_SERIAL_SHORT=//p')
            devpath=$(printf '%s\n' "$props" | sed -n 's/^ID_PATH=//p')
        fi
        printf '%s\n' "$node$fs$caps$fs$name$fs$serial$fs$devpath"
    done
}

# The pixel formats a node enumerates, space separated, upper case fourccs.
# Empty when v4l2-ctl is not installed - bash cannot make the ioctl itself.
camera_node_formats() {
    local node=$1 out
    have v4l2-ctl || return 1
    out=$(v4l2-ctl --device "$node" --list-formats 2>/dev/null) || return 1
    printf '%s\n' "$out" | sed -n "s/.*'\\([A-Za-z0-9]\\{4\\}\\)'.*/\\1/p" | tr '\n' ' '
}

# "colour", "ir" or "unknown" for one capture node.
#
# Measured when v4l2-ctl is installed: a node offering only GREY is the
# infrared sensor. Inferred otherwise, from the USB interface order within
# one serial - hence "unknown" rather than a confident answer.
camera_node_kind() {
    local node=$1 serial=$2 devpath=$3 fmts first_path c s p
    if fmts=$(camera_node_formats "$node"); then
        fmts=${fmts% }
        [[ -z $fmts ]] && { printf 'unknown'; return 0; }
        # Greyscale as the ONLY format is the infrared sensor; greyscale
        # among several is just one mode of a colour camera.
        case ${fmts// /} in
            GREY|Y800) printf 'ir'; return 0 ;;
        esac
        printf 'colour'
        return 0
    fi
    # No ioctl available. Within one serial the colour camera is on the
    # lower USB interface, so only the first capture node can be colour.
    #
    # camera_video_nodes prints FIVE fields and every one of them has to be
    # read: with four variables the last swallows the rest, which put the
    # device name where the serial belongs, matched nothing, and labelled
    # the colour camera an infrared sensor on a host where it is fine.
    [[ -n $serial && -n $devpath ]] || { printf 'unknown'; return 0; }
    first_path=''
    while IFS=$DEVICES_FS read -r _ c _ s p; do
        [[ $c == *capture* ]] || continue
        [[ $s == "$serial" ]] || continue
        first_path=$p
        break
    done < <(camera_video_nodes)
    [[ $first_path == "$devpath" ]] && printf 'unknown' || printf 'ir'
}

# Print one record per real capture node, infrared included:
#
#   node<FS>kind<FS>name<FS>serial<FS>devpath
#
# kind is "colour", "ir" or "unknown"; see camera_node_kind.
camera_capture_nodes() {
    local node caps name serial devpath kind fs=$DEVICES_FS
    while IFS=$DEVICES_FS read -r node caps name serial devpath; do
        if [[ -n $caps ]]; then
            [[ $caps == *capture* ]] || continue
        else
            # udevadm unavailable: every node is a candidate, and a
            # character device is the most that can be checked here.
            [[ -c $node ]] || continue
        fi
        kind=$(camera_node_kind "$node" "$serial" "$devpath")
        printf '%s\n' "$node$fs$kind$fs$name$fs$serial$fs$devpath"
    done < <(camera_video_nodes)
}

# The node a human means: the first capture node that is not the infrared
# sensor. Prints nothing and returns 1 when there is no such node.
camera_primary_node() {
    local node kind fallback=''
    while IFS=$DEVICES_FS read -r node kind _; do
        case $kind in
            colour)  printf '%s\n' "$node"; return 0 ;;
            unknown) [[ -n $fallback ]] || fallback=$node ;;
        esac
    done < <(camera_capture_nodes)
    [[ -n $fallback ]] || return 1
    printf '%s\n' "$fallback"
}

# True when any capture node exists at all, infrared included. Separates
# "no camera attached" from "camera attached but only the IR sensor".
camera_any_capture_node() {
    local node
    while IFS=$DEVICES_FS read -r node _; do
        [[ -n $node ]] && return 0
    done < <(camera_capture_nodes)
    return 1
}

# ------------------------------------------------------------------- the app

# Print the argv that launches GNOME Camera, one word per line, so a caller
# can read it with mapfile. Returns 1 when the app is not installed.
#
# A plain binary is preferred over the flatpak: the flatpak needs its own
# camera permission, and a host install already has the portal.
camera_app_argv() {
    local app
    for app in $CAMERA_APPS; do
        if have "$app"; then
            printf '%s\n' "$app"
            return 0
        fi
    done
    if have flatpak && flatpak info "$CAMERA_APP_ID" >/dev/null 2>&1; then
        printf '%s\n%s\n%s\n' flatpak run "$CAMERA_APP_ID"
        return 0
    fi
    return 1
}

# True when the camera portal is on the session bus. GNOME Camera reaches
# the camera only through org.freedesktop.portal.Camera, so a missing
# portal is a real failure and not the camera's fault.
camera_portal_available() {
    have gdbus || return 0   # cannot tell; do not claim a fault
    gdbus call --session \
        --dest org.freedesktop.DBus \
        --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.NameHasOwner \
        org.freedesktop.portal.Desktop 2>/dev/null | grep -q true
}

# True when this user may open the video nodes at all. Permission is by
# group on every distribution that ships uaccess rules, so a user outside
# "video" with no seat gets EACCES on open and no useful error from the app.
camera_user_can_open() {
    local node=$1
    [[ -r $node && -w $node ]]
}

# True when there is a graphical session to put a window on.
camera_display_available() {
    [[ -n ${WAYLAND_DISPLAY:-} || -n ${DISPLAY:-} ]]
}
