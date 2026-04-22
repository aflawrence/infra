# forge-iso

Builds `forge-<version>.iso` — a bootable installer that lays down Fedora
Server, OpenZFS, Cockpit + 45Drives Houston modules, KVM/libvirt, Pacemaker,
and Sanoid/Restic in one go. Boot it, let it run, log into Cockpit. Matches
the package/config decisions made by the Ansible playbook in `../forge.yml`
so both delivery mechanisms produce the same box.

## How it works

1. **Source**: a stock Fedora Server netinstall ISO (downloaded at build time
   or supplied locally via `SOURCE_ISO=`).
2. **`mkksiso`** (from `lorax`) embeds `forge.ks` plus the `post/`,
   `firstboot/`, and `files/` trees into that ISO and sets the bootloader
   cmdline to auto-run the kickstart.
3. **At install time**, anaconda follows `forge.ks` — partitions the chosen
   disk (xfs `/`, xfs `/boot`, efi, swap; leaves other disks for ZFS),
   installs the package set, then runs each `post/*.sh` in order to enable
   repos, install ZFS/Houston modules, and stage sanoid.
4. **At first boot**, `forge-firstboot.service` drops the operator into an
   interactive console wizard: create admin user, pick the VM bridge NIC,
   optionally build a ZFS pool, print the Cockpit URL, then disable itself.

## Build

### In a container (recommended — reproducible)

```bash
podman build -t forge-iso-builder -f forge-iso/Containerfile .
mkdir -p out
podman run --rm -it --privileged \
    -v "$PWD/forge-iso:/src:Z" \
    -v "$PWD/out:/out:Z" \
    forge-iso-builder /src/build.sh
# Result: ./out/forge-0.1.0-x86_64.iso
```

### On a Fedora host directly

```bash
sudo dnf install lorax xorriso isomd5sum pykickstart
./forge-iso/build.sh
```

### Knobs

| Env var         | Default          | What it does                                      |
|-----------------|------------------|---------------------------------------------------|
| `FEDORA_VER`    | `41`             | Fedora release to base on                         |
| `FORGE_VERSION` | `0.1.0`          | Stamped into `/etc/forge/release`                 |
| `ARCH`          | `x86_64`         | ISO architecture                                  |
| `SOURCE_ISO`    | (auto-download)  | Path to an already-downloaded netinstall ISO      |
| `OUTPUT_DIR`    | `/out`           | Where the built ISO is written                    |

## Install

1. Write to USB: `sudo dd if=out/forge-0.1.0-x86_64.iso of=/dev/sdX bs=4M
   status=progress oflag=direct && sync` (or use `balena-etcher` / Ventoy).
2. Boot the target machine. The installer runs unattended — no operator
   clicks needed unless `forge.disk=` is unset *and* the host has no
   `/dev/nvme0n1`, `/dev/sda`, or `/dev/vda`.
3. After the automatic reboot, the console lands in `forge-firstboot`:
   - set admin password
   - optionally paste an SSH key
   - pick the NIC for `br0`
   - optionally create a ZFS pool
4. Open `https://<host>:9090` and log in. You now have: KVM, Podman, ZFS,
   file sharing, scheduler, benchmarking, navigator, identities, storage,
   networking, logs, SELinux, sosreport, and live updates in the UI.

## Deviations from Proxmox-style behavior

- **Root filesystem is XFS, not ZFS.** ZFS-on-root in an anaconda-driven
  installer needs a custom addon, which is a meaningful amount of code we
  didn't want in v1. Data pools on ZFS work fine — which matches how a lot
  of Proxmox deployments actually run (XFS root + ZFS for `/tank`).
  ZFS-on-root is tracked as a future enhancement; see "Future work" below.
- **Netinstall by default.** Hosts need network during install to pull
  packages. For an offline-capable ISO, switch `url --mirrorlist=...` in
  `forge.ks` to `cdrom` and rebuild against the full Server DVD with
  `livemedia-creator` instead of `mkksiso`.
- **No silent install**. `rootpw --lock` is the default so published ISOs
  never ship with a known password. Uncomment the `rootpw --iscrypted` /
  `user --iscrypted` lines in `forge.ks` for fleet-wide automated installs.

## Future work

- ZFS-on-root via an anaconda addon (or a `%pre --nochroot` that partitions
  manually and bootstraps via `dnf --installroot`).
- Offline ISO target via `livemedia-creator --make-iso`.
- Signed ISO + UEFI SecureBoot shim with our own MOK, so the installed
  system passes SB with the OpenZFS kmod in place.
- A Cockpit "forge" module that replaces `forge-firstboot.sh`'s console UX
  with a browser wizard.
