#!/usr/bin/env bash
#
# printer-print.sh - send a file to the printer.
#
# The companion to printer-find.sh. That one finds a printer and prints a
# device URI; this one prints a file through the queue CUPS already has.
# It is the long-hand form of
#
#   lp -d HP_Smart_Tank_510_series_6E0508_USB -t "fisica.pdf" ~/Downloads/fisica.pdf
#
# with the two things that line hardcodes worked out rather than typed: the
# destination comes from lpstat, and the job title comes from the file.
#
# Why the destination is worth asking for every time: the queue name is not
# stable. CUPS derives it from whatever the printer advertises - model,
# serial, how it is attached - so it changes when the printer is renamed,
# moved from the cable to the wifi, or simply re-added, and the line above
# then fails with "The printer or class does not exist" while the printer
# sits there working. lpstat costs nothing and cannot go stale.
#
# Resolution order for the destination: --dest, then $PRINTER_DEST, then
# the CUPS default destination, then the only queue if there is exactly
# one - which is the common case, and the case this host is in. Several
# queues and no default is the one situation this refuses to guess at.
#
# Nothing here configures anything: no queue is created, no default is
# set, no option is made permanent. It submits a job and reports the id.
#
# stdout carries the job ids and nothing else, so a job can be followed or
# called off:
#
#   cancel "$(printer-print.sh -q report.pdf)"
#
# Note that -n is --dry-run, as everywhere in this suite, and is therefore
# NOT lp's number-of-copies flag; copies are -# / --copies, as in lpr(1).

set -euo pipefail

# shellcheck source-path=SCRIPTDIR/..

_self=${BASH_SOURCE[0]}
_self=$(readlink -f -- "$_self" 2>/dev/null || printf '%s' "$_self")
ROOT_DIR=$(cd -- "$(dirname -- "$_self")/.." && pwd -P)
# shellcheck source=lib/common.sh
. "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/printer.sh
. "$ROOT_DIR/lib/printer.sh"

VERSION=1.0.0
PROG=${0##*/}

DEST=${PRINTER_DEST:-}
TITLE=''
COPIES=1
LIST=0
declare -a OPTS=()
declare -a FILES=()

usage() {
    cat <<EOF
Usage: $PROG [options] FILE...
       $PROG [options] -            # print standard input

Send a file to the printer through the CUPS queue, titling the job after
the file. One job per file.

With no --dest, the destination is \$PRINTER_DEST, else the CUPS default,
else the only queue there is.

Options:
  -d, --dest QUEUE       print to this queue (default: as resolved above)
  -t, --title TEXT       job title (default: the file's name)
  -#, --copies N         number of copies (lp's -n is --dry-run here)
  -o, --option K=V       pass an option to lp, repeatable
                         (sides=two-sided-long-edge, fit-to-page, ...)
  -2, --two-sided        shorthand for -o sides=two-sided-long-edge
  -m, --media SIZE       shorthand for -o media=SIZE (A4, Letter, ...)
  -P, --pages RANGE      shorthand for -o page-ranges=RANGE (1-4,7)
  -R, --raw              send the file through untouched, no filtering
  -L, --list             list the queues and what they are doing, then exit
  -n, --dry-run          print the lp command instead of running it
  -q, --quiet            print only the job ids
  -h, --help             this help
  -V, --version          version

Exit codes:
  0 job submitted                       2 bad usage
  1 the printing system refused it      3 no queue to print to

Examples:
  $PROG ~/Downloads/fisica.pdf             # title: fisica.pdf
  $PROG -L                                 # what can I print to?
  $PROG -2 -m A4 report.pdf                # duplex, A4
  $PROG -d office -# 3 -P 1-4 notes.pdf    # 3 copies of pages 1-4
  $PROG -n *.pdf                           # what would be submitted
  cancel "\$($PROG -q report.pdf)"          # submit, then call it off
EOF
}

# shellcheck disable=SC2034  # QUIET and DRY_RUN are read by lib/common.sh
while (( $# )); do
    case $1 in
        -d|--dest)      [[ ${2:-} ]] || die -"$EX_USAGE" "$1 needs a queue name"; DEST=$2; shift 2 ;;
        -t|--title)     [[ ${2:-} ]] || die -"$EX_USAGE" "$1 needs a title"; TITLE=$2; shift 2 ;;
        -#|--copies)    [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || die -"$EX_USAGE" "$1 needs a positive number"; COPIES=$2; shift 2 ;;
        -o|--option)    [[ ${2:-} ]] || die -"$EX_USAGE" "$1 needs an option"; OPTS+=("$2"); shift 2 ;;
        -2|--two-sided) OPTS+=(sides=two-sided-long-edge); shift ;;
        -m|--media)     [[ ${2:-} ]] || die -"$EX_USAGE" "$1 needs a media size"; OPTS+=("media=$2"); shift 2 ;;
        -P|--pages)     [[ ${2:-} ]] || die -"$EX_USAGE" "$1 needs a page range"; OPTS+=("page-ranges=$2"); shift 2 ;;
        -R|--raw)       OPTS+=(raw); shift ;;
        -L|--list)      LIST=1; shift ;;
        -n|--dry-run)   DRY_RUN=1; shift ;;
        -q|--quiet)     QUIET=1; shift ;;
        -h|--help)      usage; exit "$EX_OK" ;;
        -V|--version)   printf '%s %s\n' "$PROG" "$VERSION"; exit "$EX_OK" ;;
        --)             shift; FILES+=("$@"); break ;;
        -)              FILES+=(-); shift ;;
        -*)             usage >&2; die -"$EX_USAGE" "unknown option: $1" ;;
        *)              FILES+=("$1"); shift ;;
    esac
done

# ------------------------------------------------------------------ queues

# Every queue with its state, one record per line:
#   name<FS>uri<FS>state<FS>accepting<FS>description
queue_records() {
    local qname quri state
    while IFS=$DEVICES_FS read -r qname quri; do
        if state=$(printer_queue_state "$qname"); then
            printf '%s\n' "$qname$DEVICES_FS$quri$DEVICES_FS$state"
        else
            printf '%s\n' "$qname$DEVICES_FS$quri${DEVICES_FS}unknown${DEVICES_FS}true$DEVICES_FS"
        fi
    done < <(printer_cups_queues)
}

# Why there is nothing to print to. Every cause below leaves lpstat silent
# and only one of them is the user's to fix, so they are told apart here
# rather than reported as "no printer".
no_queues() {
    if ! have lpstat; then
        err "no printing system found"
        info "install the CUPS client tools: sudo apt install cups-client"
    elif ! printer_cups_running; then
        err "CUPS is not running, so the host has no queues"
        info "start it: sudo systemctl start cups"
    else
        err "no CUPS queue is configured"
        info "find the printer first: $ROOT_DIR/printer/printer-find.sh"
        info "then add a queue:       lpadmin -p office -E -v URI -m everywhere"
    fi
    exit "$EX_NODEV"
}

if (( LIST )); then
    found=0
    while IFS=$DEVICES_FS read -r qname quri qstate qaccept qdesc; do
        found=1
        : "$qdesc"
        printf '%s\n' "$qname"
        info "  state      $qstate$([[ $qaccept == true ]] && printf ', accepting jobs' || printf ', NOT accepting jobs')"
        info "  device     $quri"
    done < <(queue_records)
    (( found )) || no_queues
    exit "$EX_OK"
fi

(( ${#FILES[@]} )) || { usage >&2; die -"$EX_USAGE" "no file to print"; }
(( ${#FILES[@]} > 1 )) && [[ -n $TITLE ]] && \
    die -"$EX_USAGE" "--title names one job; drop it to title each job after its file"

for f in "${FILES[@]}"; do
    [[ $f == - ]] && continue
    [[ -e $f ]] || die -"$EX_USAGE" "no such file: $f"
    [[ -d $f ]] && die -"$EX_USAGE" "that is a directory: $f"
    [[ -r $f ]] || die -"$EX_USAGE" "cannot read: $f"
    [[ -s $f ]] || die -"$EX_USAGE" "file is empty: $f"
done

# ------------------------------------------------------------ destination

# Which queue, when none was named. The useful distinction is not how many
# queues exist but how many can take a job: a host collects queues it is
# not printing to - a printer re-added over the wifi, an old one left
# behind - and those sit there disabled and refusing jobs. So a single
# queue that is accepting is not a guess, and it is announced either way.
# A default destination can outlive the queue it names: the queue is
# removed and the default is left pointing at nothing, which is the state
# this host is in. That must not veto a working printer - so a *named*
# destination is honoured or refused, while an inferred one that does not
# exist is reported and dropped, and resolution carries on without it.
if [[ -z $DEST ]]; then
    if DEST=$(printer_cups_default) && have lpstat \
       && ! printer_queue_state "$DEST" >/dev/null 2>&1; then
        warn "the CUPS default destination $DEST no longer exists; ignoring it"
        info "point it somewhere real with: lpoptions -d NAME"
        DEST=''
    fi
fi

if [[ -z $DEST ]]; then
    count=0 sole='' live=0 live_name=''
    while IFS=$DEVICES_FS read -r qname _ qstate qaccept _; do
        count=$(( count + 1 ))
        sole=$qname
        [[ $qaccept == true && $qstate != disabled && $qstate != stopped ]] || continue
        live=$(( live + 1 ))
        live_name=$qname
    done < <(queue_records)

    if (( count == 0 )); then
        no_queues
    elif (( count == 1 )); then
        DEST=$sole
        info "printing to $DEST, the only queue on this host"
    elif (( live == 1 )); then
        DEST=$live_name
        info "printing to $DEST, the only queue of $count that is taking jobs"
    else
        if (( live )); then
            err "$live of $count queues are taking jobs, and none is the default: which one?"
        else
            err "none of the $count queues on this host is taking jobs"
        fi
        info "pass --dest NAME, or set a default with: lpoptions -d NAME"
        while IFS=$DEVICES_FS read -r qname _ qstate qaccept _; do
            info "  $qname  ($qstate$([[ $qaccept == true ]] && printf ', accepting' || printf ', not accepting'))"
        done < <(queue_records)
        exit "$EX_USAGE"
    fi
fi

if have lpstat; then
    if qstate=$(printer_queue_state "$DEST"); then
        IFS=$DEVICES_FS read -r state accepting desc <<<"$qstate"
        if [[ $accepting != true ]]; then
            err "queue $DEST is not accepting jobs, so this would be refused"
            info "$desc"
            info "let it take jobs again: sudo cupsaccept $DEST"
            exit "$EX_FAIL"
        fi
        # A disabled queue still takes the job and holds it. That is a
        # legitimate thing to want, so this warns and carries on rather
        # than refusing - but it must not be reported as printed.
        if [[ $state == disabled || $state == stopped ]]; then
            warn "queue $DEST is $state: the job will wait until it is enabled"
            info "$desc"
            info "enable it: sudo cupsenable $DEST"
        fi
    else
        err "no queue named $DEST"
        info "the queues on this host are:"
        while IFS=$DEVICES_FS read -r qname _; do
            info "  $qname"
        done < <(printer_cups_queues)
        info "list them with their state: $PROG -L"
        exit "$EX_NODEV"
    fi
fi

# ------------------------------------------------------------- submission

# lp and lpr are the same job through different spellings. lp is preferred
# because it reports the job id back; lpr is accepted because a host can
# have it and not the other, and then saying "no printing system" would be
# a lie.
if have lp; then
    SUBMIT='lp'
elif have lpr; then
    SUBMIT='lpr'
    info "lp not found; submitting with lpr, which reports no job id"
else
    err "neither lp nor lpr is installed, so nothing can be submitted"
    info "install the CUPS client tools: sudo apt install cups-client"
    exit "$EX_FAIL"
fi

submit() {
    local file=$1 title=$2 opt
    local -a cmd=()

    # A leading dash would be read as an option by lp, which has no --.
    [[ $file == -* && $file != - ]] && file=./$file

    if [[ $SUBMIT == lp ]]; then
        cmd=(lp -d "$DEST" -t "$title")
        (( COPIES > 1 )) && cmd+=(-n "$COPIES")
        for opt in "${OPTS[@]+"${OPTS[@]}"}"; do cmd+=(-o "$opt"); done
        [[ $file == - ]] || cmd+=("$file")
    else
        cmd=(lpr -P "$DEST" -T "$title")
        (( COPIES > 1 )) && cmd+=("-#$COPIES")
        for opt in "${OPTS[@]+"${OPTS[@]}"}"; do cmd+=(-o "$opt"); done
        [[ $file == - ]] || cmd+=("$file")
    fi

    run "${cmd[@]}"
}

rc=0
for f in "${FILES[@]}"; do
    if [[ -n $TITLE ]]; then
        title=$TITLE
    elif [[ $f == - ]]; then
        title=stdin
    else
        title=${f##*/}
    fi

    if ! out=$(submit "$f" "$title"); then
        err "the printing system refused ${f##*/}"
        rc=$EX_FAIL
        continue
    fi

    # "request id is NAME-42 (1 file(s))" - the id is all stdout is for.
    job=''
    [[ $out =~ request[[:space:]]id[[:space:]]is[[:space:]]+([^[:space:]]+) ]] && job=${BASH_REMATCH[1]}

    ok "$(verb send sent) \"$title\" to $DEST${job:+ as job $job}"
    [[ -n $job ]] && printf '%s\n' "$job"
done

exit "$rc"
