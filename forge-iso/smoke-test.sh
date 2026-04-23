#!/bin/bash
# smoke-test.sh — boot the built forge ISO in QEMU to exercise the install
# end-to-end before burning a USB stick and touching real hardware.
#
# Mental model:
#   • target.qcow2   40G — the "system disk" anaconda installs onto
#   • zfs{1,2,3}.qcow2  4G each — bonus disks so the firstboot wizard
#     has something to build a ZFS pool from
#   • UEFI (OVMF) firmware — matches modern hardware; you want to catch
#     grub2-efi-x64 / shim issues in the VM, not on the target
#   • user-mode networking with port 9090 forwarded — open Cockpit from
#     the host browser at https://localhost:9090
#
# Usage:
#   ./smoke-test.sh install                 # fresh install cycle
#   ./smoke-test.sh run                     # boot the installed VM (skip ISO)
#   ./smoke-test.sh clean                   # wipe the test disks
#
# Env overrides:
#   FORGE_ISO=/path/to/forge-0.1.0-x86_64.iso     (default: ../out/forge-*.iso)
#   SMOKE_DIR=/tmp/forge-smoke                    (state dir)
#   RAM_MB=4096  VCPUS=4  GRAPHICS=spice|vnc|sdl|gtk|none
#   NESTED_KVM=1 — pass through /dev/kvm so the installed hypervisor can
#                  itself run VMs during the test (requires KVM on the host)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
: "${SMOKE_DIR:=/tmp/forge-smoke}"
: "${RAM_MB:=4096}"
: "${VCPUS:=4}"
: "${GRAPHICS:=spice}"
: "${NESTED_KVM:=1}"

MODE="${1:-install}"

# -----------------------------------------------------------------------------
# dependency check — fail fast with actionable messages
# -----------------------------------------------------------------------------
for cmd in qemu-system-x86_64 qemu-img; do
    command -v "$cmd" >/dev/null || {
        echo "missing $cmd — install 'qemu' / 'qemu-kvm' on your host" >&2
        exit 2
    }
done

# Locate OVMF. Fedora / RHEL / Ubuntu / Arch all disagree on the path.
OVMF_CODE=""
for p in \
    /usr/share/edk2/ovmf/OVMF_CODE.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/ovmf/OVMF.fd
do
    [ -f "$p" ] && { OVMF_CODE="$p"; break; }
done
[ -n "$OVMF_CODE" ] || {
    echo "no OVMF firmware found — install edk2-ovmf / ovmf" >&2
    exit 2
}
OVMF_VARS_SRC="${OVMF_CODE%_CODE*}_VARS.fd"
[ -f "$OVMF_VARS_SRC" ] || OVMF_VARS_SRC="$(dirname "$OVMF_CODE")/OVMF_VARS.fd"

# -----------------------------------------------------------------------------
# locate the ISO
# -----------------------------------------------------------------------------
if [ -z "${FORGE_ISO:-}" ]; then
    FORGE_ISO="$(ls -1t "${SCRIPT_DIR}"/../out/forge-*.iso 2>/dev/null | head -n 1 || true)"
fi
if [ "$MODE" = "install" ] && [ ! -f "${FORGE_ISO:-}" ]; then
    echo "no forge ISO found — build one first with forge-iso/build.sh" >&2
    echo "or set FORGE_ISO=/path/to/forge.iso" >&2
    exit 3
fi

# -----------------------------------------------------------------------------
# ensure workdir + disks
# -----------------------------------------------------------------------------
mkdir -p "$SMOKE_DIR"
TARGET="$SMOKE_DIR/target.qcow2"
OVMF_VARS="$SMOKE_DIR/OVMF_VARS.fd"

if [ "$MODE" = "clean" ]; then
    rm -rf "$SMOKE_DIR"
    echo "wiped $SMOKE_DIR"
    exit 0
fi

if [ ! -f "$TARGET" ]; then
    echo "==> creating 40G target disk"
    qemu-img create -f qcow2 "$TARGET" 40G >/dev/null
fi
for i in 1 2 3; do
    d="$SMOKE_DIR/zfs${i}.qcow2"
    [ -f "$d" ] || qemu-img create -f qcow2 "$d" 4G >/dev/null
done
[ -f "$OVMF_VARS" ] || cp "$OVMF_VARS_SRC" "$OVMF_VARS"

# -----------------------------------------------------------------------------
# KVM acceleration — use it if the kernel exposes /dev/kvm and we have perms
# -----------------------------------------------------------------------------
ACCEL="tcg"
CPU="qemu64"
if [ "$NESTED_KVM" = "1" ] && [ -w /dev/kvm ]; then
    ACCEL="kvm"
    # host-passthrough gives the guest the host's real CPU flags, which is
    # needed for the guest's own KVM to work (nested virt). If the host is
    # AMD, vmx won't appear in the guest; that's fine — the point of the
    # smoke test is the installer + firstboot, not running nested VMs.
    CPU="host"
fi

# -----------------------------------------------------------------------------
# graphics backend selection — default spice, fall back gracefully
# -----------------------------------------------------------------------------
GRAPHICS_ARGS=()
case "$GRAPHICS" in
    spice)
        GRAPHICS_ARGS=(-device virtio-vga -spice port=5930,disable-ticketing=on
                       -device virtio-serial-pci
                       -chardev spicevmc,id=spicechannel0,name=vdagent
                       -device virtserialport,chardev=spicechannel0,name=com.redhat.spice.0)
        echo "==> Spice on port 5930 — connect with: remote-viewer spice://localhost:5930"
        ;;
    vnc)
        GRAPHICS_ARGS=(-vnc :2 -vga std)
        echo "==> VNC on :5902 — connect with: vncviewer localhost:5902"
        ;;
    sdl|gtk)
        GRAPHICS_ARGS=(-display "$GRAPHICS" -vga std)
        ;;
    none)
        GRAPHICS_ARGS=(-display none -serial mon:stdio -nographic)
        echo "==> Headless; anaconda text mode — Ctrl-A X to kill"
        ;;
    *)
        echo "unknown GRAPHICS=$GRAPHICS" >&2; exit 4
        ;;
esac

# -----------------------------------------------------------------------------
# assemble QEMU invocation
# -----------------------------------------------------------------------------
ARGS=(
    -name forge-smoke
    -machine q35,accel="$ACCEL"
    -cpu "$CPU"
    -smp "$VCPUS"
    -m "$RAM_MB"
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
    -drive if=pflash,format=raw,file="$OVMF_VARS"
    # target disk — becomes /dev/vda, which `%pre` in forge.ks picks up
    -drive file="$TARGET",if=virtio,format=qcow2,cache=none,aio=native
    # bonus ZFS disks — will show up as /dev/vdb /vdc /vdd in firstboot
    -drive file="$SMOKE_DIR/zfs1.qcow2",if=virtio,format=qcow2
    -drive file="$SMOKE_DIR/zfs2.qcow2",if=virtio,format=qcow2
    -drive file="$SMOKE_DIR/zfs3.qcow2",if=virtio,format=qcow2
    # user-mode networking — port-forward 9090→host:9090 (Cockpit) and 22→2222
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:9090-:9090,hostfwd=tcp:127.0.0.1:2222-:22
    -device virtio-net-pci,netdev=n0
    -rtc base=utc
)

if [ "$MODE" = "install" ]; then
    # Boot from the ISO. q35 + OVMF will automatically find the ISO's
    # EFI loader. inst.ks is already baked into the ISO's cmdline by
    # mkksiso — no extra kernel args needed here.
    ARGS+=(-cdrom "$FORGE_ISO" -boot order=d,menu=on)
    echo "==> installing from ${FORGE_ISO}"
    echo "    (watch the console — anaconda runs forge.ks unattended)"
    echo "    after reboot, the ISO is ejected automatically by kickstart;"
    echo "    if QEMU keeps booting from CD, kill it and run: ./smoke-test.sh run"
elif [ "$MODE" = "run" ]; then
    ARGS+=(-boot order=c)
    echo "==> booting installed VM from ${TARGET}"
    echo "    firstboot runs on tty1; Cockpit comes up at https://localhost:9090"
else
    echo "usage: $0 {install|run|clean}" >&2
    exit 1
fi

"${GRAPHICS_ARGS[@]:+${GRAPHICS_ARGS[@]}}" >/dev/null 2>&1 || true  # satisfy set -u if empty
exec qemu-system-x86_64 "${ARGS[@]}" "${GRAPHICS_ARGS[@]}"
