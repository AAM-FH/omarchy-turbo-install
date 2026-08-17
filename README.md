# omarchy-turbo-install

**Proof of concept: a full Omarchy Quattro install (939 packages) in under 6
seconds, power-on to reboot, boot-verified, with unique per-install identity:
from a 4.0GB one-file image, 37% smaller than the official 6.3GB ISO.**
Same bits, same result as the official installer: the work just happens once,
at image-build time, instead of on every machine. Smaller download AND faster
install from the same structural change: shipping the installed system beats
shipping the ingredients (the official ISO carries a full live environment
plus an uncompressed package mirror; this carries a 25MB installer plus the
compressed final system).

Measured on the same bench, same VM, same clock (QEMU/KVM on a bare-metal
Ryzen 9 5950X, disk in RAM, timed externally from power-on to the guest's own
post-install reboot):

| Path | power-on → reboot | N |
|---|---|---|
| Official Quattro installer (offline ISO) | **139.7s** p50 (123-168) | 10 |
| Golden-image install (this repo) | **10.26s** p50, 9.02s best | 6 |
| + unique per-install identity, sized+compressed image, parallel copy | **5.61s best, p50 5.80s** (warm, idle host) | 10 |

The installed system boots to a login prompt with a fresh unique machine-id,
resized to fill the real disk, all 939 packages present in pacman's db.

## Why it works

Profiling the official installer (per-phase, per-package, per-subprocess)
shows the 85-second package phase is a serial, single-core pipeline: zstd
decompression, file-by-file extraction, pacman db fsyncs, hooks: with **zero
I/O pressure and no benefit from more cores** (measured: 4 vCPUs = 32 vCPUs).
The install result is identical every time, so this PoC builds that final
disk state once (**from the official ISO, on your machine**) and then
installing becomes a sequential block copy plus a handful of fixups:
the only workload modern hardware finishes in seconds.

This is the same distribution model used by ChromeOS, SteamOS, Android
factory images, Windows OEM (sysprep) and every cloud VM image: golden image,
grow-to-fit, first-boot identity and provisioning.

## Run it

```sh
# any Linux with KVM and ~24G of free RAM; everything happens inside VMs and
# ./work, your system is never touched. Dependencies (apt or pacman) and the
# official ISO are fetched automatically.
git clone https://github.com/AAM-FH/omarchy-turbo-install
cd omarchy-turbo-install
sudo ./run-all.sh
```

Already have the ISO? `sudo ./run-all.sh /path/to/omarchy-4.0.0.iso`.

Step 2 runs the official unattended installer once (~2.5 min on fast
hardware): that is both your baseline number and the source of the golden
image. Step 5 prints the golden-image number. Step 6 boots the result.

## What the ~6s does and does not include

Executed at install time: block copy of the image, GPT relocation and
partition grow to the real disk, btrfs resize, machine-id reset, ssh host
key removal, first-boot provisioning armed, reboot.

Deferred to first boot (seconds, using Omarchy's own deferred-provisioning
mechanism): user creation, ssh host key regeneration, swapfile.

Per-install identity is SOLVED (no UKI rebuild needed): the factory rewrites
the UKI cmdline, limine.conf and fstab to reference the root by LABEL, then
re-pins limine's two tamper checks (the enrolled BLAKE2B of its config and
the BLAKE2B in the UKI entry path). At install time `sgdisk -G` regenerates
the disk GUID and all PARTUUIDs and `btrfstune` gives the filesystem a fresh
UUID: ~1.3s, asserted fail-loud against the golden on every benchmark run,
and boot-verified through limine to a login prompt.

Also verified:
- Package db coherence: `pacman -Sy` syncs against real mirrors and `-Sup`
  resolves upgrades cleanly on an imaged system; `pacman -Qk` reports 935/939
  packages with zero missing files (the 4 flagged are the ssh host keys this
  PoC deletes on purpose so they regenerate per install).
- LUKS mechanism: the golden root streamed through dm-crypt lands intact
  (939 packages readable after unlock). Throughput on this bench is not
  representative (dm-crypt over loop over tmpfs serializes on one writeback
  flusher); on real NVMe dm-crypt scales across cores at GB/s.

Known open items, deliberately not hidden:
- Real-hardware runs: numbers above are QEMU/KVM. Relative gains should
  survive; absolute numbers will differ.
- Product integration: the image should ship inside the ISO (replacing the
  offline package mirror, zstd-compressed, similar size) rather than as a
  second disk. The configurator flow stays as-is: this replaces only what
  happens after you hit install.

## The one-file product test

`scripts/06-build-turbo-usb.sh` builds **omarchy-turbo-usb.img (4.0GB, smaller
than the official 6.3GB ISO)**: a single flashable file carrying the
mini-installer plus the golden image as four parallel zstd frames. Flash it,
boot any UEFI PC from it, and it finds the internal disk (never the USB
itself), streams the image through parallel decompression, regenerates
identity and reboots into the installed system.

VM-verified end to end: power-on to installed-and-rebooting in **17.7s**
(copy 12.3s), and the resulting internal disk boots to login with a fresh
machine-id. On real hardware the number is bounded by USB read speed:
~4GB to read, so a 400MB/s stick adds ~10s and a USB-NVMe enclosure adds ~2s.
WARNING: it wipes the largest non-USB disk it finds, by design: speedrun
semantics, not a polite installer.

## Layout

- `run-all.sh`: the whole chain, one command.
- `scripts/00-extract-airootfs.sh`: unpack the official airootfs.
- `scripts/01-source-install.sh`: unattended official install in QEMU
  (adapted from omarchy-iso's own integration test harness).
- `scripts/02-build-golden.sh`: golden 12G disk image (ESP + btrfs with the
  full subvolume layout, factory snapshot included) from that install.
- `scripts/03-build-mini-installer.sh`: 25MB UKI (systemd stub + 7.8MB
  initramfs with dd/sgdisk/sfdisk/btrfs taken from the airootfs; the Omarchy
  kernel has virtio and btrfs built in).
- `scripts/04-benchmark.sh`: power-on → reboot wall clock.
- `scripts/05-boot-verify.sh`: boots the installed disk to `login:`.
- `scripts/06-build-turbo-usb.sh`: the one-file flashable product image.

MIT, like Omarchy itself. Derived from and grateful to
[basecamp/omarchy](https://github.com/basecamp/omarchy) and
[omacom-io/omarchy-iso](https://github.com/omacom-io/omarchy-iso).
