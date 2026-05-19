#!/usr/bin/env bash
#
# install.sh — radeon-lvds-ssfix installer
#
# Builds a patched radeon kernel module that disables PPLL spread spectrum
# for LVDS panels.  Workaround for replacement-panel scenarios on RV6xx/RV7xx
# AMD GPUs (e.g., Dell Studio XPS 1645 with swapped LVDS panel).
#
# Usage: sudo ./install.sh [--force] [--keep-build]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_PY="${SCRIPT_DIR}/apply_patch.py"
KERNEL_RELEASE="$(uname -r)"
WORK_DIR="${WORK_DIR:-/tmp/radeon-lvds-ssfix-build}"
SYS_MOD_DIR="/lib/modules/${KERNEL_RELEASE}/kernel/drivers/gpu/drm/radeon"
RADEON_MOD_NAME="radeon.ko"
KEEP_BUILD=0
FORCE=0

# ---- helpers ----
log() { printf '\033[1;32m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

# ---- argument parsing ----
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --keep-build) KEEP_BUILD=1 ;;
        -h|--help)
            sed -n '3,9p' "$0"
            exit 0
            ;;
        *) die "unknown argument: $arg" ;;
    esac
done

# ---- preflight ----
if [[ $EUID -ne 0 ]]; then
    die "must be run as root (use sudo)"
fi

if [[ ! -x "$PATCH_PY" ]]; then
    die "apply_patch.py not found or not executable: $PATCH_PY"
fi

log "Kernel release: $KERNEL_RELEASE"
log "Module dir: $SYS_MOD_DIR"

if [[ ! -d "$SYS_MOD_DIR" ]]; then
    die "$SYS_MOD_DIR does not exist — is the radeon driver part of this kernel?"
fi

# Quick hardware applicability check
if [[ -r /sys/bus/pci/devices ]]; then
    if ! lspci -d 1002: 2>/dev/null | grep -qiE 'radeon|hd 4|rv7|rv6|hd 5|hd 6|hd 3'; then
        if [[ $FORCE -eq 0 ]]; then
            warn "No RV6xx/RV7xx-era radeon GPU detected via lspci."
            warn "This fix is intended for that hardware generation."
            warn "Run with --force to install anyway."
            exit 1
        else
            warn "No matching GPU detected, but --force was given.  Proceeding."
        fi
    fi
fi

# ---- distro detection ----
DISTRO="unknown"
if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    DISTRO="${ID:-unknown}"
fi
log "Distro: $DISTRO"

# ---- kernel source acquisition ----
get_kernel_source() {
    local target="$1"
    log "Acquiring kernel source for $KERNEL_RELEASE into $target"

    case "$DISTRO" in
        ubuntu|debian|linuxmint|pop)
            log "Using apt source linux..."
            mkdir -p "$target"
            cd "$target"
            if ! apt-get source --download-only "linux-image-unsigned-${KERNEL_RELEASE}" 2>/dev/null \
                && ! apt-get source --download-only "linux-image-${KERNEL_RELEASE}" 2>/dev/null \
                && ! apt-get source --download-only linux 2>/dev/null; then
                die "apt source linux failed.  Have you enabled deb-src in /etc/apt/sources.list*?"
            fi
            # Extract whatever .dsc / .tar / .diff was downloaded
            local dsc
            dsc="$(ls -1 ./*.dsc 2>/dev/null | head -1 || true)"
            if [[ -n "${dsc:-}" ]]; then
                dpkg-source -x "$dsc" >/dev/null
            fi
            ;;
        arch|cachyos|manjaro|endeavouros)
            log "Acquiring kernel source via Arch tooling..."
            warn "On Arch-family distros, kernel source acquisition is best done manually."
            warn "Please ensure linux-headers (or matching headers package) is installed."
            warn "Then re-run with KERNEL_SRC=/path/to/source ./install.sh"
            if [[ -z "${KERNEL_SRC:-}" ]]; then
                die "Set KERNEL_SRC environment variable to a kernel source tree containing drivers/gpu/drm/radeon/"
            fi
            ;;
        fedora|rhel|centos|rocky|almalinux)
            warn "Fedora/RHEL family — please install kernel-devel and matching kernel source manually."
            if [[ -z "${KERNEL_SRC:-}" ]]; then
                die "Set KERNEL_SRC environment variable to a kernel source tree containing drivers/gpu/drm/radeon/"
            fi
            ;;
        *)
            warn "Unknown distro ($DISTRO).  Please provide kernel source manually via KERNEL_SRC env var."
            if [[ -z "${KERNEL_SRC:-}" ]]; then
                die "Set KERNEL_SRC environment variable to a kernel source tree containing drivers/gpu/drm/radeon/"
            fi
            ;;
    esac
}

# Resolve the kernel source root
KERNEL_SRC_ROOT=""
if [[ -n "${KERNEL_SRC:-}" ]]; then
    KERNEL_SRC_ROOT="$KERNEL_SRC"
    log "Using user-supplied KERNEL_SRC: $KERNEL_SRC_ROOT"
else
    mkdir -p "$WORK_DIR"
    get_kernel_source "$WORK_DIR"
    # Find the extracted source tree (look for one containing drivers/gpu/drm/radeon)
    KERNEL_SRC_ROOT="$(find "$WORK_DIR" -maxdepth 2 -type d -name 'linux-*' 2>/dev/null | head -1)"
    if [[ -z "$KERNEL_SRC_ROOT" ]] || [[ ! -d "$KERNEL_SRC_ROOT/drivers/gpu/drm/radeon" ]]; then
        die "Could not locate a usable kernel source tree under $WORK_DIR"
    fi
    log "Found kernel source: $KERNEL_SRC_ROOT"
fi

if [[ ! -d "$KERNEL_SRC_ROOT/drivers/gpu/drm/radeon" ]]; then
    die "$KERNEL_SRC_ROOT does not contain drivers/gpu/drm/radeon/"
fi

# ---- prepare kernel source for module build ----
log "Preparing kernel source tree..."
cd "$KERNEL_SRC_ROOT"

# Copy the running kernel's config
if [[ ! -f .config ]]; then
    if [[ -f "/boot/config-${KERNEL_RELEASE}" ]]; then
        cp "/boot/config-${KERNEL_RELEASE}" .config
        log "Copied /boot/config-${KERNEL_RELEASE} -> .config"
    else
        die "no /boot/config-${KERNEL_RELEASE}; cannot proceed"
    fi
fi

# Make sure LOCALVERSION matches the running kernel.  Strip any '+' or hash that might
# be appended automatically.
RUNNING_LOCALVERSION="${KERNEL_RELEASE#*-}"
RUNNING_LOCALVERSION="-${RUNNING_LOCALVERSION}"

# Setting CONFIG_LOCALVERSION via .config is unreliable: Ubuntu (and some other
# distros) reset it during make olddefconfig.  Use the localversion-* file
# mechanism instead, which the kernel Makefile reads independently of .config
# and which olddefconfig leaves alone.
LOCALVERSION_FILE="localversion-radeon-lvds-ssfix"
echo "${RUNNING_LOCALVERSION}" > "${LOCALVERSION_FILE}"
log "Wrote ${LOCALVERSION_FILE} containing '${RUNNING_LOCALVERSION}'"
# Also disable AUTO if set (this one olddefconfig respects)
sed -i 's|^CONFIG_LOCALVERSION_AUTO=y|# CONFIG_LOCALVERSION_AUTO is not set|' .config

# Trap to clean up the localversion file on exit (success or failure)
trap 'rm -f "$KERNEL_SRC_ROOT/$LOCALVERSION_FILE"' EXIT

# Force regen of the version headers
rm -f include/generated/utsrelease.h include/generated/compile.h .version include/config/kernel.release

# Run olddefconfig and prepare
log "Running make olddefconfig..."
make olddefconfig >/dev/null 2>&1 || warn "olddefconfig had warnings (often ok)"

log "Running make prepare..."
make prepare >/dev/null 2>&1 || die "make prepare failed"

# Verify utsrelease.h
if [[ ! -f include/generated/utsrelease.h ]]; then
    die "include/generated/utsrelease.h not generated; cannot ensure vermagic match"
fi

UTS_GENERATED="$(grep -oP '"\K[^"]+' include/generated/utsrelease.h | head -1)"
log "utsrelease.h says: $UTS_GENERATED"
if [[ "$UTS_GENERATED" != "$KERNEL_RELEASE" ]]; then
    die "utsrelease mismatch: got '$UTS_GENERATED', expected '$KERNEL_RELEASE'"
fi

# ---- apply the patch ----
log "Applying radeon-lvds-ssfix patch..."
python3 "$PATCH_PY" "$KERNEL_SRC_ROOT" || die "patch failed"

# ---- build the module ----
# Copy Module.symvers from the running kernel so module symbol versions match
SYMVERS_SRC="/usr/src/linux-headers-${KERNEL_RELEASE}/Module.symvers"
if [[ ! -f "$SYMVERS_SRC" ]]; then
    SYMVERS_SRC="/lib/modules/${KERNEL_RELEASE}/build/Module.symvers"
fi
if [[ -f "$SYMVERS_SRC" ]]; then
    cp "$SYMVERS_SRC" Module.symvers
    log "Module.symvers copied from $SYMVERS_SRC"
else
    warn "Module.symvers not found in expected locations; module symbol versions may not match"
fi

log "Building radeon module (this takes a few minutes)..."
make M=drivers/gpu/drm/radeon clean >/dev/null
if ! make M=drivers/gpu/drm/radeon modules 2>&1 | tail -5; then
    die "module build failed"
fi

KO_PATH="$KERNEL_SRC_ROOT/drivers/gpu/drm/radeon/radeon.ko"
if [[ ! -f "$KO_PATH" ]]; then
    die "build completed but $KO_PATH not found"
fi

# Verify vermagic
BUILT_VERMAGIC="$(modinfo "$KO_PATH" 2>/dev/null | awk '/^vermagic:/ {sub(/^vermagic:[ \t]+/, ""); print; exit}')"
log "Built module vermagic: $BUILT_VERMAGIC"
if ! echo "$BUILT_VERMAGIC" | grep -q "^${KERNEL_RELEASE} "; then
    die "vermagic mismatch: built '$BUILT_VERMAGIC', need to start with '$KERNEL_RELEASE '"
fi

# ---- install ----
log "Installing module to $SYS_MOD_DIR ..."

# Backup original module if not already backed up
INSTALLED_KO="$SYS_MOD_DIR/radeon.ko.zst"
BACKUP_KO="$SYS_MOD_DIR/radeon.ko.zst.bak"

if [[ ! -f "$BACKUP_KO" ]]; then
    if [[ -f "$INSTALLED_KO" ]]; then
        cp "$INSTALLED_KO" "$BACKUP_KO"
        log "Original module backed up to $BACKUP_KO"
    else
        warn "$INSTALLED_KO not found; cannot back up"
    fi
fi

# Strip + compress
STRIPPED="${WORK_DIR}/radeon-stripped.ko"
COMPRESSED="${WORK_DIR}/radeon.ko.zst"
mkdir -p "$WORK_DIR"
objcopy --strip-debug "$KO_PATH" "$STRIPPED"
zstd -19 -f "$STRIPPED" -o "$COMPRESSED" >/dev/null

cp "$COMPRESSED" "$INSTALLED_KO"
log "Installed: $INSTALLED_KO"

# Update module dependencies + initramfs
log "Running depmod..."
depmod -a

log "Running update-initramfs / mkinitcpio..."
if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u 2>&1 | tail -3 || warn "update-initramfs reported issues"
elif command -v mkinitcpio >/dev/null 2>&1; then
    mkinitcpio -P 2>&1 | tail -3 || warn "mkinitcpio reported issues"
elif command -v dracut >/dev/null 2>&1; then
    dracut -f 2>&1 | tail -3 || warn "dracut reported issues"
else
    warn "no initramfs tool found; you may need to regenerate manually"
fi

# ---- cleanup ----
if [[ $KEEP_BUILD -eq 0 ]]; then
    log "Cleaning up build directory..."
    rm -rf "$WORK_DIR"
fi

# ---- summary ----
echo
log "==== Install complete ===="
echo
echo "  Patched module: $INSTALLED_KO"
echo "  Backup of original: $BACKUP_KO"
echo
echo "  To activate the fix: reboot."
echo "  To verify after reboot: dmesg | grep -i radeon"
echo "  To uninstall: sudo $SCRIPT_DIR/uninstall.sh"
echo
