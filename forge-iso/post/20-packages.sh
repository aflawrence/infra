#!/bin/bash
# Install packages that can't (or shouldn't) go in the kickstart %packages
# block — anything from the third-party repos added in 10-repos.sh.
set -euo pipefail

# OpenZFS kmod. kmod (prebuilt for the running kernel) is preferred over dkms
# — no compile step on every kernel update. If the matching kmod isn't in the
# repo yet for this kernel we fall back to dkms.
if dnf -y install zfs zfs-dracut; then
    echo "forge: installed OpenZFS (kmod variant)"
else
    echo "forge: kmod install failed, falling back to dkms"
    dnf -y install zfs-dkms zfs zfs-dracut
fi

# 45Drives Houston modules.
dnf -y install --enablerepo=45drives \
    cockpit-zfs-manager \
    cockpit-file-sharing \
    cockpit-identities \
    cockpit-navigator \
    cockpit-benchmark \
    cockpit-scheduler \
    || echo "forge: WARN — one or more Houston modules failed to install"
