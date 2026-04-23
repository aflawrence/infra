#!/bin/bash
# Activate forge branding on the installed system. Most of this is declared
# by the forge-release / forge-logos RPMs via their Obsoletes + %post
# scriptlets — we just belt-and-braces here so a minimally broken build
# still produces something consistent.
set -euo pipefail

# /etc/os-release — should already be the forge-release one, but if anything
# left a stray symlink, point it back at the canonical file.
if [ ! -L /etc/os-release ] && [ -f /usr/lib/os-release ]; then
    ln -sf ../usr/lib/os-release /etc/os-release
fi

# Plymouth theme — forge-logos's %post already calls plymouth-set-default-theme,
# but only if plymouth is installed. On a server install with `-plymouth`
# excluded it's a no-op, which is correct.
if command -v plymouth-set-default-theme &>/dev/null; then
    plymouth-set-default-theme forge -R 2>/dev/null || \
    plymouth-set-default-theme forge     2>/dev/null || :
fi

# GRUB boot menu title — anaconda writes "Fedora Linux" by default. Rewrite
# to match the forge identity so the boot menu matches the OS inside.
if [ -f /etc/default/grub ]; then
    sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="forge Linux"/' /etc/default/grub
    if command -v grub2-mkconfig &>/dev/null; then
        for cfg in /boot/grub2/grub.cfg /boot/efi/EFI/fedora/grub.cfg; do
            [ -f "$cfg" ] && grub2-mkconfig -o "$cfg" 2>/dev/null || :
        done
    fi
fi

# Ensure the attribution notice ends up somewhere an operator can see it
# without having to dig through /usr/share/licenses.
install -D -m 0644 /usr/share/licenses/forge-release/ATTRIBUTION /etc/forge/ATTRIBUTION 2>/dev/null || :
