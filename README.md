# Corona PPC-21 Graphics

Research notes and small DOS programs for the proprietary monochrome
graphics mode in the Corona/Cordata PPC-21 portable PC.

The PPC-21 has an MDA-like text adapter, but Corona also exposed a
machine-specific graphics mode through its modified GW-BASIC as
`SCREEN 105`. The work in this repository documents that mode, provides
small test programs, and contains an early BIOS-level CGA compatibility TSR
that renders CGA-style INT 10h graphics calls into the PPC-21 framebuffer.

## Current Findings

- Corona `SCREEN 105` is 640 x 325, 1 bit per pixel.
- Graphics pages are 32 KiB apart in conventional RAM.
- Page segment formula: `page * 0800h`.
- The pixel byte layout is not linear:

```text
offset = ((y mod 13) << 11) + ((y / 13) * 80) + (x >> 3)
mask   = 01h << (x & 7)
```

- The visible page is selected through the MDA/6845-compatible CRTC start
  address registers.
- The display path wraps at `40000h`, consistent with the 6845/MDA 14-bit
  display-start address limit. In practice, the last fully usable 32 KiB
  graphics page starts at `3800:0000`.
- Mode setup observed from Corona GW-BASIC:

```asm
mov ax,0007h
int 10h
mov dx,03B8h
mov al,0A9h
out dx,al
```

Then select a graphics page with CRTC registers `0Ch` and `0Dh`.

See [CORONA_GRAPHICS_NOTES.md](CORONA_GRAPHICS_NOTES.md) for the full
reverse-engineering notes and source references.

## Repository Layout

- `basic/GWBASIC.EXE` - Corona's modified GW-BASIC used for `SCREEN 105`.
- `basic/ROLLING.BAS` - original tokenized BASIC demo that animates a ball
  by drawing into pages 4 through 7 and flipping between them.
- `src/CGA105.ASM` - resident BIOS-level CGA shim for the PPC-21.
- `bin/CGA105.COM` - built TSR.
- `debug-scripts/CGA105.SCR` - DOS DEBUG script form of `CGA105.COM`.
- `src/CGATEST.ASM` - BIOS-only smoke test for `CGA105.COM`.
- `bin/CGATEST.COM` - built CGA105 test program.
- `debug-scripts/CGATEST.SCR` - DOS DEBUG script form of `CGATEST.COM`.
- `src/CPROBE.ASM` - graphics page probe that scans candidate 32 KiB pages.
- `bin/CPROBE.COM` - built page probe.
- `debug-scripts/CPROBE.SCR` - DOS DEBUG script form of `CPROBE.COM`.

The temporary box tests, failed builds, and page-address experiments from
the reverse-engineering process are intentionally not part of the published
project.

## Program Notes

### CPROBE

`CPROBE.COM` prints the DOS memory block it found, asks for confirmation,
draws a page number into each candidate 32 KiB page, enters the Corona
graphics mode, and advances through candidate pages on keypress. `Esc`
returns to DOS.

This was used to confirm that displayable pages below `40000h` work and
that higher candidate addresses alias or fall out of the CRTC-visible range.

### CGA105

`CGA105.COM` is a first-pass TSR. It hooks INT 10h and INT 11h, reports a
CGA 80-column display to software that asks the BIOS, and implements a
subset of CGA BIOS graphics calls:

- mode 4 / 5: 320 x 200 CGA-style graphics dithered to monochrome
- mode 6: 640 x 200 monochrome graphics, vertically expanded by default
- AH=0Bh: palette/background state tracking
- AH=0Ch: write pixel
- AH=0Dh: read pixel
- AH=0Fh: get video state

Command line:

```dos
CGA105       install with vertical expansion for mode 6
CGA105 /N    install without vertical expansion
CGA105 /U    unload, if it is still the active INT 10h/INT 11h hook
```

This is API-level compatibility only. A pure 8088 TSR cannot trap direct
writes to `B800h` or direct CGA port I/O, so software that bypasses the BIOS
will need a different approach, such as memory-mapped hardware assistance.

### CGATEST

`CGATEST.COM` is a small BIOS-only test for `CGA105.COM`. It avoids direct
CGA memory and port access, so it exercises the TSR hooks rather than real
CGA hardware.

Run:

```dos
CGA105
CGATEST
```

## Building

The assembly sources are written as 8086 tiny-model `.COM` programs intended
for MASM/TASM-style assemblers:

```dos
TASM CGA105.ASM
TLINK /T CGA105.OBJ
```

The checked-in `.COM` files are the currently tested builds. The `.SCR`
files are DEBUG scripts for recreating the binaries on DOS systems that do
not have an assembler available.

## Preservation Note

`GWBASIC.EXE` and `ROLLING.BAS` are included for hardware research and
preservation context. Copyright remains with the original rights holders.
