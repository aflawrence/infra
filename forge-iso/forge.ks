# =============================================================================
# forge.ks — kickstart for the forge installer ISO
# =============================================================================
# Ships via `mkksiso` embedded in a Fedora Server netinstall DVD. Anaconda
# runs this unattended on boot; the result is a Fedora Server node with
# Cockpit + Houston + OpenZFS + libvirt + sanoid pre-installed and enabled.
#
# Partitioning strategy (v1):
#   /boot/efi         1 GiB      EFI system partition
#   /boot           1024 MiB     xfs
#   /               100 GiB      xfs (enough for Fedora + guest ISOs)
#   swap               4 GiB
#   (remaining space on the install disk and any additional disks are left
#   untouched, so the operator can build ZFS pools from Cockpit at first boot)
#
# Override at boot time by editing the kernel cmdline: add `inst.ks=<url>`
# to use a different kickstart, or set `forge.disk=/dev/nvme0n1` etc. via
# the %pre hook below.
# =============================================================================

# --- Locale / keyboard / time ------------------------------------------------
lang en_US.UTF-8
keyboard --vckeymap=us --xlayouts='us'
timezone --utc Etc/UTC

# --- Install source ----------------------------------------------------------
# Netinstall — pulls the full package set from the Fedora mirror network.
# For an offline/air-gapped ISO, replace with `cdrom` and build via
# livemedia-creator instead of mkksiso (see forge-iso/README.md).
url --mirrorlist="https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-$releasever&arch=$basearch"
repo --name=updates --mirrorlist="https://mirrors.fedoraproject.org/mirrorlist?repo=updates-released-f$releasever&arch=$basearch"

# On-ISO forge repo — ships forge-release, forge-logos, forge-backgrounds.
# Built by forge-packages/build-rpms.sh and dropped into /forge/repo by
# forge-iso/build.sh. Referenced here so the %packages block below can
# install them without network access.
repo --name=forge --baseurl=hd:LABEL=FORGE:/forge/repo --install --cost=50

# --- Install mode ------------------------------------------------------------
text
skipx
firstboot --disable
reboot --eject

# --- Security ----------------------------------------------------------------
selinux --enforcing
firewall --enabled --service=ssh,cockpit
services --enabled=sshd,chronyd,cockpit.socket,firewalld

# --- Auth --------------------------------------------------------------------
# The installer will prompt anaconda to create a root password + user. If you
# want a fully-unattended image, uncomment and set below (use
# `openssl passwd -6` to generate the hashes, don't ship cleartext).
#rootpw --iscrypted $6$...
#user --name=forge --groups=wheel --iscrypted --password=$6$...
rootpw --lock
# Force interactive user creation on first boot so no default credentials exist
# in shipped ISOs. Operators can swap in --iscrypted lines for automated fleets.

# --- Bootloader --------------------------------------------------------------
bootloader --location=mbr --append="rhgb quiet"

# --- Disk layout -------------------------------------------------------------
# `forge.disk=<dev>` on the kernel cmdline wins; otherwise use the first disk
# that looks like a system disk (set by %pre into /tmp/part-include).
%include /tmp/part-include

# --- Package set -------------------------------------------------------------
# Mirrors roles/forge_*/defaults/main.yml. Keep the two in sync when you
# touch either side.
%packages --exclude-weakdeps
@^server-product-environment
@virtualization

# Base / ops
policycoreutils-python-utils
firewalld
chrony
dnf-automatic
dnf-plugins-core
tuned
tmux
htop
lsof
strace
git
curl
jq
pciutils
usbutils
rsync
bash-completion
bind-utils
nvme-cli
smartmontools
lm_sensors

# Cockpit core
cockpit
cockpit-machines
cockpit-podman
cockpit-storaged
cockpit-networkmanager
cockpit-packagekit
cockpit-pcp
cockpit-selinux
cockpit-sosreport

# Virt extras (on top of @virtualization)
libvirt-daemon-kvm
libvirt-client
qemu-kvm
qemu-img
virt-install
virt-top
guestfs-tools
libguestfs-tools
swtpm
edk2-ovmf
python3-libvirt

# Clustering (optional per-node; only configured if the node joins a cluster)
pacemaker
pcs
fence-agents-all
corosync
resource-agents
sbd

# Backup tooling
sanoid
restic
pv
mbuffer
lzop

# Kernel headers for OpenZFS kmod (installed in %post from zfsonlinux.org)
kernel-devel
kernel-headers

# forge branding — these Obsolete fedora-release/fedora-logos/fedora-backgrounds
# cleanly, so /etc/os-release, Plymouth, and anaconda all say "forge Linux".
forge-release
forge-release-common
forge-logos
forge-backgrounds

# forge Cockpit UI — theme + overview landing page.
forge-cockpit-ui

# Remove things we don't want on a hypervisor
-PackageKit-command-not-found
%end

# =============================================================================
# %pre — runs before partitioning
# =============================================================================
%pre --interpreter=/bin/bash --log=/tmp/forge-pre.log
set -euo pipefail

# Pick the install disk. Priority:
#   1. `forge.disk=/dev/XXX` on the kernel cmdline
#   2. First NVMe namespace
#   3. First /dev/sdX
INSTALL_DISK=""
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        forge.disk=*) INSTALL_DISK="${arg#forge.disk=}" ;;
    esac
done

if [ -z "$INSTALL_DISK" ]; then
    for candidate in /dev/nvme0n1 /dev/sda /dev/vda; do
        if [ -b "$candidate" ]; then
            INSTALL_DISK="$candidate"
            break
        fi
    done
fi

if [ -z "$INSTALL_DISK" ] || [ ! -b "$INSTALL_DISK" ]; then
    echo "forge: could not determine install disk" >&2
    exit 1
fi

# Short name for part commands ("nvme0n1" → basename, anaconda expects this).
DISK_SHORT="$(basename "$INSTALL_DISK")"

cat > /tmp/part-include <<EOF
zerombr
clearpart --drives=${DISK_SHORT} --all --initlabel
ignoredisk --only-use=${DISK_SHORT}

part /boot/efi --fstype=efi      --size=1024 --ondisk=${DISK_SHORT} --fsoptions="umask=0077,shortname=winnt"
part /boot     --fstype=xfs      --size=1024 --ondisk=${DISK_SHORT}
part swap                        --size=4096 --ondisk=${DISK_SHORT}
part /         --fstype=xfs      --size=102400 --ondisk=${DISK_SHORT}
EOF

echo "forge: installing to ${INSTALL_DISK}" >&2
%end

# =============================================================================
# %post — first-boot configuration (runs chrooted in the installed system)
# =============================================================================
%post --interpreter=/bin/bash --log=/var/log/forge-post.log
set -euo pipefail

# The scripts are packed into initrd by mkksiso at /run/install/repo/forge/post.
# Copy them in so first-boot can see them in /var/lib/forge/post/ for debug.
mkdir -p /var/lib/forge
if [ -d /run/install/repo/forge ]; then
    cp -a /run/install/repo/forge /var/lib/forge/installer
fi

# Run each numbered script in order. Fail fast.
for script in /var/lib/forge/installer/post/*.sh; do
    echo "forge-post: running $script"
    bash "$script"
done

# Install the firstboot helper that waits for the operator to create a user
# and (optionally) import/create a ZFS pool before declaring the host ready.
install -D -m 0644 /var/lib/forge/installer/firstboot/forge-firstboot.service \
    /etc/systemd/system/forge-firstboot.service
install -D -m 0755 /var/lib/forge/installer/firstboot/forge-firstboot.sh \
    /usr/local/sbin/forge-firstboot
systemctl enable forge-firstboot.service

# Branded MOTD
install -D -m 0644 /var/lib/forge/installer/files/motd /etc/motd

# Version stamp for `forge --version`, logs, Cockpit about dialog
mkdir -p /etc/forge
cat > /etc/forge/release <<EOF
NAME="forge"
VERSION="${FORGE_VERSION:-0.1.0}"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BASE="Fedora $(rpm --eval %fedora)"
EOF
%end
