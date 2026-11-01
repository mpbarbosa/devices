#!/usr/bin/env bash
#
# kindle-mount.sh - mount a Kindle connected over USB.
#
# Handles both kinds of Kindle: a mass-storage model appears as a vfat
# partition and is mounted through udisks (no root needed) or mount(8);
# an MTP model (Scribe, Colorsoft, Paperwhite 2024+) is mounted with a
# FUSE helper such as jmtpfs or simple-mtpfs.
#
# On success the mountpoint is printed on stdout; everything else goes
# to stderr, so this is safe to use as:  cd "$(kindle-mount.sh -q)"

set -euo pipefail

# shellcheck source-path=SCRIPTDIR/..

_self=${BASH_SOURCE[0]}
_self=$(readlink -f -- "$_self" 2>/dev/null || printf '%s' "$_self")
ROOT_DIR=$(cd -- "$(dirname -- "$_self")/.." && pwd -P)
# shellcheck source=lib/common.sh
. "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/kindle.sh
. "$ROOT_DIR/lib/kindle.sh"

VERSION=1.0.0
PROG=${0##*/}

MOUNTPOINT=${KINDLE_MOUNTPOINT:-}
KIND=auto
READ_ONLY=0
EXTRA_OPTS=${KINDLE_MOUNT_OPTIONS:-}
WAIT_SECS=0
LOAD_MODULE=0

usage() {
    cat <<EOF
Usage: $PROG [options]

Mount a USB-connected Kindle and print its mountpoint.

Options:
  -m, --mountpoint DIR   Mount here instead of the default
                         (mass storage: /media/\$USER/<label>, via udisks;
                          MTP: \$XDG_RUNTIME_DIR/kindle)
  -t, --type KIND        auto (default), ums (mass storage) or mtp
  -l, --label LABEL      Filesystem label to look for (default: $KINDLE_LABEL)
  -o, --options OPTS     Extra mount options, mass storage only
  -r, --read-only        Mount read-only
  -w, --wait SECONDS     Wait up to SECONDS for the Kindle to show up
  -M, --modprobe         Load the usb-storage kernel module if a mass-storage
                         Kindle is attached but the kernel has not claimed it
  -n, --dry-run          Print what would happen, change nothing
  -q, --quiet            Only print the mountpoint
  -h, --help             This help
  -V, --version          Version

Environment:
  KINDLE_MOUNTPOINT, KINDLE_LABEL, KINDLE_MOUNT_OPTIONS, NO_COLOR, DEVICES_DEBUG

Exit codes:
  0 mounted (or already mounted)   2 bad usage
  1 failure                        3 no Kindle found

Examples:
  $PROG                       # find and mount whatever is attached
  $PROG -w 30                 # plug the cable in, then wait for it
  $PROG -m ~/mnt/kindle -r    # read-only at a fixed path
  $PROG -M                    # load usb-storage first if the kernel needs it
  cp book.epub "\$($PROG -q)/documents/"
EOF
}

# shellcheck disable=SC2034  # QUIET and DRY_RUN are read by lib/common.sh
while (( $# )); do
    case $1 in
        -m|--mountpoint) [[ ${2:-} ]] || die -"$EX_USAGE" "$1 needs a directory"; MOUNTPOINT=$2; shift 2 ;;
        -t|--type)       [[ ${2:-} ]] || die -"$EX_USAGE" "$1 needs auto, ums or mtp"; KIND=$2; shift 2 ;;
        -l|--label)      [[ ${2:-} ]] || die -"$EX_USAGE" "$1 needs a label"; KINDLE_LABEL=$2; shift 2 ;;
        -o|--options)    [[ ${2:-} ]] || die -"$EX_USAGE" "$1 needs mount options"; EXTRA_OPTS=$2; shift 2 ;;
        -w|--wait)       [[ ${2:-} =~ ^[0-9]+$ ]] || die -"$EX_USAGE" "$1 needs a number of seconds"; WAIT_SECS=$2; shift 2 ;;
        -r|--read-only)  READ_ONLY=1; shift ;;
        -M|--modprobe)   LOAD_MODULE=1; shift ;;
        -n|--dry-run)    DRY_RUN=1; shift ;;
        -q|--quiet)      QUIET=1; shift ;;
        -h|--help)       usage; exit "$EX_OK" ;;
        -V|--version)    printf '%s %s\n' "$PROG" "$VERSION"; exit "$EX_OK" ;;
        --)              shift; break ;;
        -*)              usage >&2; die -"$EX_USAGE" "unknown option: $1" ;;
        *)               usage >&2; die -"$EX_USAGE" "unexpected argument: $1" ;;
    esac
done

case $KIND in
    auto|ums|mtp) ;;
    *) die -"$EX_USAGE" "--type must be auto, ums or mtp (got: $KIND)" ;;
esac

# ---------------------------------------------------------------- detection

UMS_LINE='' MTP_LINE=''

probe() {
    UMS_LINE='' MTP_LINE=''
    if [[ $KIND == auto || $KIND == ums ]]; then
        UMS_LINE=$(kindle_ums_devices | head -n1)
    fi
    if [[ -z $UMS_LINE && ( $KIND == auto || $KIND == mtp ) ]]; then
        MTP_LINE=$(kindle_mtp_devices | head -n1)
    fi
    [[ -n $UMS_LINE || -n $MTP_LINE ]]
}

wait_for_kindle() {
    local deadline=$(( SECONDS + WAIT_SECS ))
    probe && return 0
    (( WAIT_SECS )) || return 1
    info "waiting up to ${WAIT_SECS}s for a Kindle..."
    while (( SECONDS < deadline )); do
        sleep 1
        probe && return 0
    done
    return 1
}

# A mass-storage Kindle with no kernel driver attached is usually just a
# missing usb-storage module - nothing else is wrong with it.
try_modprobe() {
    local line
    line=$(kindle_ums_usb_devices | head -n1)
    [[ -n $line ]] || return 1
    kindle_usb_storage_loaded && return 1

    info "usb-storage is not loaded; loading it so the Kindle can appear"
    as_root modprobe usb-storage || return 1
    (( DRY_RUN )) && return 1

    local i
    for i in $(seq 1 20); do
        probe && return 0
        sleep 0.5
    done
    return 1
}

diagnose_and_exit() {
    local attached ums_usb mtp_usb bound
    err "no Kindle filesystem found"

    attached=$(kindle_describe_attached)
    if [[ -n $attached ]]; then
        info "USB devices that look like a Kindle:"
        printf '%s\n' "$attached" >&2
    fi

    ums_usb=$(kindle_ums_usb_devices | head -n1)
    mtp_usb=$(kindle_mtp_devices | head -n1)

    if [[ -n $ums_usb ]]; then
        IFS=$DEVICES_FS read -r _ _ _ bound _ <<<"$ums_usb"
        if (( ! bound )) && ! kindle_usb_storage_loaded; then
            cat >&2 <<EOF

The Kindle offers USB mass storage, but the kernel's usb-storage driver is
not loaded, so no block device was ever created. Load it and try again:

    sudo modprobe usb-storage
    $PROG

Or let this script do it:  $PROG --modprobe
To survive reboots:        echo usb-storage | sudo tee /etc/modules-load.d/usb-storage.conf
EOF
        elif (( ! bound )); then
            cat >&2 <<'EOF'

The Kindle is on the bus but no kernel driver claimed it. Usually that means
the Kindle itself has not switched into drive mode: wake it, unlock it, and
check that its screen says it is connected to a computer. A charge-only cable
looks identical to a data cable and behaves exactly like this.
EOF
        else
            cat >&2 <<'EOF'

The kernel claimed the Kindle but exposed no usable filesystem. Check the
Kindle screen - it may be asking you to confirm the connection - and look for
I/O errors with:  journalctl -k -b | tail -30
EOF
        fi
    elif [[ -n $mtp_usb ]]; then
        cat >&2 <<'EOF'

The Kindle speaks MTP, so it needs a FUSE helper:
    sudo apt install jmtpfs        # Debian/Ubuntu
    sudo dnf install simple-mtpfs  # Fedora
EOF
    else
        cat >&2 <<'EOF'

Nothing that looks like a Kindle is attached. Worth checking:
  * the cable carries data, not just power
  * the Kindle is awake and its screen shows the computer connection
  * a newer Kindle (Scribe, Colorsoft, Paperwhite 2024+) speaks MTP and needs
    jmtpfs or simple-mtpfs installed
  * run with DEVICES_DEBUG=1 to see what was probed
EOF
    fi
    exit "$EX_NODEV"
}

if ! wait_for_kindle; then
    if (( LOAD_MODULE )); then
        try_modprobe || diagnose_and_exit
    else
        diagnose_and_exit
    fi
fi

# ------------------------------------------------------------- mass storage

mount_ums() {
    local dev label fstype mp desc
    IFS=$DEVICES_FS read -r dev label fstype mp desc <<<"$UMS_LINE"

    info "found ${desc:-Kindle} at $dev${label:+ (label: $label)}"

    if [[ -n $mp ]]; then
        ok "already mounted at $mp"
        printf '%s\n' "$mp"
        return 0
    fi

    # udisks mounts under /media/$USER without root; prefer it when the
    # caller did not insist on a specific path.
    if [[ -z $MOUNTPOINT ]] && have udisksctl && (( EUID != 0 )); then
        local -a cmd=(udisksctl mount --no-user-interaction --block-device "$dev")
        (( READ_ONLY )) && cmd+=(--options ro)
        [[ -n $EXTRA_OPTS ]] && warn "--options is ignored when mounting through udisks"
        if (( DRY_RUN )); then
            run "${cmd[@]}"
            printf '/media/%s/%s\n' "${USER:-$(id -un)}" "${label:-Kindle}"
            return 0
        fi
        local out
        if out=$("${cmd[@]}" 2>&1); then
            debug "$out"
            mp=$(device_mountpoint "$dev" || true)
            if [[ -z $mp ]]; then
                # "Mounted /dev/sdb1 at /media/user/Kindle."
                mp=${out##*" at "}
                mp=${mp%.}
            fi
            ok "mounted at $mp"
            printf '%s\n' "$mp"
            return 0
        fi
        warn "udisksctl could not mount $dev: ${out%%$'\n'*}"
        info "falling back to mount(8)"
    fi

    mp=${MOUNTPOINT:-/media/${USER:-$(id -un)}/${label:-Kindle}}

    if is_mountpoint "$mp"; then
        die "$mp is already in use by another filesystem"
    fi

    local opts uid gid
    uid=$(id -u)
    gid=$(id -g)
    opts="noatime,flush,uid=$uid,gid=$gid,fmask=0133,dmask=0022,iocharset=utf8,shortname=mixed"
    (( READ_ONLY )) && opts+=",ro" || opts+=",rw"
    [[ -n $EXTRA_OPTS ]] && opts+=",$EXTRA_OPTS"
    # Those options are vfat-specific; a non-vfat Kindle gets plain defaults.
    case $fstype in
        vfat|msdos|exfat|auto|'') ;;
        *) opts="noatime"; (( READ_ONLY )) && opts+=",ro" || opts+=",rw"
           [[ -n $EXTRA_OPTS ]] && opts+=",$EXTRA_OPTS" ;;
    esac

    if [[ ! -d $mp ]]; then
        if [[ -w $(dirname -- "$mp") ]]; then
            run mkdir -p -- "$mp"
        else
            as_root mkdir -p -- "$mp"
        fi
    fi

    as_root mount -t "${fstype:-auto}" -o "$opts" -- "$dev" "$mp"
    ok "$(verb mount mounted) $dev at $mp"
    printf '%s\n' "$mp"
}

# ---------------------------------------------------------------------- MTP

mount_mtp() {
    local bus dev sys desc helper mp
    IFS=$DEVICES_FS read -r bus dev sys desc <<<"$MTP_LINE"
    : "$sys"
    info "found ${desc:-Kindle} on usb $bus:$dev (MTP, no block device)"

    # The desktop may already have it mounted through gvfs.
    local gvfs
    gvfs=$(kindle_gvfs_mounts | head -n1)
    if [[ -n $gvfs && -z $MOUNTPOINT ]]; then
        ok "already mounted by gvfs at $gvfs"
        printf '%s\n' "$gvfs"
        return 0
    fi

    if ! helper=$(kindle_mtp_helper); then
        err "no MTP helper installed (looked for jmtpfs, simple-mtpfs, go-mtpfs)"
        cat >&2 <<'EOF'
Install one of them, then run this again:
    sudo apt install jmtpfs        # Debian/Ubuntu
    sudo dnf install simple-mtpfs  # Fedora
    sudo pacman -S jmtpfs          # Arch
Alternatively, let your desktop mount it and use the gvfs path under
    /run/user/$(id -u)/gvfs/
EOF
        exit "$EX_FAIL"
    fi

    mp=${MOUNTPOINT:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/kindle}

    if is_mountpoint "$mp"; then
        ok "already mounted at $mp"
        printf '%s\n' "$mp"
        return 0
    fi

    run mkdir -p -- "$mp"

    local -a cmd=("$helper")
    (( READ_ONLY )) && cmd+=(-o ro)
    [[ -n $EXTRA_OPTS ]] && warn "--options is ignored for MTP mounts"
    cmd+=("$mp")

    if ! run "${cmd[@]}"; then
        err "$helper failed to mount the Kindle at $mp"
        info "if the desktop already claimed the device, try: gio mount -s mtp"
        exit "$EX_FAIL"
    fi

    ok "$(verb "mount via $helper" "mounted via $helper") at $mp"
    printf '%s\n' "$mp"
}

if [[ -n $UMS_LINE ]]; then
    mount_ums
else
    mount_mtp
fi
