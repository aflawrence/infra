#!/bin/bash
# build-rpms.sh — compile forge-release, forge-logos, forge-backgrounds into
# a local dnf repository under ./repo/, which forge-iso/build.sh then
# embeds in the ISO as /forge/repo.
#
# Designed to run inside the forge-iso-builder container (which already has
# rpmbuild, rsvg-convert, and ImageMagick) OR on any Fedora host.
#
# Usage:
#   cd forge-packages && ./build-rpms.sh
#   OUTPUT_REPO=/some/path ./build-rpms.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
: "${OUTPUT_REPO:=${SCRIPT_DIR}/repo}"
: "${FORGE_VERSION:=0.1.0}"
: "${ARCH:=noarch}"

need() {
    command -v "$1" >/dev/null || {
        echo "missing dependency: $1" >&2
        exit 2
    }
}
need rpmbuild
need rsvg-convert
need convert          # ImageMagick
need createrepo_c

# Use a scratch tree so rpmbuild doesn't scribble into $HOME on shared
# builders. BUILDROOT/RPMS/SRPMS/SOURCES/SPECS — standard layout.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
for d in BUILD BUILDROOT RPMS SRPMS SOURCES SPECS; do
    mkdir -p "$WORK/$d"
done

PACKAGES=(forge-release forge-logos forge-backgrounds forge-cockpit-ui)

# forge-cockpit-ui rasterizes logos from forge-logos' SVG. Stage it into
# SOURCES up front so the spec can reference it unconditionally.
cp -a "${SCRIPT_DIR}/forge-logos/assets/forge-logo.svg" "${WORK}/SOURCES/"

for pkg in "${PACKAGES[@]}"; do
    echo "==> building ${pkg}"
    src_dir="${SCRIPT_DIR}/${pkg}"
    spec="${src_dir}/${pkg}.spec"

    # Copy every source file listed in the spec into rpmbuild's SOURCES dir.
    # We use a shallow heuristic: any non-.spec file in the package dir or
    # under its assets/ subtree becomes a candidate source.
    find "${src_dir}" -type f ! -name '*.spec' -print0 |
        while IFS= read -r -d '' f; do
            rel="${f#${src_dir}/}"
            dest="$WORK/SOURCES/$(basename "$rel")"
            # Preserve subpath components that the spec references (e.g.
            # plymouth/forge.plymouth — SourceN: plymouth/forge.plymouth).
            case "$rel" in
                */*)
                    mkdir -p "$WORK/SOURCES/$(dirname "$rel")"
                    cp -a "$f" "$WORK/SOURCES/$rel"
                    ;;
                *)
                    cp -a "$f" "$dest"
                    ;;
            esac
        done

    rpmbuild \
        --define "_topdir ${WORK}" \
        --define "forge_version ${FORGE_VERSION}" \
        --define "dist .fc$(rpm --eval %fedora)" \
        -bb "${spec}"
done

# Move the built RPMs into the output repo + build repodata.
mkdir -p "${OUTPUT_REPO}"
find "${WORK}/RPMS" -name '*.rpm' -print -exec cp {} "${OUTPUT_REPO}/" \;
createrepo_c --update "${OUTPUT_REPO}"

echo
echo "==> Done. Repo at: ${OUTPUT_REPO}"
ls -lh "${OUTPUT_REPO}"/*.rpm
