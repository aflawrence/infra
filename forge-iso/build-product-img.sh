#!/bin/bash
# build-product-img.sh — produce the anaconda product.img that rebrands the
# installer UI from "Fedora" to "forge Linux".
#
# Anaconda discovers this file on the ISO at /images/product.img. The image
# is a gzip'd cpio archive; at startup the installer mounts it as an overlay
# on top of its own /usr tree, which lets us drop in:
#   • /usr/share/anaconda/product.d/forge.conf — rebrand strings
#   • /usr/share/anaconda/pixmaps/forge-*.png  — sidebar/logo artwork
#   • /usr/share/anaconda/eula/forge-eula.txt  — license screen text
#   • /.buildstamp                             — installer product identity
#
# Reference: https://anaconda-installer.readthedocs.io/en/latest/product.html
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
: "${FEDORA_VER:=41}"
: "${FORGE_VERSION:=0.1.0}"
: "${OUT:=${SCRIPT_DIR}/product.img}"

command -v cpio >/dev/null || { echo "cpio required" >&2; exit 2; }

SRC_TREE="${SCRIPT_DIR}/product-img"
[ -d "$SRC_TREE" ] || { echo "missing ${SRC_TREE}" >&2; exit 3; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Copy the source tree, templating out variables that can't live in the
# committed files (they depend on the build context).
cp -a "$SRC_TREE/." "$STAGE/"

# Substitute %FEDORA_VERSION% → the Fedora release being based on.
# Substitute %FORGE_BUILDSTAMP_UUID% → a fresh uuid per build, which anaconda
# uses to detect a partial install from a different build.
UUID="$(uuidgen)"
find "$STAGE" -type f \( -name '*.conf' -o -name '.buildstamp' \) -print0 |
    while IFS= read -r -d '' f; do
        sed -i \
            -e "s|%FEDORA_VERSION%|${FEDORA_VER}|g" \
            -e "s|%FORGE_BUILDSTAMP_UUID%|${UUID}|g" \
            "$f"
    done

# Bake the pixmaps from forge-logos (if already built into the repo) into
# the product.img so they're available to anaconda from the very first
# screen. If the forge-logos RPM hasn't been built yet, we skip — anaconda
# will fall back to Fedora defaults for those specific screens, which is
# cosmetic only.
LOGO_RPM_DIR="${SCRIPT_DIR}/../forge-packages/repo"
if compgen -G "${LOGO_RPM_DIR}/forge-logos-*.rpm" >/dev/null; then
    LOGOS_RPM="$(ls -1 "${LOGO_RPM_DIR}"/forge-logos-*.rpm | head -n 1)"
    echo "==> Extracting pixmaps from ${LOGOS_RPM}"
    mkdir -p "${STAGE}/tmp-extract"
    (
        cd "${STAGE}/tmp-extract"
        rpm2cpio "$LOGOS_RPM" | cpio -idm --quiet \
            './usr/share/anaconda/pixmaps/*' './usr/share/plymouth/themes/forge/*' || :
    )
    rsync -a "${STAGE}/tmp-extract/usr/" "${STAGE}/usr/" || :
    rm -rf "${STAGE}/tmp-extract"
else
    echo "==> NOTE: forge-logos RPM not found — anaconda will use Fedora default pixmaps"
    echo "    (run forge-packages/build-rpms.sh first for full rebrand)"
fi

# Produce the product.img. Format: gzip-compressed newc cpio archive rooted
# at /. anaconda only looks at paths below the root, so we need the cpio
# stream to list paths like './usr/share/anaconda/...' (note the leading
# dot — standard newc convention).
(
    cd "$STAGE"
    find . -print | cpio --quiet -o -H newc | gzip -9
) > "$OUT"

echo "==> Wrote ${OUT} ($(stat -c %s "$OUT") bytes)"
