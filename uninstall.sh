#!/usr/bin/env bash
#
# uninstall.sh — radeon-lvds-ssfix uninstaller
#
# Restores the original radeon kernel module from the .bak backup created
# by install.sh.  Reverses the install.sh actions.
#
# Usage: sudo ./uninstall.sh [--keep-bak]
#

set -euo pipefail

KERNEL_RELEASE="$(uname -r)"
SYS_MOD_DIR="/lib/modules/${KERNEL_RELEASE}/kernel/drivers/gpu/drm/radeon"
INSTALLED_KO="$SYS_MOD_DIR/radeon.ko.zst"
BACKUP_KO="$SYS_MOD_DIR/radeon.ko.zst.bak"
KEEP_BAK=0

# ---- helpers ----
log() { printf '\033[1;32m[uninstall]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

# ---- argument parsing ----
for arg in "$@"; do
    case "$arg" in
        --keep-bak) KEEP_BAK=1 ;;
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

if [[ ! -d "$SYS_MOD_DIR" ]]; then
    die "$SYS_MOD_DIR does not exist"
fi

if [[ ! -f "$BACKUP_KO" ]]; then
    err "backup file not found: $BACKUP_KO"
    err "Either install.sh was never run, or the backup was already removed."
    err "If you have another backup, you can manually restore it as $INSTALLED_KO."
    exit 1
fi

# ---- summary of action ----
log "Kernel release: $KERNEL_RELEASE"
log "Will restore:   $BACKUP_KO -> $INSTALLED_KO"

# Compute md5s for visibility
if command -v md5sum >/dev/null 2>&1; then
    if [[ -f "$INSTALLED_KO" ]]; then
        log "Current installed md5: $(md5sum "$INSTALLED_KO" | awk '{print $1}')"
    fi
    log "Backup md5:            $(md5sum "$BACKUP_KO" | awk '{print $1}')"
fi

# ---- restore ----
log "Restoring original module from backup..."
cp "$BACKUP_KO" "$INSTALLED_KO"

if [[ $KEEP_BAK -eq 0 ]]; then
    log "Removing backup file (use --keep-bak to keep it)..."
    rm -f "$BACKUP_KO"
else
    log "Keeping backup file at $BACKUP_KO"
fi

# ---- regenerate dependencies and initramfs ----
log "Running depmod..."
depmod -a

log "Regenerating initramfs..."
if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u 2>&1 | tail -3 || warn "update-initramfs reported issues"
elif command -v mkinitcpio >/dev/null 2>&1; then
    mkinitcpio -P 2>&1 | tail -3 || warn "mkinitcpio reported issues"
elif command -v dracut >/dev/null 2>&1; then
    dracut -f 2>&1 | tail -3 || warn "dracut reported issues"
else
    warn "no initramfs tool found; you may need to regenerate manually"
fi

# ---- summary ----
echo
log "==== Uninstall complete ===="
echo
echo "  Original module restored to: $INSTALLED_KO"
echo "  Reboot to load the original (unpatched) module."
echo
echo "  Note: with the original radeon driver active, the LVDS panel"
echo "  corruption issue this fix addressed will return on next boot."
echo
