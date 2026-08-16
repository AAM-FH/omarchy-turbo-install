#!/bin/bash
# E8: full mini-installer run. Wall clock = qemu foreground lifetime:
# OVMF power-on -> UKI -> /init -> dd golden -> fixups -> guest reboot -> qemu exits.
set -euo pipefail
TURBO="${TURBO:-$(pwd)/work}"
M=${TURBO}/mini
W=/dev/shm/e8
log(){ printf '==> [%s] %s\n' "$(date +%H:%M:%S)" "$1"; }
rm -rf $W; mkdir -p $W
cp "${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}" $W/VARS.fd
truncate -s 30G $W/target.raw
T0=$(date +%s.%N)
timeout 180 qemu-system-x86_64 -cpu host -enable-kvm -machine q35,accel=kvm -smp 8 -m 8192 \
  -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}" \
  -drive if=pflash,format=raw,file=$W/VARS.fd \
  -drive file=$W/target.raw,format=raw,if=none,id=t -device virtio-blk-pci,drive=t \
  -drive file=${TURBO}/golden12disk.raw,format=raw,if=none,id=g,readonly=on -device virtio-blk-pci,drive=g \
  -drive file=$M/bootdisk.raw,format=raw,if=none,id=b -device virtio-blk-pci,drive=b,bootindex=1 \
  -serial file:$W/serial.log -display none -no-reboot
T1=$(date +%s.%N)
TOTAL=$(awk -v a=$T0 -v b=$T1 'BEGIN{printf "%.2f", b-a}')
log "qemu vivio ${TOTAL}s. serial:"
grep -a "MINI\[" $W/serial.log || { log "E8_FAIL sin markers"; tail -5 $W/serial.log; exit 1; }
grep -aq "MINI_DONE" $W/serial.log || { log "E8_FAIL init no completo"; exit 1; }
log "E8_DONE total-power-on-a-reboot=${TOTAL}s (objetivo <15)"
