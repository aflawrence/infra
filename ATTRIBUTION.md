# Attribution & trademark notice

**forge Linux** is an independent, open-source project based on **Fedora Linux**.

Fedora is a registered trademark of **Red Hat, Inc.** Red Hat, Inc. is
neither affiliated with the forge project nor endorses it. The forge project
is not produced, sponsored, reviewed, or approved by Red Hat or the Fedora
Project.

## What forge redistributes

forge Linux boots from a composition of binary packages from:

| Source | License family | Role in forge |
|---|---|---|
| [Fedora Project](https://getfedora.org) | GPL / LGPL / MIT / Apache / BSD / others (per package) | Base OS, kernel, userspace, Cockpit |
| [OpenZFS](https://openzfs.org) | CDDL-1.0 | ZFS kernel module (built as an out-of-tree DKMS/kmod) |
| [45Drives Houston](https://github.com/45Drives) | LGPL / MIT (per module) | Cockpit extension modules |

Each package retains its own license. Nothing in forge's packaging, branding,
or documentation replaces, supersedes, or modifies any upstream license.

## What forge adds

forge itself contributes only **packaging glue** on top of the above:

- `forge-release`, `forge-logos`, `forge-backgrounds` — branding RPMs with
  distinct visual identity. No Fedora trademarks, logos, or "Infinity"
  marks are reproduced.
- A kickstart file (`forge-iso/forge.ks`), post-install scripts, and a
  firstboot TUI.
- An Ansible role tree (`roles/forge_*`) that configures the same stack
  without going through the ISO.
- An anaconda `product.img` that rebrands the installer UI.

All forge-authored code is under the **MIT license**. Source is at:
<https://github.com/aflawrence/infra>

## Trademark compliance

forge follows the [Fedora Trademark
Guidelines](https://fedoraproject.org/wiki/Legal:Trademark_guidelines):

1. The word "Fedora" is used only in factual, descriptive contexts
   ("based on Fedora Linux").
2. No Fedora logos are reproduced in forge-branded materials.
3. The installer UI, boot splash, MOTD, and `/etc/os-release` identify the
   system as "forge Linux", not Fedora.
4. This notice ships on every installed system at
   `/usr/share/licenses/forge-release/ATTRIBUTION` and
   `/etc/forge/ATTRIBUTION`.

## Source availability

For GPL compliance and general transparency:

- **Fedora source:** every Fedora binary RPM is built from source RPMs
  hosted at <https://koji.fedoraproject.org>. Dist-git at
  <https://src.fedoraproject.org>.
- **OpenZFS source:** <https://github.com/openzfs/zfs>.
- **45Drives Houston source:** <https://github.com/45Drives>.
- **forge source:** <https://github.com/aflawrence/infra>. Includes every
  spec file, asset, kickstart, and Ansible role used to build a forge ISO.

If you received a forge binary (ISO or RPM) and cannot reach the repositories
above, open an issue on the forge repo and we'll provide a matching source
archive.
