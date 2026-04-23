# forge — hardware bring-up

Step-by-step from a fresh clone to Cockpit open in your browser. Assumes
you have either:

- **A Fedora / RHEL / Rocky / Alma host** for building + smoke-testing, or
- **Podman** installed anywhere (macOS / Linux / WSL2) + a Linux target
  machine for the actual hardware install.

The fast path — smoke-test in a VM first, then burn a USB — is ~2 hours end-to-end.

## 0. Clone + pre-flight

```bash
git clone https://github.com/aflawrence/infra.git
cd infra
git checkout claude/fedora-proxmox-alternative-vM62W
./forge-iso/pre-flight.sh
```

Pre-flight verifies the build tools are installed, the repo is intact, and
your host can reach the Fedora mirror. Fix anything it flags red.

## 1. Build the ISO

Recommended — reproducible in a container so your host doesn't need any
build deps:

```bash
podman build -t forge-iso-builder -f forge-iso/Containerfile .

mkdir -p out
podman run --rm -it --privileged \
    -v "$PWD:/src:Z" \
    -v "$PWD/out:/out:Z" \
    forge-iso-builder /src/forge-iso/build.sh
```

Produces `out/forge-0.1.0-x86_64.iso` (~1.4 GB, depending on the Fedora
Server netinst baseline). The first build takes ~10-15 minutes because it
downloads the Fedora netinstall ISO and rasterizes all the logo PNG sizes.
Subsequent builds are under a minute if the source ISO is cached.

Non-container path (Fedora host only):

```bash
sudo dnf install lorax xorriso isomd5sum pykickstart rpm-build createrepo_c \
                 librsvg2-tools ImageMagick cpio
./forge-iso/build.sh
```

## 2. Smoke-test in QEMU (do this BEFORE burning a USB)

This is the iteration loop. Each install cycle is ~10 minutes; compare to
5-10 minutes *per flash* on a real USB.

```bash
# install from the ISO into a throwaway 40G virtual disk
./forge-iso/smoke-test.sh install
```

A QEMU window opens (Spice by default — connect with `remote-viewer
spice://localhost:5930` if it doesn't pop up directly). You'll see:

1. **UEFI → GRUB menu** — forge entry auto-selected after 10s
2. **Anaconda** runs unattended from the embedded kickstart; ~5 minutes
3. **Reboot** — VM ejects the CD, boots the installed system
4. **tty1: forge-firstboot wizard** — admin user + optional NIC + optional
   ZFS pool. For the VM: pick `br0` → `enp1s0`, then build a 3-disk
   mirror ZFS pool out of `/dev/vdb`, `/dev/vdc`, `/dev/vdd`.
5. **Cockpit comes up** — open https://localhost:9090 in your host
   browser. Self-signed cert; click through. Log in as the user you just
   created.

**What to verify:**
- Login page shows the forge logo + dark theme (forge-cockpit-ui branding)
- The **"Overview"** entry is the top sidebar item (forge-overview module)
- The four cards populate within 10s: Cluster shows "not configured",
  Storage lists your `tank` pool with a green `ONLINE` badge, Backups
  shows `sanoid.timer` scheduled, VMs shows `0 / 0`.
- `/etc/os-release` says `forge Linux` (open the Cockpit terminal)
- `cat /etc/forge/ATTRIBUTION` shows the Fedora trademark notice

If something's off, the most common culprits are in the troubleshooting
section below. Fix on the host, rebuild the RPM or the ISO, and re-run.

**After a fix, re-run just what changed:**

```bash
# only the forge-cockpit-ui RPM changed
rm -rf forge-packages/repo/forge-cockpit-ui-*.rpm
forge-packages/build-rpms.sh              # rebuilds the repo
forge-iso/build.sh                         # rebuilds the ISO against it
./forge-iso/smoke-test.sh clean            # wipe the VM state
./forge-iso/smoke-test.sh install          # fresh cycle
```

## 3. Write to USB

Once the smoke test passes, the ISO is hardware-ready.

**Fedora Media Writer** (recommended, cross-platform):
1. Open FMW.
2. Click **"Custom image"**.
3. Browse to `out/forge-0.1.0-x86_64.iso`.
4. Pick your USB drive.
5. Write. ~2 minutes on a USB 3 stick.

**`dd`** (Linux / macOS):

```bash
# ⚠ double-check /dev/sdX with `lsblk` — dd will not ask twice
sudo dd if=out/forge-0.1.0-x86_64.iso of=/dev/sdX bs=4M status=progress oflag=direct
sync
```

**Rufus** / **balenaEtcher** / **Ventoy** all work — Ventoy is nice for
iterating because you just drop the ISO onto a Ventoy-prepared stick, no
reflash per build.

## 4. Boot the target machine

### BIOS prerequisites

Enter BIOS/UEFI on the target and verify:

| Setting | Required state | Why |
|---|---|---|
| VT-x / AMD-V (virtualization) | **enabled** | KVM guests need it |
| IOMMU (VT-d / AMD-Vi) | enabled (optional) | PCIe passthrough later |
| Secure Boot | **disabled** (for now) | OpenZFS kmod isn't signed with a key Fedora's shim trusts. See "Secure Boot" below. |
| CSM / Legacy boot | disabled | forge's ISO is UEFI-hybrid; pure UEFI is cleanest |
| Boot order | USB stick first | |

### Install

Boot the target from USB. The unattended kickstart runs; you shouldn't
need to touch the keyboard unless:

- **The first heuristic disk is wrong.** Default order is `/dev/nvme0n1 →
  /dev/sda → /dev/vda`. If your system has an unusual layout, interrupt
  the GRUB timer and append `forge.disk=/dev/<correct>` to the kernel
  cmdline.
- **No DHCP.** Anaconda will drop into a text UI asking for network
  config. Fill it in; kickstart resumes automatically.

Install takes ~10-20 minutes on modern hardware (mostly download time from
the Fedora mirror). When it reboots, disconnect the USB.

### Firstboot

Console drops into the forge-firstboot wizard on tty1. Walk through:

1. **Admin user** — username, password, paste SSH pubkey.
2. **VM bridge** — pick the NIC you want VMs to share. The wizard preserves
   the existing IP configuration, moving it from the physical NIC onto
   `br0`.
3. **ZFS pool** — optional. If you want to create it later from the UI,
   skip. Otherwise enter pool name + vdev type + space-separated disks.
4. **Final screen** prints the Cockpit URL.

### Open Cockpit

From another machine on the same network:

```
https://<host-ip-or-hostname>:9090
```

Log in as the user you just created. You should see the forge Overview as
the landing page with all four cards populating.

## Troubleshooting

### The installer boots but hangs at "Starting installation"

Almost always a network issue. The kickstart uses netinstall; if the target
can't reach `dl.fedoraproject.org`, anaconda stalls here. Drop to a text
shell (Ctrl-Alt-F2), run `ip a` and `curl -v https://dl.fedoraproject.org`.
If DNS is the issue, edit `/etc/resolv.conf` in the installer env and
retry.

### OpenZFS refused to install during %post

Check `/var/log/forge-post.log` after the first reboot:

```bash
sudo cat /var/log/forge-post.log | grep -i zfs
```

Most common causes:

- The `zfs-release` RPM URL returned 404 because the OpenZFS team bumped
  their version number. Edit `roles/forge_zfs/defaults/main.yml` →
  `forge_zfs_repo_release_version` and rebuild the ISO.
- `zfs-kmod` isn't built for the kernel anaconda installed. Rare but
  happens during a Fedora kernel bump. The post script falls back to
  `zfs-dkms`, which will build the module on the next boot — look in
  `journalctl -u dkms` after reboot.

### Plymouth splash is Fedora, not forge

Plymouth theme activation requires an initramfs rebuild. `plymouth-set-default-theme
forge -R` should run during install; verify with:

```bash
plymouth-set-default-theme   # should print "forge"
ls /usr/share/plymouth/themes  # should list "forge"
sudo dracut -f                 # rebuild
sudo reboot
```

### Cockpit opens but looks like stock Fedora

The branding dir is tied to `/etc/os-release` `ID=`. Verify:

```bash
grep ^ID= /etc/os-release          # should print ID=forge
ls /usr/share/cockpit/branding     # should include "forge"
rpm -q forge-release forge-cockpit-ui
```

If either RPM is missing, the on-ISO forge repo didn't get consumed
during install — check `/var/log/anaconda/dnf.log` for the `hd:LABEL=FORGE`
repo lines.

### "Overview" entry isn't at the top of the Cockpit sidebar

Cache. Hard-refresh the page (Ctrl-Shift-R in most browsers) or restart
the Cockpit socket:

```bash
sudo systemctl restart cockpit.socket
```

Still missing? Verify the module is installed:

```bash
ls /usr/share/cockpit/forge-overview/
rpm -V forge-cockpit-ui     # checks file integrity
```

### Secure Boot

If you want Secure Boot enabled (good idea for production), two options:

1. **Enroll the OpenZFS MOK** at first boot (the `mokutil import` path).
   OpenZFS signs its kmod with their own key; you accept it once via the
   shim prompt.
2. **Sign the ZFS modules with your own MOK** during image build (more
   work, full control — this is a future-release item).

For now, the runbook above says to disable SB. Re-enable once you've
vetted the enrollment path on your specific hardware.

### Network card missing from the firstboot wizard

The wizard only lists `nmcli` device types that are `ethernet`. If your
NIC showed up as `wifi` or `wwan`, that's intentional — we want the VM
bridge on wired. If a physical wired NIC is missing, `lspci | grep -i net`
to confirm it's detected, then `nmcli device` to see why NetworkManager
doesn't own it (common: missing firmware, check `dmesg`).

## Iteration cadence (the healthy loop)

1. Change a file
2. `./forge-iso/pre-flight.sh` (catches regressions in the build tree)
3. `./forge-iso/build.sh` (if you changed anything under `forge-packages/`
   or `forge-iso/`; skips unchanged RPMs)
4. `./forge-iso/smoke-test.sh install`
5. Poke at the VM in the browser
6. `./forge-iso/smoke-test.sh clean` — reset for the next cycle

Keep iterating in the VM. Only burn a USB when you've got a candidate
that'd feel safe to install on a box you'd actually deploy.
