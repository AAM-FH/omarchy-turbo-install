#!/bin/bash
# One command, one number. Builds everything from the OFFICIAL Omarchy ISO on
# your machine and prints the wall-clock install time. ~20 min end to end the
# first run (one normal install to derive the golden image), ~15s after.
#
#   sudo TURBO=$PWD/work ./run-all.sh /path/to/omarchy-4.0.0.iso
#
# Requires: linux + kvm, qemu-system-x86, OVMF, squashfs-tools, guestfish
# (libguestfs-tools), gdisk, dosfstools, btrfs-progs, cloud-guest-utils,
# busybox-static. Everything runs in VMs and files under $TURBO: your system
# is never touched.
set -euo pipefail
export TURBO="${TURBO:-$(pwd)/work}"
ISO=${1:?usage: run-all.sh <omarchy-official.iso>}
S=$(cd "$(dirname "$0")/scripts" && pwd)
echo "== [1/6] extrayendo airootfs del ISO oficial"
$S/00-extract-airootfs.sh "$ISO"
echo "== [2/6] instalacion fuente con el instalador OFICIAL (esto es lo lento: es el baseline)"
BENCH_ISO="$ISO" $S/01-source-install.sh
SRC=$(ls -t /dev/shm/omarchy-bench/*/disk.qcow2 2>/dev/null | head -1)
[ -n "$SRC" ] || SRC=$(ls -t $TURBO/omarchy-bench/*/disk.qcow2 2>/dev/null | head -1)
echo "== [3/6] imagen dorada desde esa instalacion: $SRC"
$S/02-build-golden.sh "$SRC" "$TURBO/golden12disk.raw"
echo "== [4/6] mini-instalador (UKI + initramfs desde el airootfs)"
$S/03-build-mini-installer.sh
echo "== [5/6] BENCHMARK: power-on -> sistema instalado -> reboot"
$S/04-benchmark.sh
echo "== [6/6] verificacion: el sistema instalado arranca hasta login"
$S/05-boot-verify.sh
echo "Hecho. Compara el numero del paso 5 con lo que tardo el paso 2."
