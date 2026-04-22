#!/bin/bash
# OpenZFS module + service wiring. Matches roles/forge_zfs/ for parity.
set -euo pipefail

# Load on boot.
echo "zfs" > /etc/modules-load.d/zfs.conf

# Default ARC cap: 25% of RAM. Hypervisor guests need memory more than ARC
# does, and OpenZFS's default "half of RAM" is aggressive for a VM host.
TOTAL_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
ARC_MAX=$(( TOTAL_KB * 1024 / 4 ))
cat > /etc/modprobe.d/zfs.conf <<EOF
# Managed by forge — installer default. Tune via Cockpit or /etc/modprobe.d/.
options zfs zfs_arc_max=${ARC_MAX}
EOF

# Rebuild initramfs so the ARC cap applies on the next boot (before zfs
# initializes with the larger default).
dracut -f || echo "forge: WARN — initramfs rebuild failed; will retry on first boot"

# Enable core ZFS services. They're no-ops until a pool exists.
systemctl enable \
    zfs-import-cache.service \
    zfs-import.target \
    zfs-mount.service \
    zfs-zed.service \
    zfs.target \
    || true
