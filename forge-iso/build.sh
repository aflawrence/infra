#!/bin/bash
# build.sh — produce forge-<version>.iso from a stock Fedora Server DVD.
#
# Approach: download the Fedora Server netinstall/dvd ISO, validate it with
# ksvalidator, then `mkksiso` embeds forge.ks + our support tree so the ISO
# boots straight into an automated forge install.
#
# Usage:
#   ./build.sh                                    # builds with defaults
#   FEDORA_VER=41 FORGE_VERSION=0.1.0 ./build.sh
#   SOURCE_ISO=/path/to/Fedora-Server-netinst.iso ./build.sh   # reuse a local ISO
#
# Expected to run inside the forge-iso-builder container (see Containerfile).
# Will also run on any host that has `lorax`, `xorriso`, `isomd5sum`, and
# `pykickstart` installed.
set -euo pipefail

: "${FEDORA_VER:=41}"
: "${FORGE_VERSION:=0.1.0}"
: "${ARCH:=x86_64}"
: "${OUTPUT_DIR:=/out}"
: "${WORK_DIR:=/tmp/forge-build}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_ISO="${OUTPUT_DIR}/forge-${FORGE_VERSION}-${ARCH}.iso"

command -v mkksiso >/dev/null || {
    echo "mkksiso not found. Install lorax (dnf install lorax) or use the Containerfile." >&2
    exit 2
}
command -v ksvalidator >/dev/null || {
    echo "ksvalidator not found. Install pykickstart." >&2
    exit 2
}

mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

# -----------------------------------------------------------------------------
# 1. Acquire the source ISO
# -----------------------------------------------------------------------------
if [ -n "${SOURCE_ISO:-}" ] && [ -f "$SOURCE_ISO" ]; then
    echo "==> Using local source ISO: $SOURCE_ISO"
else
    SOURCE_ISO="${WORK_DIR}/Fedora-Server-netinst-${FEDORA_VER}-${ARCH}.iso"
    # Netinst is ~800MB and grabs packages over the network at install time.
    # Swap to the DVD URL for an offline-capable ISO (much larger).
    URL="https://download.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_VER}/Server/${ARCH}/iso/Fedora-Server-netinst-${ARCH}-${FEDORA_VER}-1.4.iso"
    if [ ! -f "$SOURCE_ISO" ]; then
        echo "==> Downloading ${URL}"
        curl -fL --retry 4 --retry-delay 5 --progress-bar -o "$SOURCE_ISO" "$URL" || {
            # Exact point-release filenames change; fall back to the
            # floating-latest redirect path.
            FALLBACK="https://download.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_VER}/Server/${ARCH}/iso/"
            echo "==> Direct URL failed, listing $FALLBACK so you can pick a version manually." >&2
            exit 3
        }
    fi
fi

# -----------------------------------------------------------------------------
# 2. Validate the kickstart
# -----------------------------------------------------------------------------
echo "==> Validating kickstart"
ksvalidator -v "RHEL$(echo "$FEDORA_VER" | head -c1)" "${SCRIPT_DIR}/forge.ks" || \
    ksvalidator "${SCRIPT_DIR}/forge.ks"

# -----------------------------------------------------------------------------
# 3. Build the forge-* RPMs (branding) and the anaconda product.img
# -----------------------------------------------------------------------------
REPO_DIR="${SCRIPT_DIR}/../forge-packages/repo"
if [ ! -d "$REPO_DIR" ] || [ -z "$(find "$REPO_DIR" -maxdepth 1 -name '*.rpm' 2>/dev/null)" ]; then
    echo "==> Building forge-release, forge-logos, forge-backgrounds"
    (cd "${SCRIPT_DIR}/../forge-packages" && FORGE_VERSION="$FORGE_VERSION" ./build-rpms.sh)
else
    echo "==> Re-using existing forge-packages/repo/"
fi

echo "==> Building anaconda product.img (installer rebrand)"
FORGE_VERSION="$FORGE_VERSION" FEDORA_VER="$FEDORA_VER" \
    "${SCRIPT_DIR}/build-product-img.sh"

# -----------------------------------------------------------------------------
# 4. Stage the forge support tree — mkksiso's --add copies it to /forge/ on
#    the ISO, which the %post block pulls from /run/install/repo/forge.
# -----------------------------------------------------------------------------
STAGE_DIR="${WORK_DIR}/stage"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/forge"
cp -a "${SCRIPT_DIR}/post"       "$STAGE_DIR/forge/"
cp -a "${SCRIPT_DIR}/firstboot"  "$STAGE_DIR/forge/"
cp -a "${SCRIPT_DIR}/files"      "$STAGE_DIR/forge/"

# Bundle the freshly-built RPMs as an on-ISO repository that the kickstart
# %packages block consumes via `repo --name=forge --baseurl=hd:LABEL=FORGE:/forge/repo`.
cp -a "${REPO_DIR}" "$STAGE_DIR/forge/repo"

# Ensure scripts are executable after the ISO9660 copy.
find "$STAGE_DIR/forge" -name '*.sh' -exec chmod +x {} +

# Bake the version into the tree for /etc/forge/release.
cat > "$STAGE_DIR/forge/VERSION" <<EOF
FORGE_VERSION=${FORGE_VERSION}
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BUILT_ON=${HOSTNAME:-unknown}
EOF

# -----------------------------------------------------------------------------
# 5. Inject the product.img into the source ISO before mkksiso runs. xorriso
#    has the path precision we need; mkksiso's --add can't reliably drop a
#    file at /images/product.img across every lorax version.
# -----------------------------------------------------------------------------
INTERMEDIATE_ISO="${WORK_DIR}/intermediate.iso"
echo "==> Injecting anaconda product.img into source ISO"
xorriso -indev "$SOURCE_ISO" \
        -outdev "$INTERMEDIATE_ISO" \
        -boot_image any replay \
        -map "${SCRIPT_DIR}/product.img" /images/product.img \
        -compliance no_emul_toc

# -----------------------------------------------------------------------------
# 6. Build the final ISO
# -----------------------------------------------------------------------------
echo "==> Building ${OUT_ISO}"
# --ks        embed forge.ks as the auto-executed kickstart
# --add       drop the support tree + forge repo at /forge on the ISO
# --cmdline   append to the default bootloader entry so the installer picks
#             up the kickstart without operator interaction
mkksiso \
    --ks "${SCRIPT_DIR}/forge.ks" \
    --add "${STAGE_DIR}/forge" \
    --cmdline "inst.ks=hd:LABEL=FORGE:/forge.ks inst.stage2=hd:LABEL=FORGE quiet" \
    --volid FORGE \
    "$INTERMEDIATE_ISO" "$OUT_ISO"

rm -f "$INTERMEDIATE_ISO"

# -----------------------------------------------------------------------------
# 5. Re-implant the MD5 checksum (only needed on some legacy loaders)
# -----------------------------------------------------------------------------
if command -v implantisomd5 >/dev/null; then
    implantisomd5 "$OUT_ISO" >/dev/null || true
fi

echo
echo "==> Done: ${OUT_ISO}"
ls -lh "$OUT_ISO"
