#!/bin/bash
# Build the E8 mini-installer: tiny initramfs (busybox + partition/btrfs tools
# from the omarchy airootfs) + UKI (systemd stub) + bootable ESP disk image.
# Boot chain stays honest: OVMF -> \EFI\BOOT\BOOTX64.EFI (UKI) -> /init.
set -euo pipefail
TURBO="${TURBO:-$(pwd)/work}"
AR=${TURBO}/airootfs-root
KVER=7.1.8-arch1-Watanare-T2-2-t2
OUT=${TURBO}/mini
W=/dev/shm/minibuild
log(){ printf '==> [%s] %s\n' "$(date +%H:%M:%S)" "$1"; }
rm -rf $W $OUT; mkdir -p $W/ir/{bin,dev,proc,sys,mnt,usr/lib,usr/bin} $OUT

command -v busybox >/dev/null || { DEBIAN_FRONTEND=noninteractive apt-get install -y -q busybox-static >/dev/null; }
cp "$(command -v busybox)" $W/ir/bin/busybox
for a in sh dd mount umount sync reboot blockdev mkdir cut cat rm ls sleep; do ln -s busybox $W/ir/bin/$a; done

# tools + their libs, resolved inside the airootfs (same arch, chroot-ldd)
copy_tool(){
  cp $AR/usr/bin/$1 $W/ir/usr/bin/
  chroot $AR /usr/bin/ldd /usr/bin/$1 | grep -oE '/[^ ]+\.so[^ ]*' | sort -u | while read -r so; do
    [ -f "$AR$so" ] && mkdir -p "$W/ir$(dirname $so)" && cp -n "$AR$so" "$W/ir$so" || true
  done
}
copy_tool sgdisk
copy_tool dd
copy_tool sfdisk
copy_tool btrfs
copy_tool btrfstune
mkdir -p $W/ir/usr/lib64 $W/ir/lib64
cp $AR/usr/lib/ld-linux-x86-64.so.2 $W/ir/usr/lib/ 2>/dev/null || true
ln -sf ../usr/lib/ld-linux-x86-64.so.2 $W/ir/lib64/ld-linux-x86-64.so.2 2>/dev/null || true
ln -sf usr/lib $W/ir/lib 2>/dev/null || true

cat > $W/ir/init <<'INIT'
#!/bin/sh
export PATH=/bin:/usr/bin
/bin/mount -t devtmpfs dev /dev 2>/dev/null
/bin/mount -t proc proc /proc 2>/dev/null
/bin/mount -t sysfs sys /sys 2>/dev/null
up(){ cut -d' ' -f1 /proc/uptime; }
say(){ echo "MINI[$(up)] $1" > /dev/ttyS0; }
say "init alcanzado"
# discos: vda = destino del usuario (30G), vdb = imagen dorada (12G, ro)
n=0; while [ ! -b /dev/vda ] || [ ! -b /dev/vdb ]; do sleep 0.1; n=$((n+1)); [ $n -gt 100 ] && { say "FAIL discos ausentes"; reboot -f; }; done
say "dd start"
SZ=$(blockdev --getsize64 /dev/vdb)
CH=$(( (SZ/4/67108864 + 1) * 67108864 ))
pids=""
for i in 0 1 2 3; do
  /usr/bin/dd if=/dev/vdb of=/dev/vda bs=64M skip=$((i*CH)) seek=$((i*CH)) count=$CH     iflag=direct,skip_bytes,count_bytes oflag=direct,seek_bytes conv=sparse,notrunc 2>/dev/null &
  pids="$pids $!"
done
for x in $pids; do wait $x || { say "FAIL dd-parallel"; reboot -f; }; done
say "dd done"
sgdisk -e /dev/vda >/dev/null 2>&1
echo ", +" | sfdisk --no-reread -f -N 2 /dev/vda >/dev/null 2>&1
blockdev --rereadpt /dev/vda 2>/dev/null
n=0; while [ ! -b /dev/vda2 ] && [ $n -lt 60 ]; do sleep 0.05; n=$((n+1)); done
say "particion crecida"
# E5b: fresh identity per install. Boot survives because the UKI roots by LABEL.
sgdisk -G /dev/vda >/dev/null 2>&1 || { say "FAIL sgdisk-G"; reboot -f; }
btrfstune -m /dev/vda2 >/dev/null 2>&1 || btrfstune -f -u /dev/vda2 >/dev/null 2>&1 || { say "FAIL btrfstune"; reboot -f; }
blockdev --rereadpt /dev/vda 2>/dev/null
n=0; while [ ! -b /dev/vda2 ] && [ $n -lt 60 ]; do sleep 0.05; n=$((n+1)); done
say "identidad regenerada"
mount -t btrfs -o subvol=@ /dev/vda2 /mnt || { say "FAIL mount"; reboot -f; }
btrfs filesystem resize max /mnt >/dev/null 2>&1 || say "WARN resize"
: > /mnt/etc/machine-id
rm -f /mnt/etc/ssh/ssh_host_* 2>/dev/null
umount /mnt
say "fixups done"
sync
say "MINI_DONE rebooting"
reboot -f
INIT
chmod +x $W/ir/init

log "empaquetando initramfs"
(cd $W/ir && find . | busybox cpio -o -H newc 2>/dev/null | gzip -1) > $OUT/initramfs.img
ls -la $OUT/initramfs.img

log "construyendo UKI (objcopy + linuxx64.efi.stub)"
printf 'NAME="omarchy-mini"\nID=omarchy-mini\n' > $W/osrel
printf 'console=ttyS0 rdinit=/init' > $W/cmdline
# VMAs must sit ABOVE the stub's ImageBase (0x14df90000) + its sections,
# else the PE is invalid and OVMF falls through to the EFI shell (measured).
objcopy \
  --add-section .osrel=$W/osrel       --change-section-vma .osrel=0x14dfc0000 \
  --add-section .cmdline=$W/cmdline   --change-section-vma .cmdline=0x14dfc1000 \
  --add-section .initrd=$OUT/initramfs.img --change-section-vma .initrd=0x14e000000 \
  --add-section .linux=$AR/usr/lib/modules/$KVER/vmlinuz --change-section-vma .linux=0x14f000000 \
  $AR/usr/lib/systemd/boot/efi/linuxx64.efi.stub $OUT/mini.efi
ls -la $OUT/mini.efi

log "creando disco ESP arrancable"
rm -f $OUT/bootdisk.raw
truncate -s 256M $OUT/bootdisk.raw
sgdisk -n 1:2048:0 -t 1:EF00 $OUT/bootdisk.raw >/dev/null
losetup -fP $OUT/bootdisk.raw; LO=$(losetup -j $OUT/bootdisk.raw|cut -d: -f1)
mkfs.fat -F32 ${LO}p1 >/dev/null 2>&1
mkdir -p $W/esp; mount ${LO}p1 $W/esp
mkdir -p $W/esp/EFI/BOOT; cp $OUT/mini.efi $W/esp/EFI/BOOT/BOOTX64.EFI
umount $W/esp; losetup -d $LO
log "BUILD_MINI_DONE: $OUT/{initramfs.img,mini.efi,bootdisk.raw}"
