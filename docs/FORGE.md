# forge — a Fedora-based Proxmox alternative

`forge.yml` builds a Proxmox-VE-style hypervisor platform on top of
**Fedora Server** using only open, upstream components. It is intentionally
modular: every capability is a separate role you can enable or disable.

## Mapping to Proxmox VE

| Proxmox component            | forge equivalent                                        | Role               |
|------------------------------|---------------------------------------------------------|--------------------|
| Debian base                  | Fedora Server (40+)                                     | `forge_base`       |
| Web UI (pve-manager)         | **Cockpit** + 45Drives Houston modules                  | `forge_cockpit`, `forge_houston` |
| KVM / QEMU / libvirt         | KVM / QEMU / libvirt (same thing, stock upstream)       | `forge_virt`       |
| LXC                          | systemd-nspawn + Podman (via `cockpit-podman`)          | `forge_virt`       |
| ZFS on root / as storage     | OpenZFS (`zfs-kmod`) via zfsonlinux.org                 | `forge_zfs`        |
| Cluster manager (corosync)   | Pacemaker + Corosync (upstream)                         | `forge_cluster`    |
| HA VMs                       | Pacemaker `VirtualDomain` resource + libvirt migration  | `forge_cluster`    |
| Ceph (optional)              | Not in scope here — use Ceph, Gluster, or NFS separately |                    |
| Proxmox Backup Server        | **Sanoid** (snapshot policy) + **Syncoid** (ZFS send/recv replication) + **Restic** (off-site) | `forge_backup` |

## Why this stack

- **Cockpit** gives you a browser dashboard for hosts, VMs, containers,
  storage, networking, logs, SELinux and live updates — without paying for
  or carrying a Proxmox subscription.
- **45Drives Houston modules** layer on ZFS pool/dataset management, Samba /
  NFS share admin, a file browser, a scheduler UI, and disk benchmarking —
  the features Proxmox's UI does *not* give you, and the bits NAS users miss
  most.
- **OpenZFS** via the official kmod packages means snapshots, send/recv,
  native encryption, compression (zstd), ARC caching, and RAIDZ/mirror
  flexibility are first-class — not bolted on.
- **Pacemaker + Corosync** is what Proxmox uses under the hood (as of PVE 8
  they ship corosync 3); running it upstream gives you the same quorum/
  fencing primitives with more flexibility on fence agents.
- **Sanoid/Syncoid** is the closest open replacement for the incremental,
  dedup'd replication that PBS provides — because ZFS already does the hard
  work. **Restic** plugs the "encrypted off-site to S3/B2/SFTP" gap.

## Layout

```
forge.yml                    # main playbook
group_vars/forge/
  vars.yml                   # all configuration lives here
  secret.yml.example         # ansible-vault template
roles/
  forge_base/                # dnf-automatic, firewalld, tuned, chrony, admin user
  forge_zfs/                 # OpenZFS repo, kmod, ARC cap, pools, datasets
  forge_cockpit/             # Cockpit + core modules + firewalld rules
  forge_houston/             # 45Drives repo + Cockpit modules
  forge_virt/                # KVM/libvirt, bridge, libvirt storage pools on ZFS
  forge_cluster/             # pcs auth, cluster setup, SBD fencing
  forge_backup/              # sanoid timer, syncoid timers, optional restic
hosts_forge_example          # inventory template
```

## Deployment

1. Install Fedora Server on every node, create a sudo user, drop your SSH
   key, and make sure hostnames resolve between nodes (DNS or `/etc/hosts`).
2. Copy and edit the inventory + vars:
   ```bash
   cp hosts_forge_example hosts_forge
   cp group_vars/forge/secret.yml.example group_vars/forge/secret.yml
   ansible-vault encrypt group_vars/forge/secret.yml
   ```
3. Set at minimum in `group_vars/forge/vars.yml`:
   - `forge_admin_user`, `forge_admin_ssh_keys`
   - `forge_mgmt_cidr`, `forge_vm_bridge_interface`
   - `forge_zfs_pools` (or leave empty and create in Cockpit)
   - `forge_cluster_sbd_device` if using SBD fencing
4. Run:
   ```bash
   ansible-playbook -i hosts_forge forge.yml
   ```
5. Visit `https://<node>:9090` — log in with your sudo user. You'll see
   Overview, Virtual Machines, Podman, Storage, Networking, ZFS, File
   Sharing, Navigator, Scheduler, Benchmark.

## Typical ZFS layout

The defaults assume a single pool named `tank`:

```
tank/vm       recordsize=64K zstd-3   → libvirt "vm" storage pool (qcow2 images)
tank/ct       recordsize=128K zstd-3  → podman graph root / nspawn rootfs
tank/iso      zstd-3                  → libvirt "iso" pool (install media)
tank/backup   recordsize=1M zstd-9    → syncoid replication target, restic source
```

`tank/vm` and `tank/ct` are covered by the sanoid `production` template
(hourly / daily / weekly / monthly / yearly). Syncoid then pushes them to
another node's `tank/backup`. Restic optionally pushes `tank/backup` off-site
to B2/S3/SFTP.

## HA / live migration

`forge_cluster` runs on the primary node and configures every member. After
it finishes you can:

- `pcs status` to see the cluster
- From cockpit-machines: right-click a VM → Migrate → pick a target node
- To make a VM HA, wrap it as a Pacemaker `VirtualDomain` resource:
  ```
  pcs resource create my-vm VirtualDomain \
      config=/etc/libvirt/qemu/my-vm.xml \
      migration_transport=ssh \
      meta allow-migrate=true \
      op monitor interval=30s
  ```
  Pacemaker will restart or fail over the VM on node loss, provided the
  underlying storage is shared — either via ZFS send/recv replication (cold
  failover) or via a shared LUN / NFS / Ceph (live failover).

## Backups as a PBS alternative

PBS gives you: incremental, dedup'd, encrypted backups to a central server
with pruning and verify. Here's how that maps:

| PBS feature         | forge_backup implementation                                 |
|---------------------|-------------------------------------------------------------|
| Incremental         | ZFS send -i (syncoid handles bookmarks/holds)               |
| Dedup               | ZFS dedup is off by default (per-dataset compression instead); restic does content-addressed dedup off-site |
| Encryption          | ZFS native encryption for the source datasets; restic AES-256 for off-site |
| Pruning             | Sanoid retention templates; `restic forget --prune`         |
| Verify              | `zpool scrub` on the target; `restic check --read-data-subset` |
| Web UI              | `cockpit-scheduler` shows all timers; `cockpit-zfs-manager` shows snapshots |

## Non-goals

- **Ceph**. If you want hyperconverged block storage, run Ceph separately
  and point libvirt at it — don't try to recreate Proxmox's built-in Ceph
  installer here.
- **Built-in GUI for VM templates / cloud-init**. `cockpit-machines` covers
  basic create/start/stop/migrate; for heavy template-driven provisioning
  use `virt-builder`, Packer, or Terraform with the libvirt provider.
- **Official support**. This is infrastructure-as-code for a self-hosted
  hypervisor — there is no support contract behind it.
