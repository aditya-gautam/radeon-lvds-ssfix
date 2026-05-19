#!/usr/bin/env python3
"""
Apply the LVDS spread-spectrum fix to a kernel source tree's
drivers/gpu/drm/radeon/radeon_atombios.c file.

The fix: for LVDS panels (PPLL_SS_Info IDs < 0xF0), skip the spread-spectrum
lookup so the pixel clock is delivered without modulation. This works around
VBIOS PPLL_SS_Info entries tuned for an originally-shipped panel that are
incompatible with replacement panels (e.g., Dell Studio XPS 1645 with a
swapped LVDS panel of different make/model).

Usage:
    apply_patch.py <kernel-source-root>
    apply_patch.py --check      # only check, don't modify
    apply_patch.py --revert     # remove the patch

Exit codes:
    0  success / already applied (idempotent)
    1  patch could not be applied (anchor missing, etc.)
    2  bad usage / file not found
"""
import sys
import os
import argparse


REL_PATH = "drivers/gpu/drm/radeon/radeon_atombios.c"

PATCH_MARKER = "BEGIN: radeon-lvds-ssfix"

# The patch we inject at the top of radeon_atombios_get_ppll_ss_info function body.
# We anchor on the line that already exists in the function ("int i, num_indices;")
# and inject a block before the function's first memset.
ANCHOR_BEFORE = "\tint i, num_indices;\n\n\tmemset(ss, 0, sizeof(struct radeon_atom_ss));\n"

# IMPORTANT: this injection contains the PATCH_MARKER so we can detect/revert.
INJECTION = """\tint i, num_indices;

\t/* BEGIN: radeon-lvds-ssfix
\t * Panel-swap workaround: VBIOS PPLL_SS_Info entries with id < 0xF0 are
\t * LVDS-style (DP uses 0xF1+ per ATOM_DP_SS_ID*).  These were tuned for the
\t * originally-shipped panel and apply incompatible SSC modulation to
\t * replacement panels with different input PLL characteristics.
\t * Empirical testing on a Dell Studio XPS 1645 with a swapped LVDS panel
\t * confirmed that even reducing the percentage to 0.50% center spread does
\t * not help; the auxiliary modulation parameters are also panel-specific.
\t * Skip SS lookup for LVDS IDs entirely.  DP IDs (>= 0xF0) are GPU-specific
\t * and unaffected.
\t * https://github.com/aditya-gautam/radeon-lvds-ssfix
\t * END: radeon-lvds-ssfix
\t */
\tif (id < 0xF0)
\t\treturn false;

\tmemset(ss, 0, sizeof(struct radeon_atom_ss));
"""


def find_target_file(src_root):
    target = os.path.join(src_root, REL_PATH)
    if not os.path.isfile(target):
        sys.stderr.write(
            "ERROR: cannot find %s under %s\n"
            "Pass the kernel source root as the first argument.\n"
            % (REL_PATH, src_root)
        )
        return None
    return target


def is_already_applied(content):
    return PATCH_MARKER in content


def apply_patch(target):
    with open(target, "r") as f:
        content = f.read()

    if is_already_applied(content):
        print("Patch already applied. Nothing to do.")
        return 0

    if ANCHOR_BEFORE not in content:
        sys.stderr.write(
            "ERROR: patch anchor not found in source.\n"
            "The radeon_atombios.c structure may have changed.\n"
            "Expected to find this exact text:\n%r\n" % ANCHOR_BEFORE
        )
        return 1

    if content.count(ANCHOR_BEFORE) != 1:
        sys.stderr.write(
            "ERROR: patch anchor matches %d times (expected 1).  Refusing to apply.\n"
            % content.count(ANCHOR_BEFORE)
        )
        return 1

    new_content = content.replace(ANCHOR_BEFORE, INJECTION, 1)

    # Backup the original alongside the file (idempotent: don't overwrite existing .orig)
    orig_backup = target + ".orig"
    if not os.path.exists(orig_backup):
        with open(orig_backup, "w") as f:
            f.write(content)
        print("Backup saved: %s" % orig_backup)

    with open(target, "w") as f:
        f.write(new_content)

    print("Patch applied to %s" % target)
    return 0


def check_patch(target):
    with open(target, "r") as f:
        content = f.read()
    if is_already_applied(content):
        print("APPLIED: %s contains the radeon-lvds-ssfix patch." % target)
        return 0
    else:
        print("NOT APPLIED: %s does not contain the radeon-lvds-ssfix patch." % target)
        return 1


def revert_patch(target):
    with open(target, "r") as f:
        content = f.read()

    if not is_already_applied(content):
        print("Patch not present in %s. Nothing to revert." % target)
        return 0

    if INJECTION not in content:
        sys.stderr.write(
            "ERROR: patch marker present but injection block not found verbatim.\n"
            "Manual review needed; try restoring from .orig backup.\n"
        )
        return 1

    new_content = content.replace(INJECTION, ANCHOR_BEFORE, 1)
    with open(target, "w") as f:
        f.write(new_content)
    print("Patch reverted from %s" % target)
    return 0


def main():
    parser = argparse.ArgumentParser(
        description="Apply, check, or revert the radeon-lvds-ssfix patch."
    )
    parser.add_argument("source_root", help="Path to kernel source root")
    g = parser.add_mutually_exclusive_group()
    g.add_argument("--check", action="store_true", help="check only, do not modify")
    g.add_argument("--revert", action="store_true", help="revert the patch")
    args = parser.parse_args()

    target = find_target_file(args.source_root)
    if target is None:
        return 2

    if args.check:
        return check_patch(target)
    if args.revert:
        return revert_patch(target)
    return apply_patch(target)


if __name__ == "__main__":
    sys.exit(main())
