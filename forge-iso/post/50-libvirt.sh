#!/bin/bash
# libvirt + bridge defaults. We don't create the bridge here (we don't know
# the primary NIC name at install time); forge-firstboot prompts for it.
set -euo pipefail

systemctl enable libvirtd.service virtlogd.socket virtlockd.socket

# Pre-create the libvirt dirs that the default libvirt pools expect, so
# cockpit-machines doesn't error out if the operator opens it before any
# ZFS pools exist.
install -d -m 0711 /var/lib/libvirt/images
install -d -m 0755 /var/lib/libvirt/iso

# Tuned profile for virt hosts.
systemctl enable tuned.service
mkdir -p /etc/tuned
cat > /etc/tuned/active_profile <<'EOF'
virtual-host
EOF
cat > /etc/tuned/profile_mode <<'EOF'
manual
EOF
