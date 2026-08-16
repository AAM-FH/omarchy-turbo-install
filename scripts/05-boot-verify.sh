#!/bin/bash
# E8 boot-verify: boot the E8-installed target, wait for userspace signals.
set -euo pipefail
TURBO="${TURBO:-$(pwd)/work}"
TARGET=${1:-/dev/shm/e8/target.raw}
W=/dev/shm/e8boot; rm -rf $W; mkdir -p $W
log(){ printf '==> [%s] %s\n' "$(date +%H:%M:%S)" "$1"; }
cp "${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}" $W/VARS.fd
# bench-only: serial getty so success is observable as a real login prompt
L=$(losetup -fP --show $TARGET); mkdir -p $W/m
mount -o subvol=@ ${L}p2 $W/m
mkdir -p $W/m/etc/systemd/system/getty.target.wants
ln -sf /usr/lib/systemd/system/serial-getty@.service $W/m/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service
umount $W/m; losetup -d $L
: > $W/serial.log
qemu-system-x86_64 -cpu host -enable-kvm -machine q35,accel=kvm -smp 4 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}" \
  -drive if=pflash,format=raw,file=$W/VARS.fd \
  -drive file=$TARGET,format=raw,if=none,id=d0 -device virtio-blk-pci,drive=d0 \
  -serial file:$W/serial.log -display none -pidfile $W/pid -daemonize -no-reboot
PID=$(cat $W/pid)
for i in $(seq 1 150); do
  if grep -aqiE "login:|Reached target Multi|Reached target Graphical" $W/serial.log; then
    log "BOOT_OK a los ${i}s"
    grep -aoiE "machineid=[0-9a-f]+|Reached target [A-Za-z]+|login:" $W/serial.log | sort -u | head -8
    kill $PID 2>/dev/null || true; exit 0
  fi
  kill -0 $PID 2>/dev/null || { log "BOOT_ENDED: qemu salio a los ${i}s (reset o apagado del guest)"; break; }
  sleep 1
done
log "diagnostico serial (sin ANSI):"
grep -aoiE "Timed out|time ?out|emergency|Failed|error|Reached target [A-Za-z ]+|machineid=[0-9a-f]+" $W/serial.log | sort | uniq -c | sort -rn | head -12
tail -c 400 $W/serial.log | strings | tail -6
kill $PID 2>/dev/null || true
exit 1
