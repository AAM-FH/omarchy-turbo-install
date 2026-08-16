#!/bin/bash
#
# bench-install.sh — omarchy-install-floor W1: one unattended Omarchy install
# in QEMU/KVM with the disk in /dev/shm, wall-clock timed from power-on to the
# guest's own post-install reboot, per-phase timing extracted from the
# installed disk. Adapted from omarchy-iso test/integration.d/base-test.sh.
#
# Detection contract (measured against omarchy-iso@main, ISO 4.0.0):
#   - cidata autoinstall exports OMARCHY_UI_INTERACTIVE=no; the dashboard's
#     reboot_prompt short-circuits and the guest reboots on its own.
#   - We run QEMU with -no-reboot: the guest's reboot exits QEMU, and the QMP
#     RESET event carries the host-clock timestamp of that instant.
#   - The live kernel boots with `quiet splash` and no console=ttyS0, so the
#     serial log only sees GRUB. H8 (live boot -> orchestrator) comes from
#     timing.json started_at (guest epoch == host epoch under KVM) minus T0.
#
# Output: one JSON line appended to ${TURBO}/runs.jsonl
# Artifacts per run: ${TURBO}/runs/<run_id>/
# Usage: ./bench-install.sh   (env overrides: BENCH_ISO, BENCH_MEMORY,
#        BENCH_SMP, BENCH_INSTALL_TIMEOUT)

set -euo pipefail
TURBO="${TURBO:-$(pwd)/work}"

BENCH="$TURBO"
ISO="${BENCH_ISO:-$BENCH/omarchy-4.0.0.iso}"
MEMORY="${BENCH_MEMORY:-16384}"
SMP="${BENCH_SMP:-$(nproc)}"
INSTALL_TIMEOUT="${BENCH_INSTALL_TIMEOUT:-2400}"

OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS_TEMPLATE=/usr/share/OVMF/OVMF_VARS_4M.fd

GUEST_USER=omarchy
GUEST_PASSWORD=omarchy
GUEST_HOSTNAME=omarchy-bench

RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR=$BENCH/runs/$RUN_ID
SHM_DIR=/dev/shm/omarchy-bench/$RUN_ID
DISK=$SHM_DIR/disk.qcow2
QMP_SOCK=$SHM_DIR/qmp.sock
PIDFILE=$SHM_DIR/qemu.pid
EVENTS=$RUN_DIR/qmp-events.ndjson
SERIAL=$RUN_DIR/serial.log
SSH_KEY=$BENCH/id_ed25519
CIDATA_IMG=$SHM_DIR/cidata.img
EVENT_PID=""

mkdir -p "$RUN_DIR" "$SHM_DIR"

log() { printf '==> [%s] %s\n' "$(date +%H:%M:%S)" "$1"; }

vm_running() { [[ -f $PIDFILE ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

qmp() {
  printf '{"execute":"qmp_capabilities"}\n{"execute":%s}\n' "$1" |
    timeout 5 socat -t 2 - "UNIX-CONNECT:$QMP_SOCK" 2>/dev/null || true
}

record_failure() {
  jq -cn --arg run_id "$RUN_ID" --arg status "$1" --arg detail "${2:-}" \
    '{run_id: $run_id, ts: (now|todate), status: $status, detail: $detail}' \
    >>"$BENCH/runs.jsonl"
}

cleanup() {
  local status=$?
  if vm_running; then
    qmp '"quit"' >/dev/null
    local w=0
    while vm_running && ((w < 10)); do sleep 1; ((w += 1)); done
    vm_running && kill -9 "$(cat "$PIDFILE")" 2>/dev/null
  fi
  [[ -n $EVENT_PID ]] && kill "$EVENT_PID" 2>/dev/null
  rm -rf "$SHM_DIR"
  return $status
}
trap cleanup EXIT

# ------------------------------------------------------------------- cidata
# Same content contract as upstream build_cidata(), stable packages, sized
# for the 40G virtio disk: 1MiB gap, 2GiB ESP, rest btrfs minus GPT reserve.
build_cidata() {
  local dir=$SHM_DIR/cidata hash
  local disk_bytes=$((40 * 1024 * 1024 * 1024))
  local mib=$((1024 * 1024)) gib=$((1024 * 1024 * 1024))
  local boot_start=$mib boot_size=$((2 * gib))
  local main_start=$((boot_size + boot_start))
  local main_size=$((disk_bytes - main_start - mib))

  rm -rf "$dir"
  mkdir -p "$dir"

  hash=$(openssl passwd -6 "$GUEST_PASSWORD")

  cat >"$dir/user_credentials.json" <<EOF
{
    "root_enc_password": $(jq -Rn --arg v "$hash" '$v'),
    "users": [
        {
            "enc_password": $(jq -Rn --arg v "$hash" '$v'),
            "groups": [],
            "sudo": true,
            "username": "$GUEST_USER"
        }
    ]
}
EOF

  cat >"$dir/user_configuration.json" <<EOF
{
    "app_config": null,
    "archinstall-language": "English",
    "auth_config": {},
    "audio_config": { "audio": "pipewire" },
    "bootloader_config": { "bootloader": "Limine", "uki": false, "removable": false },
    "custom_commands": [],
    "omarchy_install": {
        "mode": "full_disk",
        "defer_provisioning": false,
        "target_mount": "/mnt",
        "boot": {
            "esp_mount": "/boot",
            "esp_path": "/EFI/limine",
            "efi_binary": "limine_x64.efi",
            "enable_fallback": true
        },
        "storage": { "kernel": "linux" }
    },
    "disk_config": {
        "config_type": "default_layout",
        "device_modifications": [
            {
                "device": "/dev/vda",
                "partitions": [
                    {
                        "btrfs": [],
                        "dev_path": null,
                        "flags": [ "boot", "esp" ],
                        "fs_type": "fat32",
                        "mount_options": [],
                        "mountpoint": "/boot",
                        "obj_id": "ea21d3f2-82bb-49cc-ab5d-6f81ae94e18d",
                        "size": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $boot_size },
                        "start": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $boot_start },
                        "status": "create",
                        "type": "primary"
                    },
                    {
                        "btrfs": [
                            { "mountpoint": "/", "name": "@" },
                            { "mountpoint": "/home", "name": "@home" },
                            { "mountpoint": "/var/log", "name": "@log" },
                            { "mountpoint": "/var/cache/pacman/pkg", "name": "@pkg" }
                        ],
                        "dev_path": null,
                        "flags": [],
                        "fs_type": "btrfs",
                        "mount_options": [ "compress=zstd" ],
                        "mountpoint": null,
                        "obj_id": "8c2c2b92-1070-455d-b76a-56263bab24aa",
                        "size": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $main_size },
                        "start": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $main_start },
                        "status": "create",
                        "type": "primary"
                    }
                ],
                "wipe": true
            }
        ]
    },
    "hostname": "$GUEST_HOSTNAME",
    "kernels": [ "linux" ],
    "network_config": { "type": "iso" },
    "ntp": true,
    "parallel_downloads": 8,
    "script": null,
    "services": [],
    "swap": true,
    "timezone": "UTC",
    "locale_config": { "kb_layout": "us", "sys_enc": "UTF-8", "sys_lang": "en_US.UTF-8" },
    "mirror_config": {
        "custom_repositories": [],
        "custom_servers": [
            {"url": "https://mirror.omarchy.org/\$repo/os/\$arch"},
            {"url": "https://mirror.rackspace.com/archlinux/\$repo/os/\$arch"},
            {"url": "https://geo.mirror.pkgbuild.com/\$repo/os/\$arch"}
        ],
        "mirror_regions": {},
        "optional_repositories": []
    },
    "packages": [
        "base-devel",
        "git",
        "omarchy-keyring",
        "omarchy-settings",
        "omarchy"
    ],
    "profile_config": { "gfx_driver": null, "greeter": null, "profile": {} },
    "version": "3.0.9"
}
EOF

  echo "Omarchy Bench" >"$dir/user_full_name.txt"
  echo "bench@omarchy.org" >"$dir/user_email_address.txt"
  echo "false" >"$dir/user_encrypt_installation.txt"
  cp "$SSH_KEY.pub" "$dir/authorized_keys"

  rm -f "$CIDATA_IMG"
  truncate -s 4M "$CIDATA_IMG"
  mkfs.vfat -n CIDATA "$CIDATA_IMG" >/dev/null
  mcopy -i "$CIDATA_IMG" "$dir"/* ::/
}

# ---------------------------------------------------------------------- run

[[ -f $ISO ]] || { echo "ISO not found: $ISO" >&2; exit 2; }
[[ -f $SSH_KEY ]] || ssh-keygen -t ed25519 -N "" -q -C "omarchy-bench" -f "$SSH_KEY"

build_cidata
qemu-img create -f qcow2 "$DISK" 40G >/dev/null
cp "$OVMF_VARS_TEMPLATE" "$SHM_DIR/OVMF_VARS.fd"

log "Power-on (run $RUN_ID, smp=$SMP mem=${MEMORY}M, disk in /dev/shm)"
T0=$(date +%s.%N)

qemu-system-x86_64 \
  -cpu host -enable-kvm -machine q35,accel=kvm \
  -smp "$SMP" \
  -m "$MEMORY" \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$SHM_DIR/OVMF_VARS.fd" \
  -drive file="$DISK",format=qcow2,if=none,id=drive0 \
  -device virtio-blk-pci,drive=drive0,bootindex=1 \
  -device virtio-vga \
  -display none \
  -usb -device usb-tablet \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0 \
  -qmp "unix:$QMP_SOCK,server,nowait" \
  -serial "file:$SERIAL" \
  -pidfile "$PIDFILE" \
  -no-reboot \
  -daemonize \
  -drive "file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0" \
  -device ide-cd,drive=cdrom0,bootindex=2 \
  -drive "file=$CIDATA_IMG,format=raw,if=none,id=cidata" \
  -device usb-storage,drive=cidata

# Persistent QMP reader: the RESET event's host timestamp is our end-of-install
# instant. The sleep keeps stdin (and so the connection) open.
{ printf '{"execute":"qmp_capabilities"}\n'; sleep $((INSTALL_TIMEOUT + 120)); } |
  socat -t 5 - "UNIX-CONNECT:$QMP_SOCK" >"$EVENTS" 2>/dev/null &
EVENT_PID=$!

log "Waiting for the unattended install (timeout ${INSTALL_TIMEOUT}s)"
waited=0
while vm_running; do
  if ((waited >= INSTALL_TIMEOUT)); then
    qmp "\"screendump\", \"arguments\": {\"filename\": \"$RUN_DIR/timeout.ppm\"}" >/dev/null
    record_failure timeout "no reboot after ${INSTALL_TIMEOUT}s"
    echo "TIMEOUT after ${INSTALL_TIMEOUT}s; screendump in $RUN_DIR" >&2
    exit 1
  fi
  if ((waited % 120 == 0 && waited > 0)); then log "  ... ${waited}s"; fi
  sleep 5
  ((waited += 5))
done

# With -no-reboot the guest's reboot arrives as SHUTDOWN/guest-reset (QEMU
# converts the reset into an exit); accept a plain RESET too for safety.
T_REBOOT=$(jq -rs '[.[] | select((.event? == "RESET") or
    ((.event? == "SHUTDOWN") and (.data.reason? == "guest-reset")))][0] |
  if . == null then empty else (.timestamp.seconds + .timestamp.microseconds/1e6) end' "$EVENTS")
if [[ -z $T_REBOOT ]]; then
  record_failure no-reset "QEMU exited without a guest-initiated RESET"
  echo "VM exited without RESET event; see $EVENTS and $SERIAL" >&2
  exit 1
fi

log "Guest rebooted; extracting timing from the installed disk"
TIMING=$RUN_DIR/omarchy-install-timing.json
if ! virt-copy-out -a "$DISK" /var/log/omarchy-install-timing.json "$RUN_DIR/" 2>"$RUN_DIR/virt-copy-out.err"; then
  # Fallback: mount the @log subvolume directly.
  MNT=$SHM_DIR/mnt
  mkdir -p "$MNT"
  if guestmount -a "$DISK" -m /dev/sda2:/:subvol=@log --ro "$MNT" 2>>"$RUN_DIR/virt-copy-out.err"; then
    cp "$MNT/omarchy-install-timing.json" "$TIMING" || true
    guestunmount "$MNT"
  fi
fi
if [[ ! -s $TIMING ]]; then
  record_failure no-timing "rebooted but timing json not extractable"
  echo "Could not extract $TIMING" >&2
  exit 1
fi

jq -cn --arg run_id "$RUN_ID" \
  --argjson t0 "$T0" --argjson t_reboot "$T_REBOOT" \
  --argjson smp "$SMP" --argjson mem "$MEMORY" \
  --slurpfile t "$TIMING" '
  ($t[0]) as $T |
  {run_id: $run_id,
   ts: (now|todate),
   status: "ok",
   smp: $smp, mem_mb: $mem,
   total_s: (($t_reboot - $t0) * 100 | round / 100),
   boot_to_orch_s: (($T.started_at - $t0) * 100 | round / 100),
   install_s: (($T.finished_at - $T.started_at) * 100 | round / 100),
   finish_to_reboot_s: (($t_reboot - $T.finished_at) * 100 | round / 100),
   installed_packages: $T.installed_packages,
   phases: ($T.phases | map({key: .name, value: (.elapsed * 100 | round / 100)}) | from_entries)}
' >>"$BENCH/runs.jsonl"

log "OK: $(tail -1 "$BENCH/runs.jsonl" | jq -r '"total=\(.total_s)s boot_to_orch=\(.boot_to_orch_s)s install=\(.install_s)s"')"
