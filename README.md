# devices

A shell script suite to setup, mount and unmount devices connected to Linux.

```
lib/common.sh            logging, dry-run, privilege escalation, mount-table helpers
lib/kindle.sh            Kindle detection (USB mass storage and MTP)
kindle/kindle-mount.sh   mount a Kindle, print its mountpoint
kindle/kindle-unmount.sh flush and unmount a Kindle, optionally power it off
```

Requires bash 4.2 or newer. `udisksctl`, `gio`, `fusermount3` and an MTP helper
are used when present, never required.

## Kindle

Kindles come in two flavours and the scripts handle both:

| Flavour | Models | How it appears |
| --- | --- | --- |
| USB mass storage | Basic, Voyage, Oasis, Paperwhite up to 11th gen | a vfat partition, e.g. `/dev/sdb1` |
| MTP | Scribe, Colorsoft, Paperwhite 2024 and later | no block device; needs a FUSE helper |

### Mount

```bash
./kindle/kindle-mount.sh
```

The mountpoint is printed on stdout and everything else goes to stderr, so it
composes:

```bash
cp book.epub "$(./kindle/kindle-mount.sh -q)/documents/"
```

Useful options:

```bash
./kindle/kindle-mount.sh -w 30            # plug the cable in, then wait for it
./kindle/kindle-mount.sh -m ~/mnt/kindle  # mount at a fixed path
./kindle/kindle-mount.sh -r               # read-only
./kindle/kindle-mount.sh -M               # load usb-storage first, if needed
./kindle/kindle-mount.sh -n               # dry run, change nothing
```

A mass-storage Kindle is mounted through `udisksctl` when possible, so no root
is needed; udisks picks the path, usually `/run/media/$USER/Kindle`, and the
script reports whichever it chose. Giving `-m` switches to `mount(8)`, which
needs `sudo` and defaults to `/media/$USER/<label>`. An MTP Kindle is mounted
with `jmtpfs`, `simple-mtpfs` or `go-mtpfs` under `$XDG_RUNTIME_DIR/kindle`; if
the desktop already mounted it through gvfs, that path is reported instead.

### Unmount

```bash
./kindle/kindle-unmount.sh        # find it and unmount it
./kindle/kindle-unmount.sh -e     # unmount, power the USB disk off, ready to unplug
./kindle/kindle-unmount.sh -a     # unmount every Kindle mount found
./kindle/kindle-unmount.sh -f     # lazy unmount as a last resort when busy
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
