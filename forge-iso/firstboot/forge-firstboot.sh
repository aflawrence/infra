#!/bin/bash
# forge-firstboot — interactive setup that runs on console login after
# anaconda finishes. Disables itself once complete so it never runs twice.
#
# Scope is deliberately narrow: do the things we COULDN'T do at install time
# (because they depend on hardware the installer doesn't know about), and
# direct the operator at Cockpit for everything else.
#
# What this does:
#   1. Create/reset the admin user (`forge` by default) + sudo + SSH key
#   2. Ask which physical NIC to enslave into the `br0` bridge for VMs
#   3. Offer to create a ZFS pool (or skip and do it later in Cockpit)
#   4. Print the Cockpit URL and a short next-steps list
#   5. Disable this service
set -euo pipefail

STATE_FILE=/var/lib/forge/firstboot.done
if [ -e "$STATE_FILE" ]; then
    exit 0
fi

banner() {
    clear
    cat <<'EOF'
================================================================================
  forge — first-boot setup
  Fedora-based hypervisor platform • Cockpit + Houston + OpenZFS
================================================================================
EOF
    echo
}

prompt() {
    # prompt <varname> <question> [default]
    local __var="$1" __q="$2" __def="${3:-}"
    local __ans
    if [ -n "$__def" ]; then
        read -r -p "$__q [$__def]: " __ans || true
        __ans="${__ans:-$__def}"
    else
        read -r -p "$__q: " __ans
    fi
    printf -v "$__var" '%s' "$__ans"
}

confirm() {
    local q="$1" ans
    read -r -p "$q [y/N]: " ans || true
    [[ "$ans" =~ ^[Yy]$ ]]
}

# -----------------------------------------------------------------------------
# 1. Admin user
# -----------------------------------------------------------------------------
banner
echo "Step 1/4 — Admin user"
echo
prompt ADMIN_USER "Admin username" "forge"

if ! id "$ADMIN_USER" &>/dev/null; then
    useradd -m -s /bin/bash -G wheel "$ADMIN_USER"
fi

echo "Set a password for ${ADMIN_USER} (this account can sudo):"
passwd "$ADMIN_USER"

if confirm "Paste an authorized SSH public key for ${ADMIN_USER}?"; then
    mkdir -p "/home/${ADMIN_USER}/.ssh"
    chmod 700 "/home/${ADMIN_USER}/.ssh"
    echo "Paste one ssh-ed25519 / ssh-rsa line, then press Enter:"
    read -r SSH_KEY
    if [ -n "$SSH_KEY" ]; then
        echo "$SSH_KEY" >> "/home/${ADMIN_USER}/.ssh/authorized_keys"
        chmod 600 "/home/${ADMIN_USER}/.ssh/authorized_keys"
        chown -R "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh"
    fi
fi

# -----------------------------------------------------------------------------
# 2. VM bridge
# -----------------------------------------------------------------------------
banner
echo "Step 2/4 — VM bridge"
echo
echo "Available network interfaces:"
nmcli -t -f DEVICE,TYPE,STATE device | awk -F: '$2=="ethernet"{printf "  • %s (%s)\n", $1, $3}'
echo
prompt NIC "Which interface should the VM bridge (br0) enslave? (blank = skip)" ""

if [ -n "$NIC" ] && nmcli -t -f DEVICE device | grep -qx "$NIC"; then
    # Snapshot the existing IP config so we can move it onto the bridge.
    OLD_CONN="$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v d="$NIC" '$2==d{print $1; exit}')"

    nmcli connection add type bridge ifname br0 con-name br0 stp no
    nmcli connection add type ethernet slave-type bridge ifname "$NIC" \
        master br0 con-name "br0-port-${NIC}"

    if [ -n "$OLD_CONN" ]; then
        nmcli connection down "$OLD_CONN" || true
        nmcli connection delete "$OLD_CONN" || true
    fi
    nmcli connection up br0 || echo "forge: bridge came up but up-command failed; check with 'nmcli c s'"
    echo "forge: br0 now owns ${NIC}"
else
    echo "forge: skipping bridge — create one later from Cockpit → Networking."
fi

# -----------------------------------------------------------------------------
# 3. ZFS pool
# -----------------------------------------------------------------------------
banner
echo "Step 3/4 — Storage"
echo
if ! command -v zpool &>/dev/null; then
    echo "forge: zfs is not installed yet; skipping pool creation."
elif zpool list -H &>/dev/null && [ "$(zpool list -H | wc -l)" -gt 0 ]; then
    echo "forge: existing zpool(s) detected, skipping."
    zpool list
else
    echo "Disks available for a new ZFS pool (excludes the install disk):"
    ROOTDISK="$(findmnt -no SOURCE / | sed 's|/dev/||; s|[0-9]*$||; s|p$||')"
    lsblk -dn -o NAME,SIZE,MODEL | awk -v r="$ROOTDISK" '$1!=r{printf "  • /dev/%-10s %-10s %s\n", $1, $2, $3}'
    echo
    if confirm "Create a ZFS pool now? (can also be done from Cockpit → ZFS)"; then
        prompt POOL_NAME "Pool name" "tank"
        prompt POOL_TYPE "vdev type (mirror, raidz, raidz2, stripe)" "mirror"
        prompt POOL_DISKS "Space-separated disk list (e.g. /dev/sdb /dev/sdc)" ""
        if [ -n "$POOL_DISKS" ]; then
            VDEV_KEYWORD="$POOL_TYPE"
            [ "$POOL_TYPE" = "stripe" ] && VDEV_KEYWORD=""   # zpool syntax quirk
            echo "+ zpool create -f -o ashift=12 -O compression=zstd-3 -O atime=off \\"
            echo "    -O xattr=sa -O acltype=posixacl ${POOL_NAME} ${VDEV_KEYWORD} ${POOL_DISKS}"
            if confirm "Proceed? This will WIPE those disks."; then
                # shellcheck disable=SC2086
                zpool create -f -o ashift=12 \
                    -O compression=zstd-3 -O atime=off -O xattr=sa -O acltype=posixacl \
                    "$POOL_NAME" ${VDEV_KEYWORD} ${POOL_DISKS}
                zfs create "${POOL_NAME}/vm"
                zfs create "${POOL_NAME}/ct"
                zfs create "${POOL_NAME}/iso"
                zfs create -o recordsize=1M -o compression=zstd-9 "${POOL_NAME}/backup"
                # Register libvirt pools against the new datasets.
                for p in vm iso backup; do
                    cat > "/tmp/pool-${p}.xml" <<EOF
<pool type='dir'>
  <name>${p}</name>
  <target><path>/${POOL_NAME}/${p}</path></target>
</pool>
EOF
                    virsh pool-define "/tmp/pool-${p}.xml" || true
                    virsh pool-autostart "$p" || true
                    virsh pool-start "$p" || true
                done
                echo "forge: pool ${POOL_NAME} created and libvirt pools registered."
            fi
        fi
    fi
fi

# -----------------------------------------------------------------------------
# 4. Done
# -----------------------------------------------------------------------------
banner
echo "Step 4/4 — Done"
echo
IP="$(hostname -I | awk '{print $1}')"
cat <<EOF
Forge is up. Next steps:

  • Open Cockpit:   https://${IP:-<this-host>}:9090
  • Log in as:      ${ADMIN_USER}
  • Create VMs:     Cockpit → Virtual Machines
  • Manage ZFS:     Cockpit → ZFS (45Drives)
  • Schedule jobs:  Cockpit → Scheduler (sanoid is already armed)

Build a cluster by installing forge on two more nodes and running the
clustering Ansible role, or pcs cluster setup by hand:
    pcs host auth node1 node2 node3
    pcs cluster setup forge node1 node2 node3 --enable --start

Release info: /etc/forge/release
Logs:         /var/log/forge-post.log
EOF

mkdir -p /var/lib/forge
touch "$STATE_FILE"
systemctl disable forge-firstboot.service
