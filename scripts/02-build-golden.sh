#!/bin/bash
# Build a SIZED bootable factory image (12G disk) from an installed source disk.
# This is the one-time FACTORY cost (runs in ISO build). Output: golden12disk.raw
# = GPT [ESP 2G | root 10G btrfs], UKI + limine copied from source, btrfs UUID
# forced to the source's so the copied UKI (root=UUID=) boots as-is.
set -euo pipefail
TURBO="${TURBO:-$(pwd)/work}"
SRC_QCOW=${1:?usage: build-golden.sh <source-disk.qcow2>}
OUT=${2:-${TURBO}/golden12disk.raw}
W=/dev/shm/goldenbuild
log(){ printf '==> [%s] %s\n' "$(date +%H:%M:%S)" "$1"; }
cleanup(){ umount $W/srcesp $W/srcroot $W/dstesp $W/dstroot 2>/dev/null || true
  qemu-nbd -d /dev/nbd4 >/dev/null 2>&1 || true
  L=$(losetup -j $OUT 2>/dev/null|cut -d: -f1); [ -n "${L:-}" ] && losetup -d $L || true; }
trap cleanup EXIT
rm -rf $W; mkdir -p $W/{srcesp,srcroot,dstesp,dstroot}

qemu-nbd -c /dev/nbd4 --read-only "$SRC_QCOW"; sleep 1; partprobe /dev/nbd4; sleep 1
SRC_UUID=$(blkid -s UUID -o value /dev/nbd4p2)
SRC_PARTUUID=$(blkid -s PARTUUID -o value /dev/nbd4p2)
SRC_ESP_UUID=$(blkid -s UUID -o value /dev/nbd4p1 | tr -d -)   # FAT serial, no dash
log "source btrfs UUID = $SRC_UUID  root PARTUUID = $SRC_PARTUUID  ESP FAT = $SRC_ESP_UUID"
mount -o ro /dev/nbd4p1 $W/srcesp
mount -o ro,subvol=@factory /dev/nbd4p2 $W/srcroot

rm -f $OUT; truncate -s 12G $OUT
sgdisk -Z $OUT >/dev/null 2>&1 || true
# p2 PARTUUID must equal the source's: the copied UKI boots via root=PARTUUID=
# and the boot reference is baked into the UKI, not read from the partition.
sgdisk -n 1:2048:+2G -t 1:EF00 -n 2:0:0 -t 2:8304 -u 2:$SRC_PARTUUID $OUT >/dev/null
losetup -fP $OUT; LO=$(losetup -j $OUT|cut -d: -f1)
log "golden disk $LO : $(sgdisk -p $OUT | grep -E '^\s+[12]' | tr -s ' ')"

# ESP FAT serial must match the source: fstab mounts /boot by UUID=<fat serial>,
# else systemd blocks ~90s on the missing dev-disk-by-uuid device at boot.
mkfs.fat -F32 -i "$SRC_ESP_UUID" ${LO}p1 >/dev/null
mkfs.btrfs -q -f -U "$SRC_UUID" ${LO}p2      # force source UUID so UKI matches
mount ${LO}p2 $W/dstroot
# recreate the FULL subvol layout fstab expects: @, @home, @log, @pkg.
# Missing ones fail their mounts at boot and stall systemd (measured).
for sv in @ @home @log @pkg; do btrfs subvolume create $W/dstroot/$sv >/dev/null; done
cp -a --reflink=never $W/srcroot/. $W/dstroot/@/ 2>/dev/null || \
  (cd $W/srcroot && tar cf - .) | (cd $W/dstroot/@ && tar xf -)
# factory-reset snapshot, CoW so it adds no bytes to the raw image
btrfs subvolume snapshot -r $W/dstroot/@ $W/dstroot/@factory >/dev/null
# swapfile is NOT baked (would add real GBs to the dd); swap unit will degrade
# harmlessly until first-boot provisioning creates it. Documented, not silent.
# ESP: straight copy (UKI + limine + bootloader)
mount ${LO}p1 $W/dstesp
(cd $W/srcesp && tar cf - .) | (cd $W/dstesp && tar xf -)
sync
PKGS=$(ls $W/dstroot/@/var/lib/pacman/local 2>/dev/null | wc -l)
DATA=$(du -sh --apparent-size $W/dstroot/@ 2>/dev/null | cut -f1)
log "golden poblado: pkgs=$PKGS data=$DATA UKI=$(ls $W/dstesp/EFI/Linux/ 2>/dev/null)"
[ "$PKGS" -ge 930 ] || { log "GOLDEN_FAIL pkgs=$PKGS"; exit 1; }
umount $W/dstesp $W/dstroot $W/srcesp $W/srcroot; losetup -d $LO; qemu-nbd -d /dev/nbd4
log "GOLDEN_DONE $OUT ($(du -h $OUT|cut -f1) sparse)"
