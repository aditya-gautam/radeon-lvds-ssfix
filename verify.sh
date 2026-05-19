#!/usr/bin/env bash
#
# verify.sh — radeon-lvds-ssfix verifier
#
# Reports the state of the fix on the running system.  Read-only; never
# modifies anything.  Useful for confirming installation and diagnosing
# issues.
#
# Usage: ./verify.sh
#

set -uo pipefail

KERNEL_RELEASE="$(uname -r)"
SYS_MOD_DIR="/lib/modules/${KERNEL_RELEASE}/kernel/drivers/gpu/drm/radeon"
INSTALLED_KO="$SYS_MOD_DIR/radeon.ko.zst"
BACKUP_KO="$SYS_MOD_DIR/radeon.ko.zst.bak"

# ---- helpers ----
ok() { printf '  \033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m[WARN]\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31m[FAIL]\033[0m %s\n' "$*"; }
info() { printf '  \033[1;34m[INFO]\033[0m %s\n' "$*"; }
sect() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }

EXIT=0

sect "System info"
info "kernel release: $KERNEL_RELEASE"
if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    info "distro: ${PRETTY_NAME:-$ID}"
fi

sect "Hardware applicability"
if command -v lspci >/dev/null 2>&1; then
    GPU_LINE="$(lspci -d 1002: 2>/dev/null | grep -iE 'vga|display' | head -1 || true)"
    if [[ -n "$GPU_LINE" ]]; then
        info "GPU: $GPU_LINE"
        if echo "$GPU_LINE" | grep -qiE 'rv7|rv6|hd 3|hd 4|hd 5|hd 6|mobility'; then
            ok "RV6xx/RV7xx-era radeon GPU detected (fix is applicable)"
        else
            warn "GPU does not look like the target hardware for this fix"
        fi
    else
        warn "no AMD/ATI GPU detected via lspci"
    fi
else
    warn "lspci not available; cannot check GPU"
fi

sect "Module files"
if [[ -f "$INSTALLED_KO" ]]; then
    ok "installed module present: $INSTALLED_KO"
    info "  size: $(stat -c %s "$INSTALLED_KO" 2>/dev/null) bytes"
    if command -v md5sum >/dev/null 2>&1; then
        info "  md5:  $(md5sum "$INSTALLED_KO" | awk '{print $1}')"
    fi
else
    fail "installed module missing: $INSTALLED_KO"
    EXIT=1
fi

if [[ -f "$BACKUP_KO" ]]; then
    ok "backup module present: $BACKUP_KO"
    info "  size: $(stat -c %s "$BACKUP_KO" 2>/dev/null) bytes"
    if command -v md5sum >/dev/null 2>&1; then
        info "  md5:  $(md5sum "$BACKUP_KO" | awk '{print $1}')"
    fi
    if [[ -f "$INSTALLED_KO" ]]; then
        if cmp -s "$INSTALLED_KO" "$BACKUP_KO"; then
            warn "installed module is BYTE-IDENTICAL to backup"
            warn "this means the fix has NOT been applied (or was uninstalled)"
            EXIT=1
        else
            ok "installed module differs from backup (fix is in place)"
        fi
    fi
else
    warn "no backup module at $BACKUP_KO"
    warn "if install.sh has been run, this is unexpected"
    warn "if install.sh has not been run, this is normal"
fi

sect "Module identification"
if [[ -f "$INSTALLED_KO" ]] && command -v modinfo >/dev/null 2>&1; then
    VERMAGIC="$(sudo modinfo "$INSTALLED_KO" 2>/dev/null | awk '/^vermagic:/ {sub(/^vermagic:[ \t]+/, ""); print; exit}' || true)"
    if [[ -n "$VERMAGIC" ]]; then
        info "vermagic: $VERMAGIC"
        if echo "$VERMAGIC" | grep -q "^${KERNEL_RELEASE} "; then
            ok "vermagic matches running kernel"
        else
            fail "vermagic does NOT match running kernel ($KERNEL_RELEASE)"
            EXIT=1
        fi
    else
        warn "could not extract vermagic (modinfo needs sudo for compressed modules)"
    fi
fi

sect "Runtime behavior"
DMESG_LINES="$(sudo dmesg 2>/dev/null | grep -iE 'radeon.*PPLL|PPLL.*radeon|radeon-lvds-ssfix' || true)"
if [[ -n "$DMESG_LINES" ]]; then
    ok "found radeon PPLL log lines in dmesg:"
    echo "$DMESG_LINES" | sed 's/^/    /'
else
    info "no radeon PPLL log lines in dmesg"
    info "(this is expected if the patch is the silent 'production' version)"
fi

# Look for module load taint message
if sudo dmesg 2>/dev/null | grep -q 'radeon: loading out-of-tree module'; then
    ok "kernel reports radeon was loaded as an out-of-tree module"
fi

sect "Display state"
LVDS_DIR="$(ls -d /sys/class/drm/card*-LVDS-* 2>/dev/null | head -1 || true)"
if [[ -n "$LVDS_DIR" ]]; then
    LVDS_STATUS="$(cat "$LVDS_DIR/status" 2>/dev/null || echo unknown)"
    LVDS_ENABLED="$(cat "$LVDS_DIR/enabled" 2>/dev/null || echo unknown)"
    info "LVDS connector: $LVDS_DIR"
    info "  status: $LVDS_STATUS"
    info "  enabled: $LVDS_ENABLED"
    LVDS_MODE="$(head -1 "$LVDS_DIR/modes" 2>/dev/null || true)"
    if [[ -n "$LVDS_MODE" ]]; then
        info "  preferred mode: $LVDS_MODE"
    fi
else
    info "no LVDS connector visible in /sys/class/drm/"
    info "(this is normal on systems without LVDS, or before radeon driver loads)"
fi

sect "Summary"
if [[ $EXIT -eq 0 ]]; then
    ok "All checks passed"
else
    fail "Some checks failed (see above)"
fi

exit $EXIT
