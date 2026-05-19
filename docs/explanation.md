# Explanation — in layman's terms and in technical detail

This document explains what the bug is and why this fix works, at two
levels.  Read the layman section if you just want to understand what's
happening; read the technical section if you want the full picture.

## Layman's explanation

### What's a graphics card "VBIOS"?

When a computer powers on, before the operating system loads, a tiny
program built into the graphics card runs first.  This program has a
configuration table that describes the laptop's screen — its size,
refresh rate, color depth, and many subtle electrical parameters that
determine how the screen and graphics card communicate.

Think of it like a recipe card that came with your laptop: "this exact
screen needs these exact settings to display a picture correctly."

### What's the problem with replacing the screen?

When you replace a laptop screen with a different model (after damage,
or finding a cheaper part), the recipe card is still the original.  It's
optimized for the screen that came with the laptop, not the new one.

Most settings on the card are generic enough that any screen of similar
size and resolution will accept them.  But some settings are very
specific to the original screen, and the new screen may not understand
them.  When that happens, the screen displays garbled or noisy patterns
instead of a clear picture.

### What setting specifically is the problem?

There's a setting called **spread spectrum clocking**.  It's an
electrical trick where the graphics card varies the timing signal
slightly back and forth.  This is required by FCC/regulatory rules
(prevents the laptop from acting like a tiny radio interfering with
nearby electronics) but the screen has to be designed to tolerate this
variation.

Different screens tolerate this variation in different amounts.  A
screen that's tolerant of large variation will work fine with most
graphics cards.  A screen that's only tolerant of small variation will
fail when the graphics card tries to vary the signal too much.

The original screen in this laptop was tolerant of 1.4% variation.  The
replacement screen wasn't.  That's the entire bug.

### What does this fix do?

It tells the graphics card "stop varying the signal at all when talking
to the laptop screen."  Instead of varying it by 1.4%, the signal stays
rock-steady.  The replacement screen can lock onto a steady signal
without trouble.

### Are there any downsides?

Theoretically, the laptop now emits slightly more electromagnetic
interference at one specific frequency.  In practice, for a 16-year-old
consumer laptop sitting on a desk, this is meaningless — you're not
running a radio next to it, and even if you were, the difference is
imperceptible.

The original purpose of spread spectrum was to help laptop manufacturers
pass regulatory tests during production.  Once the laptop has shipped
and is being used at home, it provides no real benefit.

### Why didn't Linux just figure this out automatically?

The Linux driver for this generation of graphics card (`radeon`) trusts
what the graphics card's recipe card says.  When the card says "use
1.4% variation", the driver does so.  It has no way of knowing the
screen has been replaced and that the recipe card is now wrong.

Newer drivers and operating systems have more flexibility here.  But
the old `radeon` driver is in maintenance mode — nobody is adding new
features to it.  So the fix takes the form of a small patch that says
"for laptop screens specifically, ignore the recipe card's variation
setting and just use no variation."

## Technical explanation

### Hardware context

The affected hardware is the AMD/ATI Radeon family of mobile GPUs from
roughly 2008-2012, specifically those still using the legacy `radeon`
kernel driver (RV6xx, RV7xx, Evergreen, Northern Islands).  These GPUs
include `INTERNAL_UNIPHY` digital transmitters with a configurable PLL
(`PPLL`, "pixel PLL") that drives the pixel clock for digital outputs
including LVDS.

For LVDS specifically, the GPU programs the panel's input clock with
spread spectrum modulation as defined in the VBIOS `PPLL_SS_Info` data
table (also known as `SS_Info` in older ATOMBIOS revisions).

### The relevant data structures

The VBIOS `PPLL_SS_Info` table contains an array of
`ATOM_SPREAD_SPECTRUM_ASSIGNMENT` entries:

```c
typedef struct _ATOM_SPREAD_SPECTRUM_ASSIGNMENT {
    USHORT  usSpreadSpectrumPercentage;  // in 0.01% units
    UCHAR   ucSpreadSpectrumType;        // bit 0: 0=down, 1=center
    UCHAR   ucSS_Step;                   // modulation step size
    UCHAR   ucSS_Delay;                  // modulation period
    UCHAR   ucSS_Id;                     // matched against caller's id
    UCHAR   ucRecommendedRef_Div;        // PLL reference divisor
    UCHAR   ucSS_Range;                  // modulation depth range
} ATOM_SPREAD_SPECTRUM_ASSIGNMENT;
```

The kernel driver function `radeon_atombios_get_ppll_ss_info()` walks
this array, matching `ucSS_Id` against a caller-supplied `id`.

For LVDS, the `id` comes from `ucSS_Id` in the `LVDS_Info` table (which
is populated when the driver parses VBIOS LCD panel info).  This is
typically `0x01` or `0x02`.

For DisplayPort, the `id` is one of the `ATOM_DP_SS_ID*` constants:

```c
#define ATOM_DP_SS_ID1  0xF1
#define ATOM_DP_SS_ID2  0xF2
```

The convention `id < 0xF0` reliably distinguishes LVDS from DP entries.

### The corruption mechanism

When SSC is enabled, the GPU's PPLL outputs a clock signal whose
frequency varies sinusoidally around the nominal pixel clock.  The
amplitude is the SSC percentage (e.g., ±0.7% for 1.4% center spread)
and the modulation rate is determined by `ucSS_Step` and `ucSS_Delay`.

The receiving panel has its own input PLL that recovers the pixel clock
from the LVDS data signal.  This recovery PLL must lock onto the
modulated clock and track its variations within its loop bandwidth.

If the modulation amplitude exceeds the panel's loop bandwidth or step
size, the recovery PLL fails to lock cleanly.  The result is sync
detection that's mostly correct (HSync and VSync edges are detected at
roughly the right times) but pixel-level data that is not aligned with
the panel's pixel clock domain.  The visible effect: structurally-coherent
content (text and window edges visible) with chromatic noise overlay.

### Why the auxiliary parameters matter too

In addition to the percentage, `ucSS_Step` (modulation step size) and
`ucRecommendedRef_Div` (PLL reference divisor used during SSC
programming) influence the actual modulation rate and depth.  These were
chosen for the original panel's input PLL bandwidth.

A replacement panel may have different PLL bandwidth, in which case
even reducing the percentage alone (while keeping the original step,
delay, range) does not produce a tolerable signal.  Empirical testing
on the reference machine showed corruption at 1.40%, 1.00%, and 0.50%
with the original auxiliary parameters — the panel could only handle
0% (no modulation).

In principle, finding the right combination of all four parameters
might let the panel tolerate some SSC.  In practice, this is a
multi-parameter empirical search with no closed-form solution per
panel, and there's no functional benefit to having SSC enabled on an
already-shipped consumer laptop.  Disabling SSC is correct.

### Why this lives in `radeon_atombios_get_ppll_ss_info`

The driver invokes this function to populate `radeon_crtc->ss` and set
`radeon_crtc->ss_enabled`.  When the function returns `false`, the
caller treats SSC as disabled, skips amount/step computation, and the
firmware command (`EnableSpreadSpectrumOnPPLL`) is invoked with
`ATOM_DISABLE` only.  No SSC modulation is programmed.

The function is called once per modeset on the LVDS path.  Skipping
LVDS lookups (id < 0xF0) does not affect DP, HDMI, or DVI paths, which
remain unchanged.

### Why not patch the VBIOS directly?

VBIOS modification is technically possible but has substantial
drawbacks:

- VBIOS reflashing risks bricking the GPU if it fails partway through.
- Many laptop VBIOSes are signed and refuse modified images.
- The change wouldn't survive a BIOS update.
- The change would need to be redone for each different laptop model.

A driver patch is reversible, distribution-portable, and survives
BIOS updates.

### Why not amdgpu?

The `amdgpu` driver was extended backwards to cover newer GPUs but
never extended back to the RV6xx/RV7xx generation.  Those GPUs remain
on `radeon`, which is in maintenance mode — critical bugs get fixed,
but no new features are added.  This is unlikely to change.

A "proper" upstream fix to `radeon` would expose a module parameter or
a per-connector property allowing SS to be disabled at runtime.  The
patch in this repository is simpler: it unconditionally disables SS for
LVDS connectors, on the principle that the few percent of users who
*might* benefit from LVDS SS being enabled don't outweigh the broken
displays of users who don't.
