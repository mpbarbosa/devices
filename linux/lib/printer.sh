#!/usr/bin/env bash
#
# lib/printer.sh - detection for printers, HP in particular.
#
# Pure detection: every helper prints records and none of them changes
# anything, here or on the printer. Fields are separated by $DEVICES_FS,
# never a tab, so an empty field cannot shift the later fields left.
#
# A printer is unlike the other devices in this suite in two ways. There is
# usually nothing plugged in, so there is no sysfs node to read; and there
# is never anything to mount, so finding it is the whole job. It is found
# three ways, because each one misses a different printer:
#
#   usb    The cable case. USB interface class 07 is the printer class, so
#          the bus says a printer is attached whether or not anything can
#          talk to it yet.
#   mDNS   Every printer sold since roughly 2010 advertises _ipp._tcp and
#          _pdl-datastream._tcp over multicast DNS, so one browse finds it
#          with no scanning at all - and its model name, queue path and
#          capabilities come with it. But multicast does not cross subnets
#          or client isolation, and a printer asleep deeply enough to have
#          dropped off the wifi advertises nothing.
#   ports  A direct TCP probe of 9100 (HP JetDirect), 631 (IPP) and 515
#          (LPD) across the local subnet. Slower and noisier, but it finds
#          printers with mDNS disabled, which is a common hardening
#          default, and it tells "not on this network" apart from "on this
#          network and not advertising".
#
# The central domain fact, and the reason the USB and mDNS paths have to
# meet: a modern printer on a cable is *also* an IPP network printer. USB
# printer-class protocol 04 is IPP-over-USB, and ipp-usb(8) republishes
# such a device as an IPP service on localhost, advertised over mDNS on the
# loopback interface with the real USB serial in its TXT record. So one
# printer shows up twice, once on the bus and once at 127.0.0.1, and it is
# the TXT key usb_SER that proves they are the same unit. Protocol 02 is
# the older bidirectional interface, which CUPS drives through a usb:// URI
# instead; this suite prefers the IPP route when the printer offers it,
# because it is driverless and reports status back.
#
# Identification is deliberately not a single string match. A printer may
# answer to "HP", to "Hewlett-Packard", to a marketing family (DeskJet,
# OfficeJet, LaserJet, ENVY, Smart Tank) or to nothing but its MAC, so the
# USB manufacturer, the mDNS name and TXT record, the HTTP title and the
# IEEE OUI of the MAC are all consulted and any one of them is enough.

[[ -n ${DEVICES_PRINTER_LIB:-} ]] && return 0
DEVICES_PRINTER_LIB=1

# Overridable so detection can be pointed at a fixture (see CLAUDE.md).
PRINTER_SYSFS_USB=${PRINTER_SYSFS_USB:-/sys/bus/usb/devices}
PRINTER_MDNS_TYPES=${PRINTER_MDNS_TYPES:-'_ipp._tcp _ipps._tcp _pdl-datastream._tcp _printer._tcp _uscan._tcp'}
PRINTER_PORTS=${PRINTER_PORTS:-'9100 631 515'}
PRINTER_NAME_PATTERN=${PRINTER_NAME_PATTERN:-'(^|[^a-z])(hp|hewlett[ -]?packard|deskjet|officejet|laserjet|envy|photosmart|smart[ _-]?tank|designjet|pagewide|neverstop)'}
PRINTER_OUI_FILE=${PRINTER_OUI_FILE:-/usr/share/ieee-data/oui.txt}
PRINTER_SUBNET=${PRINTER_SUBNET:-}

# A /24 is 254 probes per port and takes a few seconds; a /16 is 65534 and
# takes an hour, which is never what anyone meant.
PRINTER_SCAN_MAX_HOSTS=${PRINTER_SCAN_MAX_HOSTS:-1024}
PRINTER_PROBE_TIMEOUT=${PRINTER_PROBE_TIMEOUT:-2}
PRINTER_MDNS_TIMEOUT=${PRINTER_MDNS_TIMEOUT:-10}
PRINTER_JOBS=${PRINTER_JOBS:-64}

# Virtual interfaces have no printer on them, and sweeping a docker bridge
# only wastes time. Loopback is skipped as well: a printer answering there
# is a USB printer behind ipp-usb, which the USB path finds properly.
PRINTER_SKIP_IFACES=${PRINTER_SKIP_IFACES:-'lo|docker|virbr|br-|veth|tun|tap|wg|zt'}

# ------------------------------------------------------------------- strings

# avahi-browse -p escapes anything outside printable ASCII, and the field
# separator, as \NNN - and NNN is DECIMAL, not octal: "HP\032ENVY" is
# "HP ENVY" and "\0916E0508\093" is "[6E0508]". printf %b speaks octal, so
# each escape is converted on the way through.
printer_unescape() {
    local s=$1 out='' chunk dec
    while [[ $s == *\\* ]]; do
        out+=${s%%\\*}
        s=${s#*\\}
        if [[ ${s:0:3} =~ ^[0-9][0-9][0-9]$ ]]; then
            dec=$(( 10#${s:0:3} ))
            s=${s:3}
            if (( dec > 0 && dec < 256 )); then
                printf -v chunk '%b' "\\0$(printf '%03o' "$dec")"
                out+=$chunk
            fi
        else
            out+=\\
        fi
    done
    printf '%s' "$out$s"
}

# One value out of an mDNS TXT record, which avahi prints as a list of
# quoted key=value pairs. Values may contain spaces ("ty=HP Smart Tank 510
# series"), so the quotes are the delimiter, not whitespace.
printer_txt_value() {
    local key=$1 txt=$2
    [[ $txt =~ (^|[[:space:]])\"?$key=([^\"]*)\"? ]] || return 1
    printf '%s' "${BASH_REMATCH[2]}"
}

# Percent-encode a path component for a device URI, as CUPS does.
printer_urlencode() {
    local s=$1 out='' i c
    for (( i = 0; i < ${#s}; i++ )); do
        c=${s:i:1}
        case $c in
            [a-zA-Z0-9._~-]) out+=$c ;;
            *)               out+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    printf '%s' "$out"
}

# Decide whether a device is HP from everything known about it at once -
# USB manufacturer, mDNS name, TXT record, HTTP title, OUI vendor - since
# any one of them can be the only place the brand appears. "hp" is matched
# on a word boundary or Sharp hardware would answer to it.
printer_is_hp() {
    local haystack=${*,,}
    [[ $haystack =~ $PRINTER_NAME_PATTERN ]]
}

# ----------------------------------------------------------------------- USB

# Print one record per USB device claiming the printer interface class:
#   syspath<FS>vid:pid<FS>manufacturer<FS>product<FS>serial<FS>protocols
#
# Protocols are the interface protocol bytes of class 07, deduplicated: 04
# means IPP-over-USB (driverless, via ipp-usb), 02 the classic
# bidirectional interface (the usb:// backend), 01 unidirectional.
printer_usb_devices() {
    local fs=$DEVICES_FS dir iface cls proto protos vid pid mfg product serial
    [[ -d $PRINTER_SYSFS_USB ]] || return 0
    for dir in "$PRINTER_SYSFS_USB"/*; do
        [[ -r $dir/idVendor && -r $dir/idProduct ]] || continue
        protos=''
        for iface in "$dir"/*:*; do
            [[ -r $iface/bInterfaceClass ]] || continue
            cls=$(<"$iface/bInterfaceClass")
            [[ $cls == 07 ]] || continue
            proto=$(<"$iface/bInterfaceProtocol")
            [[ ,$protos, == *",$proto,"* ]] || protos="${protos:+$protos,}$proto"
        done
        [[ -n $protos ]] || continue
        vid=$(<"$dir/idVendor")
        pid=$(<"$dir/idProduct")
        mfg=''     ; [[ -r $dir/manufacturer ]] && mfg=$(<"$dir/manufacturer")
        product='' ; [[ -r $dir/product ]]      && product=$(<"$dir/product")
        serial=''  ; [[ -r $dir/serial ]]       && serial=$(<"$dir/serial")
        printf '%s\n' "$dir$fs$vid:$pid$fs$mfg$fs$product$fs$serial$fs$protos"
    done
}

# True when the device offers IPP-over-USB, so ipp-usb can make it a
# driverless IPP printer without any model-specific driver at all.
printer_usb_is_ipp() {
    [[ ,${1:-}, == *,04,* ]]
}

# The classic CUPS usb:// URI, for a printer with no IPP-over-USB
# interface or with ipp-usb not running.
printer_usb_uri() {
    local mfg=$1 mdl=$2 serial=${3:-}
    [[ -n $mfg && -n $mdl ]] || return 1
    printf 'usb://%s/%s' "$(printer_urlencode "$mfg")" "$(printer_urlencode "$mdl")"
    [[ -n $serial ]] && printf '?serial=%s' "$(printer_urlencode "$serial")"
    return 0
}

# ---------------------------------------------------------------------- mDNS

# Print one record per advertised print service:
#   name<FS>host<FS>address<FS>port<FS>type<FS>rp<FS>interface<FS>txt
#
# The type is the one browsed for, not the one avahi prints: avahi
# substitutes a human description for the well-known types ("Internet
# Printer" for _ipp._tcp), which is no use to a caller deciding what to do
# with the record. Port 0 is dropped - ipp-usb advertises _printer._tcp
# that way, meaning "this exists but do not print to it here".
printer_mdns_services() {
    local fs=$DEVICES_FS type
    local -a types runner=()
    have avahi-browse || return 0
    read -r -a types <<<"$PRINTER_MDNS_TYPES"
    (( ${#types[@]} )) || return 0
    have timeout && runner=(timeout "$PRINTER_MDNS_TIMEOUT")

    # One browse per type, in parallel: avahi-browse takes a single service
    # type per invocation, and five sequential browses is five timeouts.
    for type in "${types[@]}"; do
        (
            local tag iface proto name svc domain host addr port txt rp
            while IFS=';' read -r tag iface proto name svc domain host addr port txt; do
                [[ $tag == '=' ]] || continue          # resolved records only
                [[ $proto == IPv4 ]] || continue       # the IPv6 record is the same printer
                [[ ${port:-0} == 0 ]] && continue
                : "$svc" "$domain"
                name=$(printer_unescape "$name")
                txt=$(printer_unescape "$txt")
                rp=$(printer_txt_value rp "$txt" || printf '')
                printf '%s\n' "$name$fs$host$fs$addr$fs$port$fs$type$fs$rp$fs$iface$fs$txt"
            done < <(${runner[@]+"${runner[@]}"} avahi-browse -rtp "$type" 2>/dev/null)
        ) &
    done
    wait
}

# True when the mDNS responder is actually running, which is the first
# thing to doubt when a browse comes back empty on a network that has a
# printer on it.
printer_mdns_running() {
    [[ -S /run/avahi-daemon/socket || -S /var/run/avahi-daemon/socket ]]
}

# -------------------------------------------------------------- the network

# Print one record per IPv4 subnet worth sweeping:  cidr<FS>interface
printer_local_subnets() {
    local fs=$DEVICES_FS iface fam cidr
    if [[ -n $PRINTER_SUBNET ]]; then
        printf '%s\n' "$PRINTER_SUBNET${fs}override"
        return 0
    fi
    have ip || return 0
    while read -r _ iface fam cidr _; do
        [[ $fam == inet ]] || continue
        [[ $cidr == */* ]] || continue
        [[ $iface =~ ^($PRINTER_SKIP_IFACES) ]] && continue
        printf '%s\n' "$cidr$fs$iface"
    done < <(ip -4 -o addr show scope global 2>/dev/null)
}

printer_ip_to_int() {
    local a b c d
    IFS=. read -r a b c d <<<"$1"
    [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ && $c =~ ^[0-9]+$ && $d =~ ^[0-9]+$ ]] || return 1
    printf '%u' "$(( (a << 24) | (b << 16) | (c << 8) | d ))"
}

# Print every host address in a CIDR block, one per line. Refuses a block
# larger than PRINTER_SCAN_MAX_HOSTS rather than sweeping for an hour.
printer_cidr_hosts() {
    local cidr=$1 addr prefix mask base bcast first last n total
    prefix=24
    [[ $cidr == */* ]] && prefix=${cidr#*/}
    addr=$(printer_ip_to_int "${cidr%/*}") || return 1
    [[ $prefix =~ ^[0-9]+$ ]] || return 1
    (( prefix >= 8 && prefix <= 32 )) || return 1

    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    base=$(( addr & mask ))
    bcast=$(( base | (0xFFFFFFFF ^ mask) ))
    if (( prefix >= 31 )); then
        first=$base last=$bcast
    else
        first=$(( base + 1 )) last=$(( bcast - 1 ))
    fi
    total=$(( last - first + 1 ))
    if (( total > PRINTER_SCAN_MAX_HOSTS )); then
        warn "$cidr is $total addresses, more than PRINTER_SCAN_MAX_HOSTS=$PRINTER_SCAN_MAX_HOSTS; narrow it with --subnet"
        return 1
    fi
    for (( n = first; n <= last; n++ )); do
        printf '%u.%u.%u.%u\n' \
            "$(( (n >> 24) & 255 ))" "$(( (n >> 16) & 255 ))" "$(( (n >> 8) & 255 ))" "$(( n & 255 ))"
    done
}

# True when a TCP port accepts a connection. bash opens the socket itself,
# so no scanner needs to be installed; timeout(1) is what bounds it, since
# a filtered port otherwise hangs for the kernel's full SYN retry.
printer_port_open() {
    local ip=$1 port=$2
    have timeout || return 2
    # Single quotes on purpose: $0 and $1 are expanded by the child bash,
    # inside the redirection, so the address never reaches a command line.
    # shellcheck disable=SC2016
    timeout "$PRINTER_PROBE_TIMEOUT" bash -c 'exec 3<>/dev/tcp/$0/$1' "$ip" "$port" 2>/dev/null
}

# Probe a list of addresses on stdin for the printer ports, in parallel.
# Prints one record per open port:  ip<FS>port
printer_scan_hosts() {
    local ip port started=0
    local -a ports
    read -r -a ports <<<"$PRINTER_PORTS"
    (( ${#ports[@]} )) || return 0
    have timeout || { warn "timeout(1) not found; skipping the port sweep"; return 1; }

    while read -r ip; do
        [[ -n $ip ]] || continue
        for port in "${ports[@]}"; do
            { printer_port_open "$ip" "$port" && printf '%s\n' "$ip$DEVICES_FS$port"; } &
            started=$(( started + 1 ))
            if (( started >= PRINTER_JOBS )); then
                wait
                started=0
            fi
        done
    done
    wait
}

# ----------------------------------------------------------- identification

# The MAC of an address, from the neighbour table only - no probe of our
# own, so this is also a record of who answered the last sweep.
printer_neigh_mac() {
    local ip=$1 line i
    local -a tok
    have ip || return 1
    line=$(ip -4 neigh show "$ip" 2>/dev/null) || return 1
    read -r -a tok <<<"$line"
    for (( i = 0; i < ${#tok[@]} - 1; i++ )); do
        [[ ${tok[i]} == lladdr ]] || continue
        printf '%s' "${tok[i+1]}"
        return 0
    done
    return 1
}

# Phones and laptops randomise their MAC, which sets the locally
# administered bit and leaves no vendor to look up. Worth saying out loud
# rather than reporting those as an unknown manufacturer.
printer_mac_is_random() {
    local mac=${1//:/} nibble
    [[ ${#mac} -ge 2 ]] || return 1
    nibble=$(( 0x${mac:1:1} ))
    (( nibble & 2 ))
}

# Manufacturer for a MAC, from the IEEE OUI registry shipped by the
# ieee-data package. Optional, like every other external dependency here.
printer_oui_vendor() {
    local mac=$1 oui line
    [[ -r $PRINTER_OUI_FILE ]] || return 1
    oui=${mac//:/}
    oui=${oui//-/}
    oui=${oui:0:6}
    [[ ${#oui} -eq 6 ]] || return 1
    line=$(grep -m1 -E "^${oui^^}[[:space:]]+\(base 16\)" "$PRINTER_OUI_FILE" 2>/dev/null) || return 1
    line=${line#*"(base 16)"}
    line=${line#"${line%%[![:space:]]*}"}
    [[ -n $line ]] || return 1
    printf '%s' "$line"
}

# The model name an address will admit to over HTTP.
#
# HP's embedded web server answers /DevMgmt/ProductConfigDyn.xml with the
# product name on every model since about 2010, which is the most precise
# identification available without SNMP; the <title> of the landing page is
# the fallback, and is what non-HP printers answer with.
#
# Two details this printer taught us. The model lives in ProductName on
# some LEDM families and in MakeAndModel on others - a Smart Tank 510
# has only the second - so both are read before falling back. And curl
# must ask for --compressed: an HP embedded web server gzips its root
# page whether or not the client offered to accept it, so without it the
# regex is matched against a gzip blob, which never matches and makes
# bash warn about the null bytes it drops on the way out of $(...).
printer_http_identity() {
    local ip=$1 scheme body elem
    have curl || return 1
    for scheme in http https; do
        body=$(curl -sk --compressed -m "$PRINTER_PROBE_TIMEOUT" "$scheme://$ip/DevMgmt/ProductConfigDyn.xml" 2>/dev/null) || body=''
        for elem in ProductName MakeAndModel; do
            if [[ $body =~ \<[a-zA-Z:]*$elem\>([^\<]+)\< ]]; then
                printf '%s' "${BASH_REMATCH[1]}"
                return 0
            fi
        done
        body=$(curl -sk --compressed -m "$PRINTER_PROBE_TIMEOUT" "$scheme://$ip/" 2>/dev/null) || body=''
        if [[ $body =~ \<[Tt][Ii][Tt][Ll][Ee]\>([^\<]+) ]]; then
            body=${BASH_REMATCH[1]}
            body=${body//$'\n'/ }
            body=${body#"${body%%[![:space:]]*}"}
            body=${body%"${body##*[![:space:]]}"}
            [[ -n $body ]] || continue
            printf '%s' "$body"
            return 0
        fi
    done
    return 1
}

# What a printer says about itself over IPP:
#   model<FS>state<FS>accepting<FS>marker-names<FS>marker-levels
#
# Read-only, and optional: ipptool ships with CUPS but need not be
# installed. This is the only helper here that talks to the printer rather
# than about it, and it is still a query - get-printer-attributes changes
# nothing and queues nothing.
printer_ipp_state() {
    local uri=$1 line key value
    local model='' state='' accepting='' names='' levels=''
    have ipptool || return 1
    while IFS= read -r line; do
        [[ $line =~ ^[[:space:]]*([a-z-]+)[[:space:]]+\([^\)]*\)[[:space:]]+=[[:space:]]*(.*)$ ]] || continue
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        case $key in
            printer-make-and-model)  model=$value ;;
            printer-state)           state=$value ;;
            printer-is-accepting-jobs) accepting=$value ;;
            marker-names)            names=$value ;;
            marker-levels)           levels=$value ;;
        esac
    done < <(timeout "$(( PRINTER_PROBE_TIMEOUT * 5 ))" \
                ipptool -tv "$uri" get-printer-attributes.test 2>/dev/null)
    [[ -n $state || -n $model ]] || return 1
    printf '%s\n' "$model$DEVICES_FS$state$DEVICES_FS$accepting$DEVICES_FS$names$DEVICES_FS$levels"
}

# The IPP device URI for an advertised service. The port is whatever the
# advert says, which for ipp-usb is an ephemeral one on loopback (60000
# here) rather than 631, so it cannot be inferred from the port number the
# way a swept printer's can.
printer_ipp_uri() {
    local type=$1 addr=$2 port=$3 rp=${4:-}
    local scheme=ipp
    [[ $type == _ipps._tcp ]] && scheme=ipps
    [[ -n $addr && -n $port ]] || return 1
    printf '%s://%s:%s/%s' "$scheme" "$addr" "$port" "${rp:-ipp/print}"
}

# The CUPS device URI for a printer, given the ports found open on it.
#
# IPP first: it is the only one that reports back what the printer is doing
# and it needs no driver. Raw JetDirect on 9100 always works and tells you
# nothing. LPD is the last resort.
printer_device_uri() {
    local ip=$1 open=,${2:-}, rp=${3:-}
    if [[ $open == *,631,* ]]; then
        printf 'ipp://%s/%s' "$ip" "${rp:-ipp/print}"
    elif [[ $open == *,9100,* ]]; then
        printf 'socket://%s:9100' "$ip"
    elif [[ $open == *,515,* ]]; then
        printf 'lpd://%s/%s' "$ip" "${rp:-queue}"
    else
        return 1
    fi
}

# Print one record per queue CUPS already has:  name<FS>uri
#
# lpstat -v rows read "device for NAME: URI", so the name is the third
# field and carries the colon.
printer_cups_queues() {
    local name uri
    have lpstat || return 0
    while read -r _ _ name uri; do
        [[ -n ${uri:-} ]] || continue
        printf '%s\n' "${name%:}$DEVICES_FS$uri"
    done < <(LC_ALL=C lpstat -v 2>/dev/null)
}

# The queue name CUPS derives from a printer's advertised name: every run
# of characters outside [A-Za-z0-9] collapses to a single underscore. Used
# to tell "this printer already has a queue" from "this one is new".
printer_cups_name() {
    local slug=${1//[^a-zA-Z0-9]/_}
    while [[ $slug == *__* ]]; do slug=${slug//__/_}; done
    slug=${slug#_}
    slug=${slug%_}
    [[ -n $slug ]] || return 1
    printf '%s' "$slug"
}

# True when cupsd is answering at all. "No queue" and "no scheduler" look
# identical from lpstat -v, which prints nothing in either case, and only
# the second one is cured by starting a service.
printer_cups_running() {
    local line
    have lpstat || return 1
    line=$(LC_ALL=C lpstat -r 2>/dev/null) || return 1
    [[ $line == *"is running"* ]]
}

# The queue CUPS prints to when none is named, if the host has one.
#
# lpstat -d says "system default destination: NAME" or "no system default
# destination", and a host can perfectly well have queues and no default -
# this one does - so a failure here means "none set", not "none exist".
printer_cups_default() {
    local line name
    have lpstat || return 1
    line=$(LC_ALL=C lpstat -d 2>/dev/null) || return 1
    [[ $line == *": "* ]] || return 1
    name=${line##*": "}
    name=${name%"${name##*[![:space:]]}"}
    [[ -n $name ]] || return 1
    printf '%s' "$name"
}

# What one queue is doing:  state<FS>accepting<FS>description
#
# Two questions, two commands, because the answers are independent and
# only one of them loses a job. lpstat -p says idle, printing or disabled;
# lpstat -a says whether new jobs are taken at all. A *disabled* queue
# still accepts jobs and holds them until it is enabled, whereas one that
# is not accepting rejects them outright - so a caller can warn about the
# first and must refuse the second.
#
# Returns 1 when the queue does not exist, which is how an out-of-date
# queue name is told apart from a printer that is merely idle.
printer_queue_state() {
    local name=$1 out desc='' state='' accepting=true
    have lpstat || return 1
    out=$(LC_ALL=C lpstat -p "$name" 2>/dev/null) || return 1
    desc=${out%%$'\n'*}
    [[ -n $desc ]] || return 1
    if [[ $desc =~ is[[:space:]]+([a-z]+) ]]; then
        state=${BASH_REMATCH[1]}
    elif [[ $desc == *disabled* ]]; then
        state=disabled
    fi
    out=$(LC_ALL=C lpstat -a "$name" 2>/dev/null) || out=''
    [[ $out == *"not accepting"* ]] && accepting=false
    printf '%s\n' "${state:-unknown}$DEVICES_FS$accepting$DEVICES_FS$desc"
}

# How many addresses answered recently, from the neighbour table. Says
# "the network is there and N things are on it" without sending anything.
printer_neigh_count() {
    local n=0 line
    have ip || { printf '0'; return 0; }
    while read -r line; do
        [[ $line == *lladdr* ]] || continue
        n=$(( n + 1 ))
    done < <(ip -4 neigh show 2>/dev/null)
    printf '%u' "$n"
}
