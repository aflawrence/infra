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
# 3. Stage the forge support tree — mkksiso's --add copies it to /forge/ on
#    the ISO, which the %post block pulls from /run/install/repo/forge.
# -----------------------------------------------------------------------------
STAGE_DIR="${WORK_DIR}/stage"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/forge"
cp -a "${SCRIPT_DIR}/post"       "$STAGE_DIR/forge/"
cp -a "${SCRIPT_DIR}/firstboot"  "$STAGE_DIR/forge/"
cp -a "${SCRIPT_DIR}/files"      "$STAGE_DIR/forge/"
# Ensure scripts are executable after the ISO9660 copy.
find "$STAGE_DIR/forge" -name '*.sh' -exec chmod +x {} +

# Bake the version into the tree for /etc/forge/release.
cat > "$STAGE_DIR/forge/VERSION" <<EOF
FORGE_VERSION=${FORGE_VERSION}
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BUILT_ON=${HOSTNAME:-unknown}
EOF

# -----------------------------------------------------------------------------
# 4. Build the ISO
# -----------------------------------------------------------------------------
echo "==> Building ${OUT_ISO}"
# --ks           embed forge.ks as the auto-executed kickstart
# --add          drop the support tree at /forge on the resulting ISO
# --cmdline      append to the default bootloader entry so the installer picks
#                up the kickstart without operator interaction
mkksiso \
    --ks "${SCRIPT_DIR}/forge.ks" \
    --add "${STAGE_DIR}/forge" \
    --cmdline "inst.ks=hd:LABEL=FORGE:/forge.ks inst.stage2=hd:LABEL=FORGE quiet" \
    --volid FORGE \
    "$SOURCE_ISO" "$OUT_ISO"

# -----------------------------------------------------------------------------
# 5. Re-implant the MD5 checksum (only needed on some legacy loaders)
# -----------------------------------------------------------------------------
if command -v implantisomd5 >/dev/null; then
    implantisomd5 "$OUT_ISO" >/dev/null || true
fi

echo
echo "==> Done: ${OUT_ISO}"
ls -lh "$OUT_ISO"
