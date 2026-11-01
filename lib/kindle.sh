#!/usr/bin/env bash
# Kindle detection helpers shared by kindle-mount.sh and kindle-unmount.sh.
# Source this file after lib/common.sh.
#
# Two kinds of Kindle exist on Linux:
#   ums  - USB mass storage, a vfat partition (Paperwhite up to 11th gen,
#          Basic, Oasis, Voyage, older Fire). Mounted like any USB stick.
#   mtp  - Media Transfer Protocol, no block device at all (Scribe,
#          Colorsoft, Paperwhite 2024 and later). Needs a FUSE helper.
#
# Every helper that prints records separates fields with $DEVICES_FS, so an
# empty field (an unmounted device) survives the round trip.

# shellcheck shell=bash

[[ -n ${_DEVICES_KINDLE_SOURCED:-} ]] && return 0
_DEVICES_KINDLE_SOURCED=1

[[ -n ${_DEVICES_COMMON_SOURCED:-} ]] || {
    printf 'error: lib/common.sh must be sourced before lib/kindle.sh\n' >&2
    exit 1
}

# Amazon's USB vendor ID. Kindle hardware reports Lab126, their device arm.
KINDLE_USB_VENDOR=${KINDLE_USB_VENDOR:-1949}

# Filesystem label of a mass-storage Kindle, matched case-insensitively.
KINDLE_LABEL=${KINDLE_LABEL:-Kindle}

# Where USB devices are enumerated; overridable so this can be tested.
KINDLE_SYSFS_USB=${KINDLE_SYSFS_USB:-/sys/bus/usb/devices}

# Read every udev property of a device into the KINDLE_PROPS array.
kindle_load_props() {
    local dev=$1 key val
    declare -gA KINDLE_PROPS=()
    while IFS='=' read -r key val; do
        [[ -n $key ]] && KINDLE_PROPS[$key]=$val
    done < <(udevadm info --query=property --name="$dev" 2>/dev/null)
    (( ${#KINDLE_PROPS[@]} ))
}

# Does this USB block device look like a Kindle?
kindle_props_match() {
    local label=${KINDLE_PROPS[ID_FS_LABEL]:-} vendor=${KINDLE_PROPS[ID_VENDOR]:-}
    local model=${KINDLE_PROPS[ID_MODEL]:-} serial=${KINDLE_PROPS[ID_SERIAL]:-}
    local vid=${KINDLE_PROPS[ID_VENDOR_ID]:-}
    [[ ${vid,,} == "${KINDLE_USB_VENDOR,,}" ]] && return 0
    [[ ${label,,} == "${KINDLE_LABEL,,}" ]] && return 0
    case "${vendor,,} ${model,,} ${serial,,}" in
        *kindle*|*amazon*|*lab126*) return 0 ;;
    esac
    return 1
}

# Mass-storage Kindle partitions, one record per line:
#   DEVNODE | LABEL | FSTYPE | MOUNTPOINT | DESCRIPTION
kindle_ums_devices() {
    have lsblk || { debug "lsblk missing, skipping mass-storage probe"; return 0; }
    have udevadm || { debug "udevadm missing, skipping mass-storage probe"; return 0; }

    local dev type mp desc fs=$DEVICES_FS
    while read -r dev type; do
        [[ $type == part || $type == disk ]] || continue
        kindle_load_props "$dev" || continue
        [[ ${KINDLE_PROPS[ID_BUS]:-} == usb ]] || continue
        # A whole disk is only interesting when it carries the filesystem itself.
        [[ $type == disk && -z ${KINDLE_PROPS[ID_FS_TYPE]:-} ]] && continue
        kindle_props_match || continue

        mp=$(device_mountpoint "$dev" || true)
        desc="${KINDLE_PROPS[ID_VENDOR]:-unknown} ${KINDLE_PROPS[ID_MODEL]:-device}"
        printf '%s\n' "$dev$fs${KINDLE_PROPS[ID_FS_LABEL]:-}$fs${KINDLE_PROPS[ID_FS_TYPE]:-auto}$fs$mp$fs${desc//_/ }"
    done < <(lsblk --raw --noheadings --paths --output NAME,TYPE 2>/dev/null)
}

# The disk a partition belongs to, for eject/power-off.
kindle_parent_disk() {
    local dev=$1 parent
    parent=$(lsblk --noheadings --output PKNAME "$dev" 2>/dev/null | head -n1)
    parent=${parent//[[:space:]]/}
    [[ -n $parent ]] || return 1
    printf '/dev/%s\n' "$parent"
}

# USB interface classes of a device, comma separated.
# 08 = mass storage, 06 = still image / PTP, which is what MTP rides on.
kindle_usb_classes() {
    local sys=$1 i cls out=''
    for i in "$sys":*; do
        [[ -r $i/bInterfaceClass ]] || continue
        read -r cls < "$i/bInterfaceClass" || continue
        out+="${out:+,}$cls"
    done
    printf '%s' "$out"
}

# Is any interface of this USB device claimed by a kernel driver?
kindle_usb_bound() {
    local sys=$1 i
    for i in "$sys":*; do
        [[ -e $i/driver ]] && return 0
    done
    return 1
}

# Every Amazon device on the USB bus, one record per line:
#   SYSPATH | BUS | DEV | CLASSES | BOUND | DESCRIPTION
kindle_usb_devices() {
    local d vid product manufacturer busnum devnum bound fs=$DEVICES_FS
    for d in "$KINDLE_SYSFS_USB"/*; do
        [[ -r $d/idVendor ]] || continue
        read -r vid < "$d/idVendor" || continue
        [[ ${vid,,} == "${KINDLE_USB_VENDOR,,}" ]] || continue
        product='' manufacturer='' busnum='' devnum=''
        [[ -r $d/product ]]      && read -r product      < "$d/product"
        [[ -r $d/manufacturer ]] && read -r manufacturer < "$d/manufacturer"
        [[ -r $d/busnum ]]       && read -r busnum       < "$d/busnum"
        [[ -r $d/devnum ]]       && read -r devnum       < "$d/devnum"
        bound=0; kindle_usb_bound "$d" && bound=1
        printf '%s\n' "$d$fs${busnum:-?}$fs${devnum:-?}$fs$(kindle_usb_classes "$d")$fs$bound$fs${manufacturer:-Amazon} ${product:-Kindle}"
    done
}

# Kindles speaking MTP, one record per line:
#   BUS | DEV | SYSPATH | DESCRIPTION
kindle_mtp_devices() {
    local sys bus dev classes bound desc fs=$DEVICES_FS
    while IFS=$DEVICES_FS read -r sys bus dev classes bound desc; do
        : "$bound"
        case ",$classes," in
            *,06,*) printf '%s\n' "$bus$fs$dev$fs$sys$fs$desc" ;;
        esac
    done < <(kindle_usb_devices)
}

# Kindles offering USB mass storage, one record per line:
#   SYSPATH | BUS | DEV | BOUND | DESCRIPTION
# BOUND is 0 when no kernel driver claimed the device, which is why no block
# device shows up even though the Kindle is plugged in.
kindle_ums_usb_devices() {
    local sys bus dev classes bound desc fs=$DEVICES_FS
    while IFS=$DEVICES_FS read -r sys bus dev classes bound desc; do
        case ",$classes," in
            *,08,*) printf '%s\n' "$sys$fs$bus$fs$dev$fs$bound$fs$desc" ;;
        esac
    done < <(kindle_usb_devices)
}

# Can the kernel claim a mass-storage Kindle at all?
kindle_usb_storage_loaded() {
    [[ -d /sys/module/usb_storage ]] && return 0
    [[ -r /proc/modules ]] || return 0
    grep -qE '^(usb_storage|uas) ' /proc/modules
}

# First available MTP FUSE helper, or nothing.
kindle_mtp_helper() {
    local h
    for h in jmtpfs simple-mtpfs go-mtpfs; do
        if have "$h"; then
            printf '%s\n' "$h"
            return 0
        fi
    done
    return 1
}

# gvfs (desktop) MTP mounts that belong to a Kindle, one path per line.
kindle_gvfs_mounts() {
    local base=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/gvfs d
    [[ -d $base ]] || return 0
    for d in "$base"/mtp:host=*; do
        [[ -d $d ]] || continue
        case "${d,,}" in
            *kindle*|*amazon*|*lab126*|*"${KINDLE_USB_VENDOR,,}"*) printf '%s\n' "$d" ;;
        esac
    done
}

# FUSE Kindle mounts from the mount table, one record per line:
#   HELPER | MOUNTPOINT
# With a path argument, only that mountpoint is considered.
kindle_fuse_mounts() {
    local hint=${1:-} src tgt fstype rest fs=$DEVICES_FS
    while read -r src tgt fstype rest; do
        : "$rest"
        case $fstype in fuse|fuse.*|fuseblk) ;; *) continue ;; esac
        tgt=$(mount_unescape "$tgt")
        case $src in
            jmtpfs|simple-mtpfs|go-mtpfs|*mtpfs*) ;;
            *)
                # Not an MTP helper; only of interest if we were asked about it.
                [[ -n $hint && $tgt == "$hint" ]] || continue
                ;;
        esac
        if [[ -n $hint ]]; then
            [[ $tgt == "$hint" ]] || continue
        else
            case "${tgt,,}" in *kindle*) ;; *) continue ;; esac
        fi
        printf '%s\n' "$src$fs$tgt"
    done < "$DEVICES_MOUNTS"
}

# Human-readable summary of what is attached, for error messages.
kindle_describe_attached() {
    local desc bus dev classes bound
    while IFS=$DEVICES_FS read -r _ _ _ _ desc; do
        [[ -n ${desc:-} ]] && printf '  mass storage: %s\n' "$desc"
    done < <(kindle_ums_devices)
    while IFS=$DEVICES_FS read -r _ bus dev classes bound desc; do
        printf '  usb %s:%s  %s  [interface class %s, %s]\n' \
            "$bus" "$dev" "$desc" "${classes:-none}" \
            "$( (( bound )) && printf 'driver attached' || printf 'no kernel driver' )"
    done < <(kindle_usb_devices)
}
