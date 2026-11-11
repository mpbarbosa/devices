# devices

Scripts for the devices I plug into this machine: a bash suite that sets up,
mounts and unmounts devices connected to Linux, plus the Windows-side material
for the same hardware on the same laptop booted the other way.

The tree is split by host platform, not by device:

```
linux/lib/common.sh                 logging, dry-run, privilege escalation, mount-table helpers
linux/lib/kindle.sh                 Kindle detection (USB mass storage and MTP)
linux/lib/mpd218.sh                 AKAI MPD218 detection (ALSA MIDI port, USB presence)
linux/kindle/kindle-mount.sh        mount a Kindle, print its mountpoint
linux/kindle/kindle-unmount.sh      flush and unmount a Kindle, optionally power it off
linux/mpd218/mpd218-config.sh       read, edit and write MPD218 presets over SysEx
linux/mpd218/mpd218-synth.sh        route the MPD218 into FluidSynth so it is audible
windows/mpd218/first_preset.mpd218  Akai MPD218 pad preset, a sysex dump
windows/mpd218/midimon.ps1          print what a MIDI controller is actually sending
windows/clock/fix-clock-utc.ps1     stop the clock booting three hours fast
```

`linux/` needs bash 4.2 or newer; `udisksctl`, `gio`, `fusermount3` and an MTP
helper are used when present, never required. `windows/` needs PowerShell 5.1,
which ships with Windows.

## Kindle (Linux)

Kindles come in two flavours and the scripts handle both:

| Flavour | Models | How it appears |
| --- | --- | --- |
| USB mass storage | Basic, Voyage, Oasis, Paperwhite up to 11th gen | a vfat partition, e.g. `/dev/sdb1` |
| MTP | Scribe, Colorsoft, Paperwhite 2024 and later | no block device; needs a FUSE helper |

### Mount

```bash
./linux/kindle/kindle-mount.sh
```

The mountpoint is printed on stdout and everything else goes to stderr, so it
composes:

```bash
cp book.epub "$(./linux/kindle/kindle-mount.sh -q)/documents/"
```

Useful options:

```bash
./linux/kindle/kindle-mount.sh -w 30            # plug the cable in, then wait for it
./linux/kindle/kindle-mount.sh -m ~/mnt/kindle  # mount at a fixed path
./linux/kindle/kindle-mount.sh -r               # read-only
./linux/kindle/kindle-mount.sh -t mtp           # skip detection, force a flavour
./linux/kindle/kindle-mount.sh -M               # load usb-storage first, if needed
./linux/kindle/kindle-mount.sh -n               # dry run, change nothing
```

A mass-storage Kindle is mounted through `udisksctl` when possible, so no root
is needed; udisks picks the path, usually `/run/media/$USER/Kindle`, and the
script reports whichever it chose. Giving `-m` switches to `mount(8)`, which
needs `sudo` and defaults to `/media/$USER/<label>`. An MTP Kindle is mounted
with `jmtpfs`, `simple-mtpfs` or `go-mtpfs` under `$XDG_RUNTIME_DIR/kindle`; if
the desktop already mounted it through gvfs, that path is reported instead.

### Unmount

```bash
./linux/kindle/kindle-unmount.sh        # find it and unmount it
./linux/kindle/kindle-unmount.sh -e     # unmount, power the USB disk off, ready to unplug
./linux/kindle/kindle-unmount.sh -a     # unmount every Kindle mount found
./linux/kindle/kindle-unmount.sh -f     # lazy unmount as a last resort when busy
```

Always syncs before unmounting. When something still has files open, the
offending processes are listed (via `fuser` or `lsof`) instead of forcing the
unmount behind your back.

### If nothing is found

`kindle-mount.sh` reports what it saw on the USB bus and why it could not use
it. The common causes are a charge-only cable, a Kindle that has not been woken
and unlocked, a missing MTP helper, or the `usb-storage` kernel module not being
loaded — in which case a mass-storage Kindle is on the bus with no kernel driver
attached and no block device to mount:

```bash
sudo modprobe usb-storage
```

To make that stick across reboots:

```bash
echo usb-storage | sudo tee /etc/modules-load.d/usb-storage.conf
```

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | mounted / unmounted, or already in that state |
| 1 | failure |
| 2 | bad usage |
| 3 | no Kindle found |
| 4 | busy, something has files open |

### Environment

`KINDLE_MOUNTPOINT`, `KINDLE_LABEL`, `KINDLE_MOUNT_OPTIONS`, `NO_COLOR`,
`DEVICES_DEBUG=1` for the commands being run.

## AKAI MPD218 (Linux)

A pad controller rather than a storage device, so there is nothing to mount: it
is configured over SysEx. The heavy lifting is done by
[mungewell/mpd-utils](https://github.com/mungewell/mpd-utils) (GPL-2.0), which
is **not vendored here** -- it carries its own git history and a
machine-specific virtualenv. Clone it separately and point `MPD_UTILS_DIR` at
it:

```bash
git clone https://github.com/mungewell/mpd-utils.git ~/Documents/GitHub/mpd-utils
cd ~/Documents/GitHub/mpd-utils
uv venv .venv
uv pip install --python .venv/bin/python construct qprompt
```

`construct` is the only hard requirement. `qprompt` adds the interactive pad,
dial, division and swing editors; `music_essentials` (git only, not on PyPI)
adds the scale editor.

### Usage

```bash
./linux/mpd218/mpd218-config.sh port              # raw ALSA port, for amidi
./linux/mpd218/mpd218-config.sh seq               # sequencer address, for aconnect
./linux/mpd218/mpd218-config.sh backup            # all 16 presets into a dated dir
./linux/mpd218/mpd218-config.sh read 1 work.mpd218
./linux/mpd218/mpd218-config.sh dump work.mpd218
./linux/mpd218/mpd218-config.sh edit -P 1 -o new.mpd218 work.mpd218
./linux/mpd218/mpd218-config.sh write new.mpd218
```

`edit` passes its arguments straight to `mpd218.py`, so every upstream flag
works. The preset slot a file lands in is recorded inside the file; change it
with `edit -p N`. Writing to the slot currently selected takes effect at once.

`backup-2026-11-10/` holds this laptop's factory presets, read-only. Restore
with:

```bash
for f in linux/mpd218/backup-2026-11-10/preset_*.mpd218; do
    ./linux/mpd218/mpd218-config.sh write "$f"; sleep 1
done
```

### Device facts worth knowing

Two things the upstream README gets wrong on this hardware, both already
handled by the script:

- Presets are addressed `0x01`..`0x10`. Index `0x00` is **not** "current
  preset" on the MPD218 -- that is MPD226 behaviour. It answers with a short
  51-byte stub rather than a config.
- A bare `amidi -p PORT -S ... -r file` yields **597 bytes, not 549**: the ALSA
  port hands over buffered performance MIDI the first time it is opened and
  that gets prepended to the reply, silently corrupting the dump. The script
  drains the port first, then locates the reply by its `F0 47 00 34` header.

A valid preset dump is exactly 549 bytes. Card numbers move between reboots, so
the port is always resolved at run time and never stored.

`construct` 2.10.70 is used although upstream asks for 2.9; it parses and
re-emits a device dump byte-identically, which is the check that matters before
writing to hardware.

### No sound?

The MPD218 has no sound engine -- it only emits MIDI. Hearing nothing is normal,
and on this laptop there were two separate reasons for it:

1. **Nothing was listening.** `aconnect -l` showed the MPD218 with no
   `Connecting To:` line, and no softsynth was installed.
2. **The notes were inaudible.** Bank A on the presets this unit shipped with
   sends notes 0-15 (C-1 to D#0) on channel 1 -- below most instrument ranges
   and at the bottom edge of hearing. A conventional MPC mapping starts at note
   36 (C2).

`mpd218-synth.sh` handles both. It starts FluidSynth and connects the
controller to it, and where the notes are out of range it can shift them with
FluidSynth's own MIDI router, leaving the presets on the device untouched:

```bash
sudo apt install fluidsynth          # one-off; the GM SoundFont is already present
./linux/mpd218/mpd218-synth.sh       # Ctrl-C to stop
```

It runs in the foreground and prints what it chose, then hands over to
FluidSynth's own command shell:

```
device    20:0
soundfont /usr/share/sounds/sf2/default-GM.sf2
transpose 0 semitones
audio     pipewire
connected 20:0 -> 128:0
hit the pads. Ctrl-C to stop.
```

Verified on this laptop: `pw-link -l` shows `FluidSynth:output_FL/FR` wired to
`alsa_output...analog-stereo`, and drum hits sent into the synth with
`aplaymidi` reach the speakers.

FluidSynth 2.4.8 prints four `GLib-GObject-CRITICAL` assertion warnings at
startup. They are harmless, and come from its own option handling.

The audio driver is `pipewire` by default, with no probe and no fallback list.
That is deliberate: there is no string that reliably means the driver opened.
FluidSynth announces each one differently -- `Using PipeWire audio driver` but
`Using PulseAudio driver` -- and the ALSA driver announces nothing at all while
still working, so an earlier version of this script that guessed from those
messages got it wrong in both directions. If there is no sound, pass
`--audio pulseaudio` or `--audio alsa`; FluidSynth's own complaint is clearer
than anything this script could infer.

The synth is left in the foreground on purpose: given `-i` (no shell) and no
MIDI file to play, FluidSynth has nothing to do and exits immediately, so its
command shell is what keeps it alive. The ALSA connection is therefore made by
a helper forked before the synth is `exec`'d, which waits for the synth's
sequencer port to appear.

Nothing is transposed by default, because **the MPD218 gives no way to ask
which preset is selected** -- sysex index `0x00` is not "current preset" on this
model -- so a blind shift would break whichever presets are already in range:

| Preset on the device | Pads send | Transpose needed |
| --- | --- | --- |
| `chroma10` (`windows/mpd218/first_preset.mpd218`) | notes 36-51, channel 10 | none; channel 10 is the GM drum map, so it is a kit |
| the VirtualDJ presets in `backup-2026-11-10/` | notes 0-15, channel 1 | `--transpose 36`, which moves bank A to C2..D#3 |

So if the pads are silent, pass `--transpose 36`. The audio driver is tried in
the order `pipewire`, `pulseaudio`, `alsa`; pin one with `--audio` if the guess
is wrong.

The shift lives in the synth rather than in a preset deliberately: writing a
preset would replace a slot on the device, and in the VirtualDJ mapping the note
numbers are control identifiers rather than pitches, so transposing them there
would break the mapping instead of fixing the sound.

> Slot 1 on this unit now holds `chroma10`, not the VirtualDJ preset it shipped
> here with. `backup-2026-11-10/preset_01.mpd218` is the only remaining copy of
> the original, which is why the backup is checked in read-only.

To see whether the hardware is sending anything at all, independent of audio:

```bash
aseqdump -p "$(./linux/mpd218/mpd218-config.sh -q seq)"   # Ctrl-C to stop
```

## Windows

PowerShell 5.1, one directory per device plus host configuration that belongs
to no device. Each script carries a `-?` help block, and anything with side
effects takes `-WhatIf`, which is the `-n` of the bash half.

### MPD218

`first_preset.mpd218` is the pad preset: pads 1-16 on notes 36-51, MIDI
channel 10. It is a sysex dump, kept `binary` in `.gitattributes` so git never
rewrites the bytes.

```powershell
.\windows\mpd218\midimon.ps1                    # 30 s, first MPD218 port
.\windows\mpd218\midimon.ps1 -Seconds 60 -Show 100
.\windows\mpd218\midimon.ps1 -Device 'nanoKEY2'
```

`midimon.ps1` opens the MIDI input port through winmm and logs what arrives,
independently of any DAW — which is how to tell what the hardware transmits
from what an editor claims it transmits. The two usually disagree: the editor's
`File > Save` writes a file and nothing else, so a preset only reaches the pads
through `File > Send To Hardware`, and the unit's PAD BANK button then shifts
the whole range anyway (bank C sends 68-83). Because opening the port only
succeeds when nothing else holds it, a `MMSYSERR_ALLOCATED` failure is itself
the answer when a DAW has grabbed the device.

### Clock

```powershell
.\windows\clock\fix-clock-utc.ps1 -WhatIf   # show every change, make none
.\windows\clock\fix-clock-utc.ps1           # elevated shell required
```

On a machine that dual-boots, Linux keeps the real-time clock in UTC, the
systemd default, while Windows assumes it holds local time. Windows therefore
reads the UTC hour off the hardware and believes it is local, so the clock boots
exactly three hours fast here and the desktop shows UTC.

The script sets `RealTimeIsUniversal` so Windows agrees with Linux about what
the RTC means, and repairs `w32time`, which ships pointed at `time.windows.com`
alone with a 4.5 hour poll interval: it adds NTP.br stratum 1 and polls hourly.
The opposite fix, `timedatectl set-local-rtc 1` on the Linux side, is
deliberately not used — a local-time RTC has no way to express a DST change.

A Windows feature update can reset `RealTimeIsUniversal`. If the clock is ever
exactly three hours fast again, check that value before suspecting the timezone,
which was never wrong.
