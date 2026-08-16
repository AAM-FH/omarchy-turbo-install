#!/bin/bash
# Extract the airootfs from the official Omarchy ISO. Needed once: the mini
# installer borrows the kernel, the systemd EFI stub and a handful of tools
# (dd, sgdisk, sfdisk, btrfs) from it, so everything you run is built from
# the exact bits Omarchy ships.
set -euo pipefail
TURBO="${TURBO:-$(pwd)/work}"
ISO=${1:?usage: 00-extract-airootfs.sh <omarchy-official.iso>}
command -v unsquashfs >/dev/null || { echo "FALTA squashfs-tools"; exit 1; }
mkdir -p $TURBO
MNT=$(mktemp -d)
trap 'umount $MNT 2>/dev/null; rmdir $MNT 2>/dev/null' EXIT
mount -o loop,ro "$ISO" $MNT
SFS=$(find $MNT -name airootfs.sfs | head -1)
[ -n "$SFS" ] || { echo "airootfs.sfs no encontrado en el ISO"; exit 1; }
rm -rf $TURBO/airootfs-root
unsquashfs -d $TURBO/airootfs-root -p "$(nproc)" "$SFS"
echo "EXTRACT_DONE: $TURBO/airootfs-root"
