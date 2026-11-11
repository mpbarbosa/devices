#!/usr/bin/env bash
#
# lib/mpd218.sh - detection for the AKAI MPD218 pad controller.
#
# Pure detection: every helper prints records and none of them touches the
# device. Fields are separated by $DEVICES_FS, never a tab, so an empty
# field cannot shift the later fields left.
#
# The MPD218 is a MIDI controller with no sound engine of its own. It is
# configured over SysEx with the scripts from mungewell/mpd-utils; this
# library only works out where it is attached.

[[ -n ${DEVICES_MPD218_LIB:-} ]] && return 0
DEVICES_MPD218_LIB=1

# Overridable so detection can be pointed at a fixture (see CLAUDE.md).
MPD218_USB_VENDOR=${MPD218_USB_VENDOR:-09e8}
MPD218_USB_PRODUCT=${MPD218_USB_PRODUCT:-0034}
MPD218_NAME=${MPD218_NAME:-MPD218}

# A full preset dump is exactly this many bytes.
MPD218_PRESET_BYTES=${MPD218_PRESET_BYTES:-549}

# Presets are addressed 0x01..0x10. Index 0x00 is NOT "current preset" on
# this device (that is MPD226 behaviour) - it answers with a short stub.
MPD218_PRESET_MIN=1
MPD218_PRESET_MAX=16

# Print one record per MPD218 raw MIDI port:  port<FS>card<FS>description
#
# Card numbers are not stable across reboots, so callers must resolve the
# port at run time rather than storing it.
mpd218_midi_ports() {
    local line port desc fs=$DEVICES_FS
    have amidi || return 0
    while IFS= read -r line; do
        case $line in
            *"$MPD218_NAME"*) ;;
            *) continue ;;
        esac
        # amidi -l rows look like:  IO  hw:1,0,0  MPD218 Port A
        read -r _ port desc <<<"$line"
        [[ -n $port ]] || continue
        printf '%s\n' "$port$fs${port#hw:}$fs${desc:-$MPD218_NAME}"
    done < <(amidi -l 2>/dev/null)
}

# Print just the first port, which is what the config script wants.
mpd218_midi_port() {
    local port
    while IFS=$DEVICES_FS read -r port _; do
        printf '%s\n' "$port"
        return 0
    done < <(mpd218_midi_ports)
    return 1
}

# True when the USB device is present at all, which tells "not plugged in"
# apart from "plugged in but ALSA never claimed it".
mpd218_usb_present() {
    have lsusb || return 1
    lsusb -d "$MPD218_USB_VENDOR:$MPD218_USB_PRODUCT" >/dev/null 2>&1
}

# Validate a preset number, printing the two-digit hex index used in SysEx.
mpd218_preset_hex() {
    local n=$1
    [[ $n =~ ^[0-9]+$ ]] || return 1
    (( n >= MPD218_PRESET_MIN && n <= MPD218_PRESET_MAX )) || return 1
    printf '%02X' "$n"
}

# Print one record per ALSA *sequencer* port:  client<FS>port<FS>description
#
# The raw port from mpd218_midi_ports (hw:1,0,0) is what amidi needs for
# sysex; aconnect instead needs a sequencer address such as 20:0. They are
# two namespaces for the same hardware, so both are detected here.
mpd218_seq_ports() {
    local line client='' name port desc mine=0 fs=$DEVICES_FS
    have aconnect || return 0
    while IFS= read -r line; do
        if [[ $line == client\ * ]]; then
            name=${line#*\'}; name=${name%\'*}
            client=${line#client }; client=${client%%:*}
            [[ $name == *"$MPD218_NAME"* ]] && mine=1 || mine=0
            continue
        fi
        (( mine )) || continue
        [[ $line == [[:space:]]* ]] || continue
        desc=${line#*\'}; desc=${desc%\'*}
        read -r port _ <<<"$line"
        [[ $port =~ ^[0-9]+$ ]] || continue
        printf '%s\n' "$client$fs$port$fs$desc"
    done < <(aconnect -l 2>/dev/null)
}

# Print just the first sequencer address, as client:port.
mpd218_seq_port() {
    local client port
    while IFS=$DEVICES_FS read -r client port _; do
        printf '%s:%s\n' "$client" "$port"
        return 0
    done < <(mpd218_seq_ports)
    return 1
}
