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
mkfs.fat -F32 -n OMARCHYESP -i "$SRC_ESP_UUID" ${LO}p1 >/dev/null
mkfs.btrfs -q -f -L omarchy_root -U "$SRC_UUID" ${LO}p2      # force source UUID so UKI matches
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
# --- E5b: boot references by LABEL, so every install can regenerate its
# PARTUUIDs and btrfs UUID without rebuilding the UKI. A label is a name,
# not an identity: constant across installs by design (like "EFI" on ESPs).
UKI=$W/dstesp/EFI/Linux/omarchy_linux.efi
objcopy -O binary --only-section=.cmdline "$UKI" $W/cmdline.bin
tr -d '\0' < $W/cmdline.bin > $W/cmdline.txt
sed -E 's#root=(UUID|PARTUUID)=[^ ]+#root=LABEL=omarchy_root#; s# resume=[^ ]+##; s# resume_offset=[^ ]+##' $W/cmdline.txt > $W/cmdline.new
grep -q "root=LABEL=omarchy_root" $W/cmdline.new || { log "GOLDEN_FAIL uki-cmdline sin root="; exit 1; }
objcopy --update-section .cmdline=$W/cmdline.new "$UKI"
sed -i -E 's#root=(UUID|PARTUUID)=[^ ]+#root=LABEL=omarchy_root#g; s# resume=[^ ]+##g; s# resume_offset=[^ ]+##g' $W/dstesp/limine.conf 2>/dev/null || true
# limine also pins the UKI by BLAKE2B in the entry path (file.efi#<hash>);
# after editing the UKI its hash changed, so update it or limine invalidates
# the entry and waits forever in its menu (measured).
NEWB2=$(b2sum "$UKI" | cut -d" " -f1)
sed -i -E "s|(omarchy_linux\.efi#)[0-9a-f]{128}|\1${NEWB2}|" $W/dstesp/limine.conf
grep -q "$NEWB2" $W/dstesp/limine.conf || { log "GOLDEN_FAIL uki-path-hash no actualizado"; exit 1; }
# limine verifies an enrolled BLAKE2B of its config; re-enroll after editing
# it or the bootloader halts silently in firmware (measured).
B2=$(b2sum $W/dstesp/limine.conf | cut -d" " -f1)
for EB in EFI/limine/limine_x64.efi EFI/BOOT/BOOTX64.EFI; do
  [ -f $W/dstesp/$EB ] || continue
  cp $W/dstesp/$EB $W/dstroot/@/tmp/limine-enroll.efi
  chroot $W/dstroot/@ /usr/bin/limine enroll-config --reset --quiet /tmp/limine-enroll.efi >/dev/null 2>&1 || true
  chroot $W/dstroot/@ /usr/bin/limine enroll-config --quiet /tmp/limine-enroll.efi "$B2" || { log "GOLDEN_FAIL limine-enroll $EB"; exit 1; }
  cp $W/dstroot/@/tmp/limine-enroll.efi $W/dstesp/$EB
done
rm -f $W/dstroot/@/tmp/limine-enroll.efi
log "E5b: BLAKE2B de limine.conf re-enrolado en limine_x64 y BOOTX64"
FSTAB=$W/dstroot/@/etc/fstab
sed -i -E "s#^UUID=${SRC_UUID}#LABEL=omarchy_root#" $FSTAB
sed -i -E "s#^UUID=[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}([[:space:]]+/boot)#LABEL=OMARCHYESP\1#" $FSTAB
grep -q "LABEL=omarchy_root" $FSTAB || { log "GOLDEN_FAIL fstab sin LABEL"; exit 1; }
log "E5b: UKI+limine+fstab reescritos a root/mounts por LABEL"

sync
PKGS=$(ls $W/dstroot/@/var/lib/pacman/local 2>/dev/null | wc -l)
DATA=$(du -sh --apparent-size $W/dstroot/@ 2>/dev/null | cut -f1)
log "golden poblado: pkgs=$PKGS data=$DATA UKI=$(ls $W/dstesp/EFI/Linux/ 2>/dev/null)"
[ "$PKGS" -ge 930 ] || { log "GOLDEN_FAIL pkgs=$PKGS"; exit 1; }
umount $W/dstesp $W/dstroot $W/srcesp $W/srcroot; losetup -d $LO; qemu-nbd -d /dev/nbd4
log "GOLDEN_DONE $OUT ($(du -h $OUT|cut -f1) sparse)"
