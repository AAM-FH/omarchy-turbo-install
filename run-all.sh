#!/bin/bash
# One command, one number. Builds everything from the OFFICIAL Omarchy ISO on
# your machine and prints the wall-clock install time.
#
#   sudo ./run-all.sh                       # downloads the official ISO itself
#   sudo ./run-all.sh /path/to/omarchy.iso  # or use one you already have
#
# First run ~20 min (one normal install derives the golden image), ~15s after.
# Dependencies are installed automatically (apt or pacman). Everything runs in
# VMs and under $TURBO: your system is never touched.
set -euo pipefail
trap 'echo "run-all ABORTADO: fallo en linea $LINENO (revisa la salida de arriba)" >&2' ERR
export TURBO="${TURBO:-$(pwd)/work}"
S=$(cd "$(dirname "$0")/scripts" && pwd)
mkdir -p "$TURBO"

# ---------- preflight: root, kvm, deps, ovmf, shm ----------
[ "$(id -u)" = 0 ] || { echo "Ejecutame con sudo: los installs corren en QEMU y el golden se monta con loop/guestfs." >&2; exit 1; }
[ -e /dev/kvm ] || { echo "FALTA /dev/kvm: necesitas una maquina con KVM (o VM con virtualizacion anidada)." >&2; exit 1; }

need() { command -v "$1" >/dev/null; }
MISSING_BIN=""
for b in qemu-system-x86_64 unsquashfs guestfish sgdisk mkfs.fat mkfs.btrfs growpart busybox jq objcopy curl; do
  need "$b" || MISSING_BIN="$MISSING_BIN $b"
done
if [ -n "$MISSING_BIN" ]; then
  echo "== instalando dependencias que faltan:$MISSING_BIN"
  if need apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q qemu-system-x86 ovmf \
      squashfs-tools libguestfs-tools gdisk dosfstools btrfs-progs \
      cloud-guest-utils busybox-static jq binutils curl
  elif need pacman; then
    pacman -S --noconfirm --needed qemu-base edk2-ovmf squashfs-tools \
      libguestfs gptfdisk dosfstools btrfs-progs cloud-guest-utils busybox \
      jq binutils curl
  else
    echo "No reconozco tu gestor de paquetes. Instala a mano:$MISSING_BIN" >&2; exit 1
  fi
fi

# OVMF lives in different paths per distro; find it once, export for scripts
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
         /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd \
         /usr/share/edk2-ovmf/x64/OVMF_CODE.fd; do
  [ -f "$c" ] && export OVMF_CODE="$c" && break
done
export OVMF_VARS="${OVMF_CODE%CODE*}VARS${OVMF_CODE##*CODE}"
[ -f "${OVMF_CODE:-}" ] && [ -f "$OVMF_VARS" ] || { echo "OVMF no encontrado (busque en /usr/share/OVMF y /usr/share/edk2*). Exporta OVMF_CODE y OVMF_VARS a mano." >&2; exit 1; }

SHM_FREE_G=$(df -BG --output=avail /dev/shm | tail -1 | tr -dc 0-9)
[ "$SHM_FREE_G" -ge 24 ] || { echo "FALTA RAM: /dev/shm tiene ${SHM_FREE_G}G libres y el bench necesita ~24G (los discos de las VMs viven en RAM para medir limpio)." >&2; exit 1; }

# ---------- ISO: use the given one or fetch the official ----------
ISO="${1:-}"
if [ -z "$ISO" ]; then
  ISO="$TURBO/omarchy-4.0.0.iso"
  if [ ! -s "$ISO" ]; then
    echo "== descargando el ISO oficial (~6GB, se reanuda si se corta)"
    curl -L -C - -o "$ISO.part" https://iso.omarchy.org/omarchy-4.0.0.iso
    mv "$ISO.part" "$ISO"
  fi
fi
[ -s "$ISO" ] || { echo "ISO no encontrado: $ISO" >&2; exit 1; }

# ---------- the chain ----------
echo "== [1/6] extrayendo airootfs del ISO oficial"
$S/00-extract-airootfs.sh "$ISO"
echo "== [2/6] instalacion fuente con el instalador OFICIAL (esto es lo lento: es el baseline)"
BENCH_ISO="$ISO" BENCH_KEEP_DISK=1 $S/01-source-install.sh
RUN_ID=$(tail -1 "$TURBO/runs.jsonl" | jq -r .run_id)
SRC="/dev/shm/omarchy-bench/$RUN_ID/disk.qcow2"
[ -s "$SRC" ] || { echo "FALLO: disco fuente no encontrado en $SRC" >&2; exit 1; }
echo "== [3/6] imagen dorada desde esa instalacion: $SRC"
$S/02-build-golden.sh "$SRC" "$TURBO/golden12disk.raw"
echo "== [4/6] mini-instalador (UKI + initramfs desde el airootfs)"
$S/03-build-mini-installer.sh
echo "== [5/6] BENCHMARK: power-on -> sistema instalado -> reboot"
$S/04-benchmark.sh
echo "== [6/6] verificacion: el sistema instalado arranca hasta login"
$S/05-boot-verify.sh
echo "Hecho. Compara el numero del paso 5 con lo que tardo el paso 2."
