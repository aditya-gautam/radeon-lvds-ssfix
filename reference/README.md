# Reference files for manual patching

This directory contains the source file we patch, in three forms:

- **`radeon_atombios.c.pristine`** \u2014 the unmodified original from the
  kernel source tree (Linux 7.0.0).  Use this as a reference for what the
  source looks like before any modification.
- **`radeon_atombios.c.patched`** \u2014 the same file after the
  radeon-lvds-ssfix patch is applied.  This is what `apply_patch.py`
  produces.
- **`radeon_atombios.c.patch`** \u2014 a unified diff between the two.  This
  is the canonical "what does the patch actually change" reference.

## When to use these

Normally you don't need to touch these files.  The `install.sh` script
uses `apply_patch.py` to apply the patch automatically.

You may need them if:

- The kernel source structure has changed enough that `apply_patch.py`'s
  text-based anchor no longer matches.
- You are manually patching a different kernel version.
- You want to inspect or audit exactly what the patch changes.
- A package maintainer wants to integrate the patch into their build
  system (this format is much more familiar than the Python approach).

## Manual patch application

If `apply_patch.py` fails, you can apply the change by hand:

1. Open the kernel source's `drivers/gpu/drm/radeon/radeon_atombios.c`.
2. Find the function `radeon_atombios_get_ppll_ss_info`.
3. Right after the variable declarations and before the
   `memset(ss, 0, ...)` line, insert:

```c
   /* radeon-lvds-ssfix: skip SS lookup for LVDS panels */
   if (id < 0xF0)
       return false;
```
4. Save and rebuild the radeon module.
Alternatively, use the unified diff with `patch(1)`:

```bash
cd /path/to/kernel/source
patch -p1 < /path/to/radeon-lvds-ssfix/reference/radeon_atombios.c.patch
```
(Note: the patch is generated against the kernel 7.0.0 file paths. You may need patch -p2 or to adjust the diff headers to match your tree.)
 EOF

echo "Wrote: $REF_DIR/README.md"
echo
echo "Reference files generated:" ls -la "$REF_DIR/"
