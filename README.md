# radeon-lvds-ssfix

A Linux kernel module patch for the legacy `radeon` driver that disables
spread spectrum clocking on LVDS panels.  Workaround for laptops where the
LVDS panel has been replaced with a different make/model than the one
originally shipped, on AMD/ATI GPUs that use the `radeon` driver
(roughly RV6xx/RV7xx generation, AMD HD 2000–HD 4000 series).

## The problem

Many laptops with this generation of AMD GPU have VBIOS spread spectrum
parameters tuned for the originally-shipped LVDS panel.  Those parameters
include the SSC modulation percentage, modulation rate, step size, and
range, and they are panel-specific.

If the panel is replaced (warranty service with a different part, screen
swap from a parts machine, repair using a compatible-but-different panel),
the new panel's input PLL may not be able to track the modulation
parameters from the original panel's VBIOS entry.  The result is visible
display corruption — typically structurally-coherent (text outlines and
window edges are recognisable) but with overlaid noise patterns.

This was originally identified on a Dell Studio XPS 1645 (RV730 Mobility
Radeon HD 4670) with the original 1920×1080 panel replaced by a 1366×768
Samsung LTN156AT02P01.  The original panel's VBIOS entry specified 1.4%
center-spread modulation; empirical testing showed that values as low as
0.5% still produced corruption, indicating the auxiliary modulation
parameters (step, delay, range) are also panel-specific and not
compatible.  Disabling spread spectrum entirely fixed the corruption.

## What this fix does

Modifies one function in `drivers/gpu/drm/radeon/radeon_atombios.c`:

```c
bool radeon_atombios_get_ppll_ss_info(struct radeon_device *rdev,
                                      struct radeon_atom_ss *ss,
                                      int id)
{
    /* ... */
    if (id < 0xF0)
        return false;
    /* ... original lookup follows ... */
}
```

LVDS PPLL SS entries use IDs below `0xF0` (typically `0x01` or `0x02`).
DisplayPort uses IDs `0xF1` and `0xF2` per `ATOM_DP_SS_ID*`.  This fix
skips the lookup only for LVDS, leaving DisplayPort SS handling
untouched.

The pixel clock is then delivered to the panel as a clean unmodulated
signal.  The only practical drawback is slightly higher peak EMI emission
at the pixel clock frequency — irrelevant for an already-shipped consumer
laptop.

## Affected hardware

- AMD/ATI GPUs using the `radeon` kernel driver
- RV6xx, RV7xx, Evergreen, Northern Islands generations approximately
- Laptops where the LVDS panel has been replaced with a different model
- Most likely: warranty replacement, parts machine swap, post-damage
  repair with a compatible-but-different panel

The fix is harmless on hardware that doesn't have this issue: if the
VBIOS SS parameters are correct for the panel, disabling SS is just a
slight EMI compliance regression with no visible effect.

If you're using the `amdgpu` driver instead of `radeon`, this fix does
not apply.  `amdgpu` was extended to cover GPUs from approximately the
SI generation forward; `radeon` covers everything older.

## Installation

### Prerequisites

- Linux distribution with the `radeon` kernel driver
- Build tools: `gcc`, `make`, `python3`, `objcopy`, `zstd`
- Kernel headers and source for your running kernel
- Root access

### Quick install

```bash
git clone https://github.com/aditya-gautam/radeon-lvds-ssfix
cd radeon-lvds-ssfix
sudo ./install.sh
sudo reboot
```

After reboot, your LVDS display should be clean.

### Distro-specific notes

**Ubuntu / Debian / Mint / Pop!_OS:**

Ensure source repositories are enabled, then `install.sh` will
automatically fetch the kernel source via `apt source linux`.  If it
fails complaining about missing deb-src, add it to your sources:

```bash
# Ubuntu 26.04 example (deb822 format)
sudo sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
sudo apt update
```

**Arch / CachyOS / Manjaro:**

Install kernel source manually, then point the script at it:

```bash
# example for Arch
sudo pacman -S linux-headers
# obtain matching kernel source via ABS or AUR; let's call it /tmp/linux-src
sudo KERNEL_SRC=/tmp/linux-src ./install.sh
```

**Fedora / RHEL / Rocky:**

```bash
sudo dnf install kernel-devel kernel-headers
# obtain matching kernel source; let's call it /tmp/linux-src
sudo KERNEL_SRC=/tmp/linux-src ./install.sh
```

**Generic / unknown distro:**

Make sure you have the kernel source somewhere with
`drivers/gpu/drm/radeon/` accessible, then:

```bash
sudo KERNEL_SRC=/path/to/kernel/source ./install.sh
```

## Verification

After installation and reboot, run:

```bash
./verify.sh
```

It will report on hardware, installed module, vermagic match, runtime
behavior, and display state.

## Uninstall

```bash
sudo ./uninstall.sh
sudo reboot
```

This restores the original `radeon.ko.zst` from the backup created during
install.  After reboot, you'll be back on the unmodified driver — the
LVDS corruption will return.

If you want to keep the backup file around (in case you reinstall later
or want to compare):

```bash
sudo ./uninstall.sh --keep-bak
```

## Persistence across kernel updates

This fix is **not** persistent across kernel package updates.  When your
distro installs a new kernel (e.g., `linux-image-7.0.0-16-generic`),
that kernel ships its own unmodified `radeon.ko.zst`.  You'll need to
re-run `install.sh` after the new kernel is installed and you've booted
into it.

A future enhancement could package this as DKMS for fully automatic
rebuild on kernel updates.

## Files

- `apply_patch.py` — applies the source-code patch (used by install.sh)
- `install.sh`     — main install entry point
- `uninstall.sh`   — restores original module
- `verify.sh`      — read-only state inspector
- `README.md`      — this file
- `LICENSE`        — GPL-2.0

## How the bug was found

The full diagnostic journey is summarised in
[`docs/diagnosis.md`](docs/diagnosis.md) (if present).  Short version:
the symptom looked like a graphics driver bug, but turned out to be
hardcoded VBIOS data tuned for the originally-shipped panel that was
incompatible with the replacement.  Walking through the kernel modeset
code path (CRTC programming → encoder dpms → UNIPHY transmitter setup →
PPLL programming → `EnableSpreadSpectrumOnPPLL` firmware call) and
correlating each parameter against EDID-declared values eventually
isolated the SSC parameters as the cause.

## Author

Aditya Gautam

## License

GPL-2.0.  See `LICENSE`.

This project modifies a Linux kernel module which is itself GPL-2.0,
and the modified module continues to be subject to GPL-2.0 terms.
