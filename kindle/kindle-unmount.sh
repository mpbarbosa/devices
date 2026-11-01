#!/usr/bin/env bash
#
# kindle-unmount.sh - flush and unmount a Kindle, optionally powering it off.
#
# Finds whatever this suite (or the desktop) mounted: a mass-storage
# partition, a jmtpfs/simple-mtpfs FUSE mount, or a gvfs MTP mount.
# Always syncs first - a Kindle pulled mid-write loses its library index.

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

TARGET=''
ALL=0
EJECT=0
FORCE=0

usage() {
    cat <<EOF
Usage: $PROG [options] [mountpoint]

Unmount a Kindle that this suite or the desktop mounted.

Options:
  -m, --mountpoint DIR   Unmount this path (same as the positional argument)
  -a, --all              Unmount every Kindle found instead of refusing
                         when there is more than one
  -e, --eject            After unmounting a mass-storage Kindle, power the
                         USB disk down so it is safe to unplug
  -f, --force            Fall back to a lazy unmount when the filesystem is
                         busy; the mount detaches once the last user closes it
  -l, --label LABEL      Filesystem label to look for (default: $KINDLE_LABEL)
  -n, --dry-run          Print what would happen, change nothing
  -q, --quiet            Stay silent unless something goes wrong
  -h, --help             This help
  -V, --version          Version

Exit codes:
  0 unmounted, or nothing was mounted   2 bad usage
  1 failure                             4 busy (something has files open)

Examples:
  $PROG            # find it and unmount it
  $PROG -e         # unmount and power off, ready to unplug
  $PROG -a -f      # unmount everything, lazily if busy
EOF
}

# shellcheck disable=SC2034  # QUIET and DRY_RUN are read by lib/common.sh
while (( $# )); do
    case $1 in
        -m|--mountpoint) [[ ${2:-} ]] || die -"$EX_USAGE" "$1 needs a directory"; TARGET=$2; shift 2 ;;
        -l|--label)      [[ ${2:-} ]] || die -"$EX_USAGE" "$1 needs a label"; KINDLE_LABEL=$2; shift 2 ;;
        -a|--all)        ALL=1; shift ;;
        -e|--eject)      EJECT=1; shift ;;
        -f|--force)      FORCE=1; shift ;;
        -n|--dry-run)    DRY_RUN=1; shift ;;
        -q|--quiet)      QUIET=1; shift ;;
        -h|--help)       usage; exit "$EX_OK" ;;
        -V|--version)    printf '%s %s\n' "$PROG" "$VERSION"; exit "$EX_OK" ;;
        --)              shift; break ;;
        -*)              usage >&2; die -"$EX_USAGE" "unknown option: $1" ;;
        *)               break ;;
    esac
done

if (( $# )); then
    [[ -z $TARGET ]] || die -"$EX_USAGE" "mountpoint given twice"
    TARGET=$1
    shift
    (( $# )) && die -"$EX_USAGE" "unexpected argument: $1"
fi

if [[ -n $TARGET ]]; then
    TARGET=$(normalize_path "$TARGET")
fi

# ------------------------------------------------------------------ targets
# Each target is one record:  KIND | MOUNTPOINT | SOURCE

collect_targets() {
    local dev label fstype mp desc helper gvfs

    while IFS=$DEVICES_FS read -r dev label fstype mp desc; do
        : "$label" "$fstype" "$desc"
        [[ -n $mp ]] || continue
        printf '%s\n' "ums$DEVICES_FS$mp$DEVICES_FS$dev"
    done < <(kindle_ums_devices)

    while IFS=$DEVICES_FS read -r helper mp; do
        printf '%s\n' "fuse$DEVICES_FS$mp$DEVICES_FS$helper"
    done < <(kindle_fuse_mounts "$TARGET")

    while read -r gvfs; do
        printf '%s\n' "gvfs$DEVICES_FS$gvfs${DEVICES_FS}gvfs"
    done < <(kindle_gvfs_mounts)
}

mapfile -t TARGETS < <(collect_targets)

if [[ -n $TARGET ]]; then
    mapfile -t TARGETS < <(
        for line in "${TARGETS[@]:-}"; do
            [[ -n $line ]] || continue
            IFS=$DEVICES_FS read -r _ mp _ <<<"$line"
            [[ $(normalize_path "$mp") == "$TARGET" ]] && printf '%s\n' "$line"
        done
    )
    if (( ${#TARGETS[@]} == 0 )); then
        is_mountpoint "$TARGET" \
            && die "$TARGET is mounted, but it does not look like a Kindle"
        info "nothing mounted at $TARGET"
        exit "$EX_OK"
    fi
fi

if (( ${#TARGETS[@]} == 0 )); then
    info "no mounted Kindle found, nothing to do"
    exit "$EX_OK"
fi

if (( ${#TARGETS[@]} > 1 && ! ALL )); then
    err "more than one Kindle mount found:"
    for line in "${TARGETS[@]}"; do
        IFS=$DEVICES_FS read -r kind mp src <<<"$line"
        printf '  %-4s %s (%s)\n' "$kind" "$mp" "$src" >&2
    done
    die "pass --all, or name one of the mountpoints above"
fi

# ---------------------------------------------------------------- unmounting

sync_disks

unmount_ums() {
    local mp=$1 dev=$2

    if (( EUID != 0 )) && have udisksctl; then
        if run udisksctl unmount --no-user-interaction --block-device "$dev"; then
            ok "$(verb unmount unmounted) $dev ($mp)"
            return 0
        fi
        warn "udisksctl could not unmount $dev, trying umount(8)"
    fi

    if as_root umount -- "$mp"; then
        ok "$(verb unmount unmounted) $dev ($mp)"
        return 0
    fi

    err "$mp is busy"
    report_blockers "$mp"
    if (( FORCE )); then
        warn "detaching lazily; the mount disappears once the last user closes it"
        as_root umount --lazy -- "$mp" || return "$EX_FAIL"
        ok "$(verb "lazily unmount" "lazily unmounted") $mp - do not unplug until it is really released"
        return 0
    fi
    info "close anything using $mp, or re-run with --force"
    return "$EX_BUSY"
}

unmount_fuse() {
    local mp=$1 helper=$2
    local -a unmounter=()

    if have fusermount3; then
        unmounter=(fusermount3 -u --)
    elif have fusermount; then
        unmounter=(fusermount -u --)
    fi

    if (( ${#unmounter[@]} )) && run "${unmounter[@]}" "$mp"; then
        ok "$(verb unmount unmounted) $helper at $mp"
        return 0
    fi

    if as_root umount -- "$mp"; then
        ok "$(verb unmount unmounted) $helper at $mp"
        return 0
    fi

    err "$mp is busy"
    report_blockers "$mp"
    if (( FORCE )); then
        warn "detaching lazily; the mount disappears once the last user closes it"
        if (( ${#unmounter[@]} )); then
            run "${unmounter[0]}" -u -z -- "$mp" && { ok "$(verb "lazily unmount" "lazily unmounted") $mp"; return 0; }
        fi
        as_root umount --lazy -- "$mp" && { ok "$(verb "lazily unmount" "lazily unmounted") $mp"; return 0; }
    fi
    info "close anything using $mp, or re-run with --force"
    return "$EX_BUSY"
}

unmount_gvfs() {
    local mp=$1
    if have gio; then
        if run gio mount --unmount "$mp"; then
            ok "$(verb unmount unmounted) the gvfs MTP mount at $mp"
            return 0
        fi
        if run gio mount --unmount-scheme=mtp; then
            ok "$(verb unmount unmounted) all gvfs MTP mounts"
            return 0
        fi
    fi
    err "could not unmount the gvfs mount at $mp"
    info "unmount it from the desktop file manager instead"
    return "$EX_FAIL"
}

eject_disk() {
    local dev=$1 disk
    have udisksctl || { warn "udisksctl not installed, skipping --eject"; return 0; }
    disk=$(kindle_parent_disk "$dev" || printf '%s' "$dev")
    if run udisksctl power-off --no-user-interaction --block-device "$disk"; then
        ok "$disk $(verb "power off" "powered off"), safe to unplug"
    else
        warn "could not power off $disk; it is unmounted, so unplugging is still safe"
    fi
}

status="$EX_OK"
for line in "${TARGETS[@]}"; do
    IFS=$DEVICES_FS read -r kind mp src <<<"$line"
    rc=0
    case $kind in
        ums)  unmount_ums  "$mp" "$src" || rc=$? ;;
        fuse) unmount_fuse "$mp" "$src" || rc=$? ;;
        gvfs) unmount_gvfs "$mp"        || rc=$? ;;
        *)    err "unknown mount kind: $kind"; rc="$EX_FAIL" ;;
    esac
    if (( rc )); then
        status=$rc
        continue
    fi
    if (( EJECT )) && [[ $kind == ums ]]; then
        eject_disk "$src"
    fi
done

exit "$status"
