# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A suite of POSIX-host bash scripts that set up, mount and unmount devices
attached to Linux. No build system, no package manifest, no CI. Bash 4.2+ is
required (enforced at the top of `linux/lib/common.sh`) because the code relies
on `declare -gA`, `${var,,}` and `mapfile`.

The tree is split by **host platform**: `linux/` holds the bash suite described
below, and `windows/` holds material for Windows hosts — PowerShell 5.1
scripts and device data, one directory per device, plus host-level
configuration that has no device of its own:

- `windows/mpd218/first_preset.mpd218` — the Akai MPD218 controller preset
  (all 48 pads on notes 36-83, MIDI channel 10; banks A, B and C at 36-51,
  52-67 and 68-83), a sysex dump kept `binary`.
- `windows/mpd218/midimon.ps1` — prints what the controller actually sends.
- `windows/clock/fix-clock-utc.ps1` — stops the clock booting three hours fast
  when the host dual-boots Linux, which keeps the RTC in UTC.

The PowerShell scripts follow the same discipline as the bash suite: a
comment-based help block, `-WhatIf` wherever bash would offer `-n`, and no
silent side effects. Everything else in this file concerns `linux/` unless
stated otherwise.

## Commands

```bash
cd linux && shellcheck -x -S style lib/*.sh kindle/*.sh mpd218/*.sh printer/*.sh camera/*.sh   # lint; must stay clean
bash -n linux/lib/common.sh                       # syntax-only check of one file
./linux/kindle/kindle-mount.sh -n                 # dry run: prints every command instead of running it
DEVICES_DEBUG=1 ./linux/kindle/kindle-mount.sh    # trace the commands actually executed
```

**Lint from inside `linux/`, not from the repository root.** shellcheck 0.11
resolves a `# shellcheck source=lib/...` directive relative to its own working
directory and does not honour `source-path=SCRIPTDIR/..` here, so running it
from the root reports SC1091 on every entry script — and, because the library
then goes unread, a spurious SC2034 for `QUIET`. Both vanish when the lint runs
from `linux/`.

`shellcheck -x` is required rather than plain `shellcheck`: the entry scripts
source the libraries through `$ROOT_DIR`, which shellcheck can only follow
because each script carries `# shellcheck source-path=SCRIPTDIR/..` plus a
`# shellcheck source=lib/...` directive per `.` line. Keep those in place when
adding a script.

### Testing without the hardware

There is no test suite. The scripts are instead designed so every probe can be
redirected at a fixture, which is how to exercise a device you do not have
plugged in. Override the seam, and put stub `lsblk`, `udevadm`, `udisksctl`,
`jmtpfs` and `fusermount3` executables early in `PATH`:

| Variable | Replaces |
| --- | --- |
| `DEVICES_MOUNTS` | `/proc/self/mounts` |
| `KINDLE_SYSFS_USB` | `/sys/bus/usb/devices` |
| `KINDLE_LABEL`, `KINDLE_USB_VENDOR` | the strings matched during detection |
| `PRINTER_SYSFS_USB` | `/sys/bus/usb/devices` |
| `PRINTER_MDNS_TYPES`, `PRINTER_PORTS` | the mDNS service types browsed, the ports probed |
| `PRINTER_NAME_PATTERN` | the regex that decides a device is HP |
| `PRINTER_SUBNET` | the block swept, instead of asking `ip route` |
| `PRINTER_OUI_FILE` | the IEEE OUI database read for vendor names |
| `PRINTER_SCAN_MAX_HOSTS` | the refusal threshold for a sweep |
| `CAMERA_SYSFS_V4L` | `/sys/class/video4linux` |
| `CAMERA_DEV_DIR` | `/dev`, where the `video*` nodes are looked for |
| `CAMERA_APPS`, `CAMERA_APP_ID` | the binaries tried, and the flatpak id |

```bash
PATH="$STUBS:$PATH" DEVICES_MOUNTS="$FIXTURE/mounts" \
  KINDLE_SYSFS_USB="$FIXTURE/sysfs" ./linux/kindle/kindle-unmount.sh -a -n
```

The printer scripts are exercised the same way, with stub `avahi-browse`,
`ip`, `curl` and `ipptool` executables — which is the only way to reach the
network path while the printer is on a USB cable, and the only way to reach
either path with no printer at all:

```bash
PATH="$STUBS:$PATH" PRINTER_SYSFS_USB="$FIXTURE/sysfs-empty" \
  ./linux/printer/printer-find.sh            # pretend it is on the wifi
```

A stub `avahi-browse` must emit `avahi-browse -rtp` records verbatim,
including the decimal `\NNN` escapes — they are what
`printer_unescape` exists for. The TCP sweep needs no stub at all: point it
at a real listening socket, which tests the live code path.

```bash
python3 -c "import socket,time; s=socket.socket(); s.bind(('127.0.0.1',9100)); s.listen(1); time.sleep(30)" &
./linux/printer/printer-find.sh -S 127.0.0.1/32 -p 9100 -a
```

Preserve these seams when touching detection code — hardcoding `/proc` or
`/sys` again makes that branch untestable.

## Architecture

Three layers, each entry script being a thin argument parser over the libraries:

- `linux/lib/common.sh` — device-agnostic. Logging, the `DRY_RUN`/`QUIET`
  discipline, privilege escalation, path normalisation, mount-table reading.
  Sourced first; it guards against double-sourcing and defines the `EX_*` exit
  codes.
- `linux/lib/kindle.sh` — all Kindle knowledge, and the only place that knows
  about udev properties, USB interface classes or MTP helpers. Pure detection:
  it prints records and never mounts anything.
- `linux/kindle/kindle-mount.sh`, `linux/kindle/kindle-unmount.sh` — option
  parsing, the decision of which strategy to use, and the user-facing
  diagnostics.
- `linux/lib/printer.sh` — all printer knowledge, and the only place that
  knows about mDNS service types, USB printer-class protocols, IEEE OUIs or
  IPP attributes. Pure detection: it prints records and never configures a
  queue.
- `linux/printer/printer-find.sh` — the search, the identification and the
  diagnostics when nothing is found. Prints a CUPS device URI on stdout and
  never calls `lpadmin`, so adding a queue stays an explicit act.
- `linux/printer/printer-print.sh` — submits a job through a queue CUPS
  already has. The queue name is resolved rather than hardcoded (`--dest`,
  `$PRINTER_DEST`, the CUPS default, the only queue, the only queue that is
  taking jobs) because CUPS derives it from what the printer advertises and
  it changes when the printer is renamed, re-added or moved between the
  cable and the wifi. Prints job ids on stdout. A *disabled* queue holds the
  job, so that warns; one that is *not accepting* rejects it, so that
  refuses before submitting. Every `lpstat` read is wrapped in `LC_ALL=C`:
  the rows it parses ("device for NAME: URI", "is idle", "not accepting")
  are translated strings, and this host runs in pt_BR.
- `linux/lib/camera.sh` — all webcam knowledge, and the only place that knows
  about V4L2 capture capabilities, UVC metadata nodes or pixel formats. Pure
  detection: it prints records and never opens the camera.
- `linux/camera/camera-open.sh` — opens GNOME Camera, after checking there is
  a camera for it to show. The app takes no device argument (it gets its list
  from PipeWire through the `org.freedesktop.portal.Camera` portal), so the
  script cannot aim it at a node; what it does instead is tell the failures
  apart — app missing, no graphical session, no capture node, node not
  readable by this user, portal absent — and print the app's pid on stdout.
  Detached by default, since closing the terminal should not take the window
  with it; `--wait` keeps it in the foreground.
- `linux/camera/camera-record.sh` — records straight to a file with ffmpeg,
  bypassing the GUI, so it works over ssh with no desktop. Resolves the node
  rather than hardcoding `/dev/video0` (see below), refuses to overwrite an
  existing recording without `--force` because a take is not reproducible,
  and prints the path written on stdout. `--duration` bounds the recording;
  without it, it runs until stopped.
- `linux/lib/mpd218.sh` — all MPD218 knowledge. Detects the device in two
  namespaces: the raw ALSA port (`hw:1,0,0`, what `amidi` needs for sysex) and
  the sequencer address (`20:0`, what `aconnect` needs). Pure detection.
- `linux/mpd218/mpd218-config.sh`, `linux/mpd218/mpd218-synth.sh`,
  `linux/mpd218/mpd218-drums.sh` — preset transfer, routing the controller into
  FluidSynth so it is audible, and a generated General MIDI drum kit.
  `mpd218-drums.sh` is the one script that writes a preset from scratch rather
  than moving one around, so it carries the 549-byte dump layout in its header
  comment: 7 header bytes, slot, 8-byte name, 14-bit tempo stuffed into two
  7-bit bytes, division, swing, 48 pads × 8 bytes, 18 dials × 8 bytes, `F7`.
  Every byte after the header must be ≤ `0x7F` or it is not legal SysEx. The
  check to run after touching it is a `construct` round-trip (parse and re-emit
  byte-identically) plus a read-back from the device.

`$ROOT_DIR` resolves to `linux/`, not the repository root, so the in-script
`# shellcheck source=lib/...` directives stay relative to `linux/` and need no
`linux/` prefix themselves.

### The record protocol

Detection helpers return multi-field records, one per line, with fields joined
by `$DEVICES_FS` (a `\x1f` unit separator) and read back with
`IFS=$DEVICES_FS read -r ...`. **Do not switch this to a tab.** Tab is an IFS
whitespace character, so bash collapses runs of them and an empty field — an
unmounted device has an empty mountpoint — silently shifts every later field
left. That bug has already been fixed once here.

### Two kinds of Kindle

The central domain fact, and the reason detection is split the way it is: older
Kindles expose USB mass storage (a vfat block device, USB interface class 08),
newer ones (Scribe, Colorsoft, Paperwhite 2024+) expose only MTP (no block
device at all, interface class 06). `kindle_usb_devices` enumerates Amazon
devices once and `kindle_mtp_devices` / `kindle_ums_usb_devices` filter it by
interface class, so the scripts branch on what the device *is* rather than
guessing. Amazon hardware reports itself as `Lab126`, not `Amazon` or `Kindle`,
so string matching covers all three plus vendor ID `1949`.

`kindle_usb_bound` and `kindle_usb_storage_loaded` exist to distinguish "no
Kindle attached" from "Kindle attached but the kernel never claimed it", which
is what the diagnostics in `kindle-mount.sh` are built on.

### Three ways to find a printer, and the one fact that ties them together

A printer is found on the USB bus (interface class 07, the printer class),
over mDNS (`_ipp._tcp` and friends) and by sweeping the subnet for ports
9100, 631 and 515. Each misses a different printer: mDNS does not cross
subnets or client isolation and a deeply asleep printer advertises nothing,
while a port sweep finds printers with mDNS switched off.

The fact that makes the three one picture: **a modern printer on a cable is
also an IPP network printer.** USB printer-class protocol `04` is
IPP-over-USB, and `ipp-usb(8)` republishes such a device as an IPP service
on loopback, advertised over mDNS with the real USB serial in its TXT
record. So one printer appears twice — once on the bus, once at `127.0.0.1`
— and `usb_SER` is what proves the two records are the same unit.
`printer-find.sh` folds them into one candidate on that key, which is why
candidates are keyed by USB serial rather than by address. Protocol `02` is
the older bidirectional interface that CUPS drives through a `usb://` URI;
the IPP route is preferred wherever the printer offers it, because it is
driverless and reports state back.

Two details that only live hardware reveals, both already handled:

- `avahi-browse -p` escapes with **decimal** `\NNN`, not octal, so
  `HP\032Smart` is `HP Smart` and `\0916E0508\093` is `[6E0508]`.
  `printf '%b'` speaks octal, so `printer_unescape` converts.
- `avahi-browse -p` prints a *human description* in the service-type field
  for well-known types — `Internet Printer` for `_ipp._tcp`, `UNIX Printer`
  for `_printer._tcp` — so the type a caller gets back is the one that was
  browsed for, not the one avahi printed. And `ipp-usb` advertises
  `_printer._tcp` on **port 0**, meaning "this exists but do not print to
  it here"; those records are dropped.

### One webcam, four device nodes, and only one of them is the camera

The fact that makes camera detection worth a library at all. Measured on the
internal Integrated Webcam FHD (vendor `0bda`, product `5586` — one serial
across all four nodes):

| node | `ID_V4L_CAPABILITIES` | formats | what it is |
| --- | --- | --- | --- |
| `/dev/video0` | `:capture:` | MJPG, YUYV | the camera |
| `/dev/video1` | `:` | none | UVC metadata |
| `/dev/video2` | `:capture:` | GREY only | infrared sensor |
| `/dev/video3` | `:` | none | UVC metadata |

Two separate traps live in that table, and both have bitten this code:

- **The metadata nodes do not capture.** UVC registers a second node per
  stream for per-frame metadata; opening it yields no image. udev labels
  them — `ID_V4L_CAPABILITIES` is `:capture:` for a real capture node and a
  bare `:` for metadata — which is what `camera_capture_nodes` filters on.
  The numbering interleaves, so "the lowest `/dev/video*`" is right here only
  by luck and `video1` is wrong on every such webcam.
- **The infrared sensor is a capture node too**, correctly so, and *no udev
  property tells it from the colour camera*. It is the face-recognition
  camera, it offers `GREY` and nothing else, and software that opens it shows
  a dim grey picture indistinguishable from broken hardware. The two differ
  only in the pixel formats they enumerate, which takes a `VIDIOC_ENUM_FMT`
  ioctl bash cannot make. So `camera_node_kind` asks `v4l2-ctl` (package
  `v4l-utils`) when it is installed and reports `colour` or `ir`; without it,
  it falls back on USB interface order within one serial (`:1.0` before
  `:1.2`) and reports `unknown` rather than claiming a reading it did not
  take. Callers can therefore tell a measurement from an inference.

Preference across the three kinds is `colour`, then `unknown`, then `ir`, and
it **cannot** be a sort on the kind field: `ir` sorts before `unknown`
alphabetically, which once put the infrared sensor at the head of
`camera-open.sh --list` and so at the head of the ffmpeg pipeline its own help
recommends. `ranked_capture_nodes` makes the rank explicit for that reason.

Two further facts measured on this host, both of which `camera-record.sh`
depends on:

- **ffmpeg exits 255 when a capture is interrupted, and the file is fine.**
  SIGINT finalises the output properly — a run cut off at 0.6s produced valid,
  playable H.264 — but under `set -e` that non-zero status aborts the script
  before it can report, so an ordinary Ctrl-C looks like a failure. 255 and
  130 are therefore treated as a normal stop when no `--duration` was given.
  Beware measuring this through a pipeline: `tail`'s status reads 0 and
  `timeout`'s reads 124, so it takes `timeout --preserve-status` or a direct
  signal to see ffmpeg's own code.
- **GNOME Camera being open does not hold `/dev/video0`.** It streams through
  PipeWire, so `fuser` reports no holder and a concurrent ffmpeg capture
  succeeds — verified with both running at once. The `EX_BUSY` check in
  `camera-record.sh` therefore fires only for a genuine second reader of the
  node, not for the GUI.

### Conventions that cross files

- **stdout is the result, stderr is the conversation.** The mount script prints
  only the mountpoint on stdout, so `cd "$(kindle-mount.sh -q)"` works. Every
  log line goes to stderr via `info`/`ok`/`warn`/`err`. Never `echo` a
  diagnostic to stdout.
- **Every side effect goes through `run` or `as_root`**, which honour `DRY_RUN`
  and `DEVICES_DEBUG`. Calling `mount`, `modprobe` or `fusermount3` directly
  breaks `--dry-run`.
- **`as_root` escalates only when needed** — it is a no-op when already root and
  dies with a clear message when `sudo` is absent. Prefer a strategy that needs
  no root at all (`udisksctl`, FUSE) and fall back to `mount(8)`.
- **Report honestly under `--dry-run`**: success messages use
  `verb mount mounted` so a dry run says "would mount", never "mounted".
- **Exit with the `EX_*` constants**, not literals: `EX_USAGE=2`, `EX_NODEV=3`
  (no device found), `EX_BUSY=4` (something holds the mount open). `die -"$EX_USAGE" msg`
  sets the code.
- **External tools are optional, not required.** Gate every one on `have`, and
  degrade with an explanation rather than failing — `udisksctl`, `gio`,
  `fusermount3`, `fuser`/`lsof` and the MTP helpers are all treated this way.
- Unmount paths always `sync_disks` first.

### Adding another device

Add `linux/lib/<device>.sh` for detection following the record protocol, and
`linux/<device>/<device>-mount.sh` / `-unmount.sh` reusing
`linux/lib/common.sh`. Copy the `ROOT_DIR` resolution header verbatim — it
resolves symlinks so the scripts work when linked onto `PATH`, and it is what
keeps the libraries reachable as `$ROOT_DIR/lib/...` from one level down.

Entry scripts are committed mode `100755`; the libraries stay `100644` because
they are sourced, not executed. Check with `git ls-files -s` after adding one.
