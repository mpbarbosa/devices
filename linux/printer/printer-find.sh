#!/usr/bin/env bash
#
# printer-find.sh - find a printer, on the cable or on the wifi, HP by default.
#
# Nothing is mounted and nothing is configured: this script only looks. It
# enumerates USB printers, browses mDNS, optionally sweeps the local subnet
# for the printer ports, identifies whatever answered and asks it over IPP
# how it is doing. It changes nothing on the host and nothing on the
# printer, and it never adds a CUPS queue - the URI it prints is what
# lpadmin(8) wants, so adding one stays an explicit act:
#
#   lpadmin -p office -E -v "$(printer-find.sh -q)" -m everywhere
#
# On success the device URI of each printer found is printed on stdout, one
# per line, and everything else goes to stderr.
#
# A USB printer that speaks IPP-over-USB is reported once, not twice:
# ipp-usb republishes it as an IPP service on localhost, so the bus and
# mDNS both see it, and the usb_SER in the TXT record is what proves the
# two records are the same unit.
#
# The failure path matters as much as the success path. A printer that is
# powered off, asleep off-network, on the guest SSID or behind client
# isolation is simply not visible, and "nothing found" on its own is no
# help - so when the search comes up empty the script reports what it did
# see and which of those causes fits.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR/..

_self=${BASH_SOURCE[0]}
_self=$(readlink -f -- "$_self" 2>/dev/null || printf '%s' "$_self")
ROOT_DIR=$(cd -- "$(dirname -- "$_self")/.." && pwd -P)
# shellcheck source=lib/common.sh
. "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/printer.sh
. "$ROOT_DIR/lib/printer.sh"

VERSION=1.1.0
PROG=${0##*/}

SCAN=0
MDNS_ONLY=0
NO_USB=0
USB_ONLY=0
ALL=0
WAIT=0

usage() {
    cat <<EOF
Usage: $PROG [options]

Find a printer and print its CUPS device URI on stdout.

Looks on the USB bus first, then over mDNS, then - only if those found
nothing - sweeps the local subnet for printer ports.

Options:
  -U, --usb-only         look on the USB bus only
  -N, --network-only     skip the USB bus
  -M, --mdns-only        browse mDNS only, never sweep
  -s, --scan             sweep the subnet even when something was found
  -S, --subnet CIDR      sweep this block instead of the local subnet
  -p, --ports LIST       ports to probe (default: $PRINTER_PORTS)
  -a, --all              report every printer found, not just HP ones
  -w, --wait SECONDS     keep looking until one appears, or time out
                         (plug it in or wake it, then let this catch it)
  -j, --jobs N           parallel probes during a sweep (default: $PRINTER_JOBS)
  -t, --timeout SECONDS  per-probe timeout (default: $PRINTER_PROBE_TIMEOUT)
  -n, --dry-run          print what would be probed; sweep nothing and
                         ask the printer nothing (the USB bus and mDNS are
                         still read, since both are passive)
  -q, --quiet            print only the URIs
  -h, --help             this help
  -V, --version          version

Exit codes:
  0 at least one printer found          2 bad usage
  1 failure                             3 no printer found

Examples:
  $PROG                                    # cable, then wifi
  $PROG -U                                 # is it on the cable?
  $PROG -a                                 # every printer, any make
  $PROG -w 120                             # plug it in, then wait for it
  $PROG -S 192.168.1.0/24 -s               # sweep another subnet
  lpadmin -p hp -E -v "\$($PROG -q)" -m everywhere
EOF
}

# shellcheck disable=SC2034  # QUIET and DRY_RUN are read by lib/common.sh
while (( $# )); do
    case $1 in
        -U|--usb-only)     USB_ONLY=1; shift ;;
        -N|--network-only) NO_USB=1; shift ;;
        -M|--mdns-only)    MDNS_ONLY=1; shift ;;
        -s|--scan)         SCAN=1; shift ;;
        -a|--all)          ALL=1; shift ;;
        -S|--subnet)       [[ ${2:-} ]] || die -"$EX_USAGE" "$1 needs a CIDR block"; PRINTER_SUBNET=$2; SCAN=1; shift 2 ;;
        -p|--ports)        [[ ${2:-} ]] || die -"$EX_USAGE" "$1 needs a port list"; PRINTER_PORTS=${2//,/ }; shift 2 ;;
        -w|--wait)         [[ ${2:-} =~ ^[0-9]+$ ]] || die -"$EX_USAGE" "$1 needs a number of seconds"; WAIT=$2; shift 2 ;;
        -j|--jobs)         [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || die -"$EX_USAGE" "$1 needs a positive number"; PRINTER_JOBS=$2; shift 2 ;;
        -t|--timeout)      [[ ${2:-} =~ ^[0-9]+$ ]] || die -"$EX_USAGE" "$1 needs a number of seconds"; PRINTER_PROBE_TIMEOUT=$2; shift 2 ;;
        -n|--dry-run)      DRY_RUN=1; shift ;;
        -q|--quiet)        QUIET=1; shift ;;
        -h|--help)         usage; exit "$EX_OK" ;;
        -V|--version)      printf '%s %s\n' "$PROG" "$VERSION"; exit "$EX_OK" ;;
        --)                shift; break ;;
        *)                 usage >&2; die -"$EX_USAGE" "unexpected argument: $1" ;;
    esac
done

(( MDNS_ONLY && SCAN ))    && die -"$EX_USAGE" "--mdns-only and --scan contradict each other"
(( USB_ONLY && NO_USB ))   && die -"$EX_USAGE" "--usb-only and --network-only contradict each other"
(( USB_ONLY && SCAN ))     && die -"$EX_USAGE" "--usb-only and --scan contradict each other"

# ---------------------------------------------------------------- candidates
# One candidate per printer, not one per record: the same unit is normally
# on the bus and on mDNS, and must be reported once. The key is the USB
# serial for a cabled printer and the address for a network one.

declare -A CAND_WHERE CAND_NAME CAND_ADDR CAND_PORTS CAND_RP CAND_HOW
declare -A CAND_MODEL CAND_VENDOR CAND_MAC CAND_SERIAL CAND_PROTOS CAND_USBID
declare -A CAND_URI
declare -a CAND_ORDER=()

# Recreated rather than emptied: bash 4.2 is the floor for this suite and
# `assoc=()` is not dependable that far back, while `declare -gA` is.
reset_candidates() {
    unset CAND_WHERE CAND_NAME CAND_ADDR CAND_PORTS CAND_RP CAND_HOW
    unset CAND_MODEL CAND_VENDOR CAND_MAC CAND_SERIAL CAND_PROTOS CAND_USBID CAND_URI
    declare -gA CAND_WHERE CAND_NAME CAND_ADDR CAND_PORTS CAND_RP CAND_HOW
    declare -gA CAND_MODEL CAND_VENDOR CAND_MAC CAND_SERIAL CAND_PROTOS CAND_USBID
    declare -gA CAND_URI
    CAND_ORDER=()
}

note() {
    local key=$1 field=$2 value=$3
    [[ -n $value ]] || return 0
    case $field in
        name)   [[ -n ${CAND_NAME[$key]:-} ]]   || CAND_NAME[$key]=$value ;;
        addr)   [[ -n ${CAND_ADDR[$key]:-} ]]   || CAND_ADDR[$key]=$value ;;
        rp)     [[ -n ${CAND_RP[$key]:-} ]]     || CAND_RP[$key]=$value ;;
        model)
            # The model arrives from several records at once and the
            # browses run in parallel, so first-wins would make the output
            # depend on timing: _uscan._tcp says "Smart Tank 510 series"
            # where _ipp._tcp says "HP Smart Tank 510 series". The longer
            # name wins when one contains the other, in either order.
            if [[ -z ${CAND_MODEL[$key]:-} ]]; then
                CAND_MODEL[$key]=$value
            elif [[ ${value,,} == *"${CAND_MODEL[$key],,}"* ]] \
                 && (( ${#value} > ${#CAND_MODEL[$key]} )); then
                CAND_MODEL[$key]=$value
            fi ;;
        vendor) [[ -n ${CAND_VENDOR[$key]:-} ]] || CAND_VENDOR[$key]=$value ;;
        serial) [[ -n ${CAND_SERIAL[$key]:-} ]] || CAND_SERIAL[$key]=$value ;;
        protos) [[ -n ${CAND_PROTOS[$key]:-} ]] || CAND_PROTOS[$key]=$value ;;
        usbid)  [[ -n ${CAND_USBID[$key]:-} ]]  || CAND_USBID[$key]=$value ;;
        uri)    [[ -n ${CAND_URI[$key]:-} ]]    || CAND_URI[$key]=$value ;;
        port)
            [[ ",${CAND_PORTS[$key]:-}," == *",$value,"* ]] \
                || CAND_PORTS[$key]="${CAND_PORTS[$key]:+${CAND_PORTS[$key]},}$value" ;;
        how)
            [[ ${CAND_HOW[$key]:-} == *"$value"* ]] \
                || CAND_HOW[$key]="${CAND_HOW[$key]:+${CAND_HOW[$key]}, }$value" ;;
    esac
    return 0
}

remember() {
    local key=$1 where=$2
    [[ -n $key ]] || return 1
    if [[ -z ${CAND_WHERE[$key]:-} ]]; then
        CAND_ORDER+=("$key")
        CAND_WHERE[$key]=$where
    fi
    return 0
}

# ------------------------------------------------------------------- the bus

find_usb() {
    local syspath usbid mfg product serial protos key
    while IFS=$DEVICES_FS read -r syspath usbid mfg product serial protos; do
        key="usb:${serial:-$usbid}"
        remember "$key" usb
        note "$key" name   "${product:+${mfg:+$mfg }$product}"
        note "$key" model  "$product"
        note "$key" vendor "$mfg"
        note "$key" serial "$serial"
        note "$key" protos "$protos"
        note "$key" usbid  "$usbid"
        note "$key" how    "usb ${syspath##*/}"
    done < <(printer_usb_devices)
}

# ------------------------------------------------------------------ the wifi

find_mdns() {
    local name host addr port type rp iface txt key ser ty
    if ! have avahi-browse; then
        warn "avahi-browse not installed; skipping mDNS discovery"
        info "install avahi-utils to find network printers without sweeping"
        return 0
    fi
    while IFS=$DEVICES_FS read -r name host addr port type rp iface txt; do
        ser=$(printer_txt_value usb_SER "$txt" || printf '')
        ty=$(printer_txt_value ty "$txt" || printf '')

        # A service on loopback is a USB printer that ipp-usb has
        # republished. Fold it into the bus record it belongs to - that is
        # what usb_SER is for - rather than reporting 127.0.0.1 as a second
        # printer.
        if [[ $iface == lo || $addr == 127.* ]]; then
            (( NO_USB )) && continue
            key="usb:${ser:-$host}"
            [[ -n ${CAND_WHERE[$key]:-} ]] || remember "$key" usb
        else
            (( USB_ONLY )) && continue
            key=$addr
            remember "$key" network
        fi

        note "$key" addr "$addr"
        note "$key" name "$name"
        note "$key" model "$ty"
        note "$key" serial "$ser"
        note "$key" port "$port"
        note "$key" rp "$rp"
        note "$key" how "mdns $type"
        case $type in
            _ipp._tcp|_ipps._tcp)
                note "$key" uri "$(printer_ipp_uri "$type" "$addr" "$port" "$rp" || printf '')" ;;
        esac
    done < <(printer_mdns_services)
}

sweep() {
    local cidr iface ip port total=0
    local -a hosts=()

    while IFS=$DEVICES_FS read -r cidr iface; do
        hosts=()
        mapfile -t hosts < <(printer_cidr_hosts "$cidr")
        if (( ${#hosts[@]} == 0 )); then
            warn "nothing to sweep on $iface ($cidr)"
            continue
        fi
        total=$(( total + ${#hosts[@]} ))
        if (( DRY_RUN )); then
            printf '%swould probe:%s %d addresses on %s (%s) on ports %s\n' \
                "$C_DIM" "$C_RESET" "${#hosts[@]}" "$cidr" "$iface" "$PRINTER_PORTS" >&2
            continue
        fi
        info "sweeping ${#hosts[@]} addresses on $cidr ($iface) for ports $PRINTER_PORTS"
        while IFS=$DEVICES_FS read -r ip port; do
            remember "$ip" network
            note "$ip" addr "$ip"
            note "$ip" port "$port"
            note "$ip" how  "scan"
        done < <(printf '%s\n' "${hosts[@]}" | printer_scan_hosts)
    done < <(printer_local_subnets)

    (( total )) || warn "no IPv4 subnet to sweep; name one with --subnet"
}

search() {
    reset_candidates
    (( NO_USB )) || find_usb
    (( USB_ONLY )) || find_mdns
    (( USB_ONLY || MDNS_ONLY )) && return 0
    if (( ${#CAND_ORDER[@]} == 0 || SCAN )); then
        sweep
    fi
    return 0
}

# ------------------------------------------------------------------ the hunt

deadline=$(( SECONDS + WAIT ))
while :; do
    search
    (( ${#CAND_ORDER[@]} )) && break
    (( SECONDS < deadline )) || break
    info "nothing yet; looking again in 5s (Ctrl-C to stop)"
    run sleep 5
done

# -------------------------------------------------------------- identify

declare -a FOUND=()

for key in ${CAND_ORDER[@]+"${CAND_ORDER[@]}"}; do
    addr=${CAND_ADDR[$key]:-}
    if [[ ${CAND_WHERE[$key]} == network && -n $addr ]]; then
        mac=$(printer_neigh_mac "$addr" || printf '')
        CAND_MAC[$key]=$mac
        if [[ -n $mac ]]; then
            if printer_mac_is_random "$mac"; then
                note "$key" vendor '(randomised MAC)'
            else
                note "$key" vendor "$(printer_oui_vendor "$mac" || printf '')"
            fi
        fi
        note "$key" model "$(printer_http_identity "$addr" || printf '')"
    fi

    if (( ALL )) || printer_is_hp "${CAND_NAME[$key]:-}" "${CAND_MODEL[$key]:-}" \
        "${CAND_VENDOR[$key]:-}" "${CAND_USBID[$key]:-}"; then
        FOUND+=("$key")
    fi
done

# --------------------------------------------------------------------- report

# Which of these already has a CUPS queue, by the name CUPS derives from
# the advertised name. Answers "do I still need to set it up?".
queue_for() {
    local name=$1 slug qname quri
    slug=$(printer_cups_name "$name") || return 1
    while IFS=$DEVICES_FS read -r qname quri; do
        [[ $qname == "$slug" || $quri == *"$slug"* ]] || continue
        printf '%s' "$qname"
        return 0
    done < <(printer_cups_queues)
    return 1
}

describe_protos() {
    local protos=,${1:-}, out=''
    [[ $protos == *,04,* ]] && out+="IPP-over-USB"
    [[ $protos == *,02,* ]] && out+="${out:+, }bidirectional"
    [[ $protos == *,01,* ]] && out+="${out:+, }unidirectional"
    printf '%s' "${out:-unknown}"
}

report_ink() {
    local names=$1 levels=$2 out='' i=0
    local -a n l
    IFS=, read -r -a n <<<"$names"
    IFS=, read -r -a l <<<"$levels"
    (( ${#n[@]} && ${#n[@]} == ${#l[@]} )) || return 1
    for (( i = 0; i < ${#n[@]}; i++ )); do
        out+="${out:+  }${n[i]% cartridge} ${l[i]}%"
    done
    printf '%s' "$out"
}

uri_for() {
    local key=$1
    local where=${CAND_WHERE[$key]}
    local addr=${CAND_ADDR[$key]:-}
    local open=${CAND_PORTS[$key]:-}
    if [[ -n ${CAND_URI[$key]:-} ]]; then
        printf '%s' "${CAND_URI[$key]}"
        return 0
    fi
    if [[ $where == usb ]]; then
        # ipp-usb's localhost service when there is one, since it is
        # driverless and reports status back; the raw usb:// backend only
        # when there is not.
        if [[ -n $addr && -n $open ]]; then
            printer_device_uri "$addr" "$open" "${CAND_RP[$key]:-}" && return 0
        fi
        printer_usb_uri "${CAND_VENDOR[$key]:-}" "${CAND_MODEL[$key]:-}" "${CAND_SERIAL[$key]:-}" && return 0
        return 1
    fi
    printer_device_uri "$addr" "${CAND_PORTS[$key]:-}" "${CAND_RP[$key]:-}"
}

if (( ${#FOUND[@]} )); then
    for key in "${FOUND[@]}"; do
        label=${CAND_MODEL[$key]:-${CAND_NAME[$key]:-unidentified}}
        # USB reports the product without the maker ("Smart Tank 510
        # series"), so put the maker back when it is not already there.
        vendor=${CAND_VENDOR[$key]:-}
        if [[ -n $vendor && $vendor != *[\ \(]* && ${label,,} != *"${vendor,,}"* ]]; then
            label="$vendor $label"
        fi
        uri=$(uri_for "$key" || printf '')
        info ''
        ok "$label"

        if [[ ${CAND_WHERE[$key]} == usb ]]; then
            # The bus record carries the ids and interface protocols; a
            # printer known only through ipp-usb's advert has neither, and
            # saying "USB ?" would imply the bus was read and came back odd.
            if [[ -n ${CAND_USBID[$key]:-} ]]; then
                info "  attached   USB ${CAND_USBID[$key]}${CAND_SERIAL[$key]:+, serial ${CAND_SERIAL[$key]}}"
                info "  interfaces printer class, $(describe_protos "${CAND_PROTOS[$key]:-}")"
            else
                info "  attached   USB${CAND_SERIAL[$key]:+, serial ${CAND_SERIAL[$key]}} (known from ipp-usb, bus not read)"
            fi
            if [[ -n ${CAND_ADDR[$key]:-} ]]; then
                info "  published  ${CAND_ADDR[$key]}:${CAND_PORTS[$key]:-?} by ipp-usb, as \"${CAND_NAME[$key]:-?}\""
            elif ! printer_usb_is_ipp "${CAND_PROTOS[$key]:-}"; then
                : # nothing to publish it with; the usb:// backend is the only route
            elif (( USB_ONLY )); then
                info "  published  not checked; --usb-only skipped the mDNS browse"
            else
                warn "this printer speaks IPP-over-USB but nothing is publishing it"
                info "  start ipp-usb for a driverless queue: sudo systemctl start ipp-usb"
            fi
        else
            info "  address    ${CAND_ADDR[$key]:-?}${CAND_MAC[$key]:+  (${CAND_MAC[$key]})}"
            info "  vendor     ${CAND_VENDOR[$key]:-unknown}"
            info "  ports      ${CAND_PORTS[$key]:-none open}"
        fi
        info "  found by   ${CAND_HOW[$key]}"

        if [[ -n $uri && $uri == ipp* ]] && (( DRY_RUN )); then
            printf '%swould ask:%s %s for its state and ink levels\n' \
                "$C_DIM" "$C_RESET" "$uri" >&2
        elif [[ -n $uri && $uri == ipp* ]] && state=$(printer_ipp_state "$uri"); then
            IFS=$DEVICES_FS read -r ipp_model ipp_state ipp_accept ink_names ink_levels <<<"$state"
            : "$ipp_model"
            info "  state      ${ipp_state:-unknown}$([[ $ipp_accept == true ]] && printf ', accepting jobs')"
            ink=$(report_ink "$ink_names" "$ink_levels" || printf '')
            [[ -n $ink ]] && info "  ink        $ink"
        fi

        if qname=$(queue_for "${CAND_NAME[$key]:-}"); then
            info "  cups       queue $qname is already configured"
        else
            info "  cups       no queue yet: lpadmin -p NAME -E -v $uri -m everywhere"
        fi

        if [[ -n $uri ]]; then
            printf '%s\n' "$uri"
        else
            warn "${CAND_ADDR[$key]:-$key} answers, but on no port CUPS can print to"
        fi
    done
    exit "$EX_OK"
fi

# Nothing matched. Say what was actually seen, because every cause below
# looks identical from here and only the user can tell them apart.

if (( DRY_RUN )); then
    info "dry run: nothing was probed"
    exit "$EX_OK"
fi

if (( ALL )); then
    err "no printer of any make found"
else
    err "no HP printer found"
    info "pass --all to report printers of other makes"
fi

if (( ${#CAND_ORDER[@]} )); then
    info "these answered, but do not look like printers:"
    for key in "${CAND_ORDER[@]}"; do
        info "  ${CAND_ADDR[$key]:-$key}  ports ${CAND_PORTS[$key]:-?}  ${CAND_VENDOR[$key]:-unknown vendor}"
    done
fi

(( NO_USB )) || info "nothing on the USB bus claims the printer interface class"
if (( ! USB_ONLY )); then
    printer_mdns_running \
        || warn "avahi-daemon is not running, so mDNS found nothing by construction: sudo systemctl start avahi-daemon"
    info "$(printer_neigh_count) addresses answered recently, so the network itself is reachable"
fi

cat >&2 <<EOF

A printer that is on, and either cabled or joined to this wifi, is always
visible here. Check in this order:

  1. The cable, if there is one. A charge-only USB cable carries no data,
     and the bus would then look exactly like this.
  2. Wake it. Some models drop off the network in deep sleep and only
     rejoin when a button is pressed.
  3. Print its network configuration page from the printer's own panel
     (Settings > Network > Reports). That page states the SSID it joined
     and the address it holds, which settles whether it is on this network
     at all.
  4. Check the SSID. A printer on the guest network, or on a 2.4GHz-only
     SSID this laptop is not using, is a different broadcast domain.
  5. Check client isolation on the router. With it on, this machine cannot
     reach the printer at all, by design, and nothing here will find it.

Then re-run with:  $PROG -s -w 120
EOF

exit "$EX_NODEV"
