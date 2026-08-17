#!/bin/bash
# Build the ONE-FILE product: omarchy-turbo-usb.img. Flash it to a USB stick,
# boot any UEFI PC from it, and it installs the golden image to the internal
# disk. Layout: GPT [ESP 256M: mini-USB UKI as BOOTX64] [p2: zstd blob of the
# golden disk image]. The blob size is baked into the init at build time.
set -euo pipefail
TURBO="${TURBO:-/tmp/turbo-cold}"
AR=$TURBO/airootfs-root
KVER=7.1.8-arch1-Watanare-T2-2-t2
OUT=${1:-/tmp/omarchy-turbo-usb.img}
W=/dev/shm/turbousb
log(){ printf '==> [%s] %s\n' "$(date +%H:%M:%S)" "$1"; }
cleanup(){ umount $W/esp 2>/dev/null || true
  L=$(losetup -j $OUT 2>/dev/null|cut -d: -f1); [ -n "${L:-}" ] && losetup -d $L || true; }
trap cleanup EXIT
rm -rf $W; mkdir -p $W/ir/{bin,dev,proc,sys,mnt,usr/bin,usr/lib} $W/esp

log "comprimiendo la imagen dorada en 4 frames paralelos (zstd -12)"
RAW=$(stat -c%s $TURBO/golden12disk.raw)
CHRAW=$(( (RAW/4/1048576 + 1) * 1048576 ))
if [ -s /tmp/turbochunks.cache/c0.zst ]; then cp /tmp/turbochunks.cache/c*.zst $W/
else
  mkdir -p /tmp/turbochunks.cache
  for i in 0 1 2 3; do
    dd if=$TURBO/golden12disk.raw bs=16M skip=$((i*CHRAW)) count=$CHRAW iflag=skip_bytes,count_bytes 2>/dev/null | zstd -12 -T8 -q -o $W/c$i.zst - &
  done; wait
  cp $W/c*.zst /tmp/turbochunks.cache/
fi
OFFS=""; SIZES=""; OFF=0; BLOB=0
for i in 0 1 2 3; do S=$(stat -c%s $W/c$i.zst); OFFS="$OFFS $OFF"; SIZES="$SIZES $S"; OFF=$((OFF+S)); BLOB=$((BLOB+S)); done
cat $W/c0.zst $W/c1.zst $W/c2.zst $W/c3.zst > $W/golden.zst
log "blob: $((BLOB/1024/1024))MB en 4 frames (desde $((RAW/1024/1024))MB raw)"

log "initramfs mini-usb"
cp "$(command -v busybox)" $W/ir/bin/busybox
for a in sh dd mount umount sync reboot blockdev mkdir cut cat rm ls sleep head sed grep basename readlink; do ln -s busybox $W/ir/bin/$a; done
copy_tool(){ cp $AR/usr/bin/$1 $W/ir/usr/bin/
  chroot $AR /usr/bin/ldd /usr/bin/$1 | grep -oE '/[^ ]+\.so[^ ]*' | sort -u | while read -r so; do
    [ -f "$AR$so" ] && mkdir -p "$W/ir$(dirname $so)" && cp --update=none "$AR$so" "$W/ir$so" || true
  done; }
copy_tool sgdisk; copy_tool dd; copy_tool btrfs; copy_tool btrfstune; copy_tool zstd; copy_tool blkid
cp $AR/usr/lib/ld-linux-x86-64.so.2 $W/ir/usr/lib/ 2>/dev/null || true
mkdir -p $W/ir/lib64; ln -sf ../usr/lib/ld-linux-x86-64.so.2 $W/ir/lib64/ld-linux-x86-64.so.2
ln -sf usr/lib $W/ir/lib 2>/dev/null || true

cat > $W/ir/init <<'INIT'
#!/bin/sh
export PATH=/bin:/usr/bin
/bin/mount -t devtmpfs dev /dev 2>/dev/null
/bin/mount -t proc proc /proc 2>/dev/null
/bin/mount -t sysfs sys /sys 2>/dev/null
up(){ cut -d' ' -f1 /proc/uptime; }
say(){ echo "TURBO[$(up)] $1" > /dev/ttyS0; echo "TURBO $1" > /dev/console 2>/dev/null; }
say "init"
n=0; SRC=""
while [ -z "$SRC" ] && [ $n -lt 100 ]; do SRC=$(blkid -L TURBOBOOT 2>/dev/null); [ -z "$SRC" ] && sleep 0.1; n=$((n+1)); done
[ -n "$SRC" ] || { say "FAIL: no encuentro el USB TURBOBOOT"; sleep 5; reboot -f; }
USBDISK=$(basename "$(readlink -f /sys/class/block/$(basename $SRC)/..)")
BLOBPART=$(echo "$SRC" | sed 's/1$/2/')
say "usb=$USBDISK blob=$BLOBPART"
# target: el disco mas grande que NO es el USB de arranque
TGT=""; TGTSZ=0
for d in /sys/block/*; do b=$(basename $d)
  case $b in loop*|ram*|sr*|zram*|dm-*) continue;; esac
  [ "$b" = "$USBDISK" ] && continue
  sz=$(cat $d/size 2>/dev/null || echo 0)
  [ "$sz" -gt "$TGTSZ" ] && { TGT=$b; TGTSZ=$sz; }
done
[ -n "$TGT" ] && [ "$TGTSZ" -gt 33554432 ] || { say "FAIL: sin disco destino >=16G"; sleep 5; reboot -f; }
say "destino=/dev/$TGT ($((TGTSZ/2048/1024))G) - SE BORRARA ENTERO"
for b in zstd sgdisk btrfstune blkid; do $b --help >/dev/null 2>&1 || $b --version >/dev/null 2>&1 || say "AVISO: $b no ejecuta"; done
say "install start"
set -- __SIZES__
OFF=0; i=0; pids=""
for SZ in "$@"; do
  ( /usr/bin/dd if="$BLOBPART" bs=16M skip=$OFF count=$SZ iflag=skip_bytes,count_bytes 2>/dev/null \
    | zstd -dc \
    | /usr/bin/dd of=/dev/$TGT bs=64M seek=$((i*__CH_RAW__)) oflag=seek_bytes conv=notrunc,sparse 2>/dev/null ) & pids="$pids $!"
  OFF=$((OFF+SZ)); i=$((i+1))
done
for x in $pids; do wait $x || { say "FAIL copia"; sleep 5; reboot -f; }; done
say "copia done"
sgdisk -e -d 2 -n 2:0:0 -t 2:8304 -G /dev/$TGT >/dev/null 2>&1 || { say "FAIL sgdisk"; reboot -f; }
blockdev --rereadpt /dev/$TGT 2>/dev/null
P2=/dev/${TGT}2; [ -b $P2 ] || P2=/dev/${TGT}p2
n=0; while [ ! -b $P2 ] && [ $n -lt 60 ]; do sleep 0.05; n=$((n+1)); done
btrfstune -m $P2 >/dev/null 2>&1 || btrfstune -f -u $P2 >/dev/null 2>&1 || { say "FAIL btrfstune"; reboot -f; }
mount -t btrfs -o subvol=@ $P2 /mnt || { say "FAIL mount"; reboot -f; }
btrfs filesystem resize max /mnt >/dev/null 2>&1 || say "WARN resize"
: > /mnt/etc/machine-id
rm -f /mnt/etc/ssh/ssh_host_* 2>/dev/null
umount /mnt; sync
say "TURBO_DONE instalado en /dev/$TGT - reboot (saca el USB)"
reboot -f
INIT
sed -i "s/__CH_RAW__/$CHRAW/; s/__SIZES__/$(echo $SIZES)/" $W/ir/init
chmod +x $W/ir/init
(cd $W/ir && find . | busybox cpio -o -H newc 2>/dev/null | gzip -1) > $W/initramfs.img

log "UKI mini-usb"
printf 'NAME="omarchy-turbo"\nID=omarchy-turbo\n' > $W/osrel
printf 'console=ttyS0 rdinit=/init' > $W/cmdline
objcopy \
  --add-section .osrel=$W/osrel       --change-section-vma .osrel=0x14dfc0000 \
  --add-section .cmdline=$W/cmdline   --change-section-vma .cmdline=0x14dfc1000 \
  --add-section .initrd=$W/initramfs.img --change-section-vma .initrd=0x14e000000 \
  --add-section .linux=$AR/usr/lib/modules/$KVER/vmlinuz --change-section-vma .linux=0x14f000000 \
  $AR/usr/lib/systemd/boot/efi/linuxx64.efi.stub $W/turbo.efi

log "imagen USB unica"
ESP_MB=280
TOTAL=$(( (BLOB/1024/1024) + ESP_MB + 32 ))
rm -f $OUT; truncate -s ${TOTAL}M $OUT
sgdisk -n 1:2048:+${ESP_MB}M -t 1:EF00 -n 2:0:0 -t 2:8300 $OUT >/dev/null
losetup -fP $OUT; LO=$(losetup -j $OUT|cut -d: -f1)
mkfs.fat -F32 -n TURBOBOOT ${LO}p1 >/dev/null 2>&1
mount ${LO}p1 $W/esp; mkdir -p $W/esp/EFI/BOOT
cp $W/turbo.efi $W/esp/EFI/BOOT/BOOTX64.EFI
umount $W/esp
dd if=$W/golden.zst of=${LO}p2 bs=64M conv=notrunc 2>/dev/null
sync; losetup -d $LO
log "TURBOUSB_DONE $OUT ($(du -h $OUT | cut -f1), blob $((BLOB/1024/1024))MB)"
