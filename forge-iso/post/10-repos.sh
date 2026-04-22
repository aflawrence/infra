#!/bin/bash
# Enable the two third-party repos forge depends on: OpenZFS and 45Drives.
# Running inside the %post chroot, so no sudo needed.
set -euo pipefail

FEDORA_REL="$(rpm --eval %fedora)"
ZFS_RELEASE_VER="2-7"

# OpenZFS — ships zfs-kmod / zfs-dkms / zfs-dracut from zfsonlinux.org.
rpm --import https://zfsonlinux.org/fedora/RPM-GPG-KEY-openzfs 2>/dev/null || true
dnf -y install "https://zfsonlinux.org/fedora/zfs-release-${ZFS_RELEASE_VER}.fc${FEDORA_REL}.noarch.rpm" \
    || echo "forge: WARN — OpenZFS release RPM install failed; zfs will be installed on first boot"

# 45Drives Houston modules.
rpm --import https://repo.45drives.com/key/gpg.asc
curl -fsSL https://repo.45drives.com/lists/45drives.repo -o /etc/yum.repos.d/45drives.repo

# Refresh metadata so subsequent %post scripts can install from these repos.
dnf -q makecache || true
