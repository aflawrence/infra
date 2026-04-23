#!/bin/bash
# pre-flight.sh — verify the build environment before kicking off a real
# build. Runs fast (~5 seconds), doesn't mutate anything, prints a checklist.
#
# Use cases:
#   • "does my laptop have everything to build a forge ISO?"
#   • "does the builder container have everything?" (run it inside)
#   • first step of CI
set -uo pipefail

PASS=0
WARN=0
FAIL=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; WARN=$((WARN+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

need()       { command -v "$1" >/dev/null && ok "$1 ($(command -v "$1"))"   || bad "missing: $1 (install $2)"; }
nice_to_have() { command -v "$1" >/dev/null && ok "$1"                        || warn "optional: $1 (install $2 if $3)"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# -----------------------------------------------------------------------------
section "Build tooling (required for ISO)"
# -----------------------------------------------------------------------------
need mkksiso       "dnf install lorax"
need ksvalidator   "dnf install pykickstart"
need xorriso       "dnf install xorriso"
need curl          "dnf install curl"
nice_to_have implantisomd5 "isomd5sum" "you want md5 checksums on the ISO"

# -----------------------------------------------------------------------------
section "RPM builder (required for forge-* packages)"
# -----------------------------------------------------------------------------
need rpmbuild      "dnf install rpm-build"
need createrepo_c  "dnf install createrepo_c"
need rsvg-convert  "dnf install librsvg2-tools"
need convert       "dnf install ImageMagick"
need cpio          "dnf install cpio"

# -----------------------------------------------------------------------------
section "QEMU smoke test (optional but highly recommended)"
# -----------------------------------------------------------------------------
nice_to_have qemu-system-x86_64 "qemu / qemu-kvm" "you want VM smoke tests before hardware"
nice_to_have qemu-img           "qemu-img" "you want VM smoke tests"

if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ok "/dev/kvm writable — nested virt works"
else
    warn "/dev/kvm not accessible — smoke tests will run under TCG (slow)"
fi

# OVMF firmware — smoke test needs it for UEFI boot
OVMF_FOUND=""
for p in \
    /usr/share/edk2/ovmf/OVMF_CODE.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/ovmf/OVMF.fd
do
    [ -f "$p" ] && OVMF_FOUND="$p" && break
done
[ -n "$OVMF_FOUND" ] && ok "OVMF at $OVMF_FOUND" || warn "no OVMF firmware (smoke test will fail — install edk2-ovmf)"

# -----------------------------------------------------------------------------
section "Source tree sanity"
# -----------------------------------------------------------------------------
for f in \
    "$SCRIPT_DIR/forge.ks" \
    "$SCRIPT_DIR/build.sh" \
    "$SCRIPT_DIR/build-product-img.sh" \
    "$REPO_ROOT/forge-packages/build-rpms.sh"
do
    [ -f "$f" ] && ok "$(basename "$f") present" || bad "missing: $f"
done

for spec in "$REPO_ROOT"/forge-packages/*/*.spec; do
    if [ -f "$spec" ]; then
        if rpm -q --specfile "$spec" >/dev/null 2>&1; then
            ok "$(basename "$spec") — parses"
        else
            bad "$(basename "$spec") — rpm cannot parse this spec"
        fi
    fi
done

if command -v ksvalidator >/dev/null; then
    if ksvalidator "$SCRIPT_DIR/forge.ks" 2>/dev/null; then
        ok "forge.ks — ksvalidator clean"
    else
        warn "forge.ks — ksvalidator reports issues (may be false positives on HD-label syntax)"
    fi
fi

# -----------------------------------------------------------------------------
section "Disk space + network"
# -----------------------------------------------------------------------------
FREE_MB="$(df -Pm "$REPO_ROOT" | awk 'NR==2 {print $4}')"
if [ "$FREE_MB" -gt 8192 ]; then
    ok "${FREE_MB} MB free (need ~4G for ISO build, ~2G for smoke-test disks)"
else
    warn "${FREE_MB} MB free — builds may fail near ~4G used"
fi

if curl -fsSI https://dl.fedoraproject.org >/dev/null 2>&1; then
    ok "fedoraproject.org reachable"
else
    warn "fedoraproject.org NOT reachable — build.sh can't download the source ISO; set SOURCE_ISO=/path/to/local.iso"
fi

# -----------------------------------------------------------------------------
section "Summary"
# -----------------------------------------------------------------------------
printf '  passed: %d  warnings: %d  failed: %d\n' "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ] || { echo; echo "resolve the failures above before running build.sh" >&2; exit 1; }
echo
echo "Ready to build:"
echo "   cd $REPO_ROOT && ./forge-iso/build.sh"
