#!/usr/bin/env bash
# Shared helpers for the devices script suite.
# Source this file, do not execute it.
#
#   . "$ROOT_DIR/lib/common.sh"
#
# Honours: QUIET=1, DRY_RUN=1, DEVICES_DEBUG=1, NO_COLOR=1

# shellcheck shell=bash

[[ -n ${_DEVICES_COMMON_SOURCED:-} ]] && return 0
_DEVICES_COMMON_SOURCED=1

if [[ -z ${BASH_VERSINFO[0]:-} ]] || (( BASH_VERSINFO[0] < 4 )) \
   || { (( BASH_VERSINFO[0] == 4 )) && (( BASH_VERSINFO[1] < 2 )); }; then
    printf 'error: bash 4.2 or newer is required\n' >&2
    exit 1
fi

# shellcheck disable=SC2034  # consumed by the scripts that source this file
DEVICES_LIB_VERSION=1.0.0

# Exit codes used across the suite:
#   0 success   1 failure   2 bad usage   3 no such device   4 device busy
# shellcheck disable=SC2034  # consumed by the scripts that source this file
EX_OK=0 EX_FAIL=1 EX_USAGE=2 EX_NODEV=3 EX_BUSY=4

QUIET=${QUIET:-0}
DRY_RUN=${DRY_RUN:-0}

if [[ -t 2 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
    C_RESET=$'\033[0m'
    C_RED=$'\033[31m'
    C_YELLOW=$'\033[33m'
    C_GREEN=$'\033[32m'
    C_DIM=$'\033[2m'
else
    C_RESET='' C_RED='' C_YELLOW='' C_GREEN='' C_DIM=''
fi

# Diagnostics go to stderr so stdout stays machine-readable.
info()  { (( QUIET )) || printf '%s\n' "$*" >&2; }
ok()    { (( QUIET )) || printf '%s%s%s\n' "$C_GREEN" "$*" "$C_RESET" >&2; }
warn()  { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()   { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()   { local code=$EX_FAIL; [[ $1 == -[0-9]* ]] && { code=${1#-}; shift; }; err "$*"; exit "$code"; }
debug() { [[ -n ${DEVICES_DEBUG:-} ]] && printf '%s+ %s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; return 0; }

have() { command -v -- "$1" >/dev/null 2>&1; }

# Render a command so it can be copied into a shell.
quote_cmd() {
    local out='' arg
    for arg; do
        printf -v arg '%q' "$arg" 2>/dev/null || arg=$(printf '%q' "$arg")
        out+="${out:+ }$arg"
    done
    printf '%s' "$out"
}

# Run a command, respecting DRY_RUN.
run() {
    if (( DRY_RUN )); then
        printf '%swould run:%s %s\n' "$C_DIM" "$C_RESET" "$(quote_cmd "$@")" >&2
        return 0
    fi
    debug "$(quote_cmd "$@")"
    "$@"
}

# Run a command with root privileges, escalating only when needed.
as_root() {
    if (( EUID == 0 )); then
        run "$@"
    elif have sudo; then
        run sudo -- "$@"
    else
        die "root privileges are required for: $(quote_cmd "$@")"
    fi
}

# Field separator for the record lines the device helpers print. A unit
# separator rather than a tab: IFS treats tab as whitespace, which collapses
# runs of them and so loses empty fields - and an unmounted device has an
# empty mountpoint field.
# shellcheck disable=SC2034  # consumed by the scripts that source this file
DEVICES_FS=$'\x1f'

# The table of current mounts; overridable so this can be tested.
DEVICES_MOUNTS=${DEVICES_MOUNTS:-/proc/self/mounts}

# Absolute path with any trailing slash removed - except for "/" itself,
# which must not be stripped down to the empty string.
normalize_path() {
    local path=$1
    path=$(readlink -f -- "$path" 2>/dev/null) || path=$1
    [[ $path == / ]] || path=${path%/}
    printf '%s' "$path"
}

# "mounted" on a real run, "would mount" on a dry run, so the report never
# claims something that did not happen.
verb() {
    if (( DRY_RUN )); then
        printf 'would %s' "$1"
    else
        printf '%s' "$2"
    fi
}

# /proc/self/mounts escapes space, tab, newline and backslash as octal.
mount_unescape() { printf '%b' "$1"; }

# First mountpoint of a block device, if any.
device_mountpoint() {
    local want=$1 real src tgt
    real=$(readlink -f -- "$want" 2>/dev/null) || real=$want
    while read -r src tgt _; do
        [[ $src == /dev/* ]] || continue
        if [[ $src != "$real" ]]; then
            [[ $(readlink -f -- "$src" 2>/dev/null) == "$real" ]] || continue
        fi
        mount_unescape "$tgt"
        return 0
    done < "$DEVICES_MOUNTS"
    return 1
}

# True when the given path is a mountpoint.
is_mountpoint() {
    local want=$1 src tgt
    want=${want%/}
    [[ -n $want ]] || want=/
    while read -r src tgt _; do
        [[ $(mount_unescape "$tgt") == "$want" ]] && return 0
    done < "$DEVICES_MOUNTS"
    return 1
}

# Who is holding a mountpoint open, best effort.
report_blockers() {
    local mp=$1
    if have fuser; then
        fuser -vm -- "$mp" >&2 2>&1 || true
    elif have lsof; then
        lsof +D "$mp" >&2 2>&1 || true
    else
        warn "install psmisc (fuser) or lsof to see what is holding $mp open"
    fi
}

# Flush pending writes before any unmount; a Kindle corrupts easily otherwise.
sync_disks() {
    if (( DRY_RUN )); then
        printf '%swould run:%s sync\n' "$C_DIM" "$C_RESET" >&2
        return 0
    fi
    debug sync
    sync
}
