# Corona PPC-21 GW-BASIC SCREEN 105 Notes

Target hardware: Corona/Cordata PPC-21 portable PC. Do not confuse this
machine with the later PPC-400/PC-400 family; the PPC-400 has different
400-scanline display hardware and IBM CGA-emulation claims that do not
appear to apply to this PPC-21.

Current confirmed working test: `CBOX.COM` switches to the PPC-21 graphics
mode, clears page 7 at `3800:0000`, and draws an aligned box using the
pixel layout and mode-switch values described below.

`ROLLING.BAS` is a tokenized GW-BASIC demo. The relevant setup is:

```basic
90 CLEAR ,10000
100 SCREEN 105
180 FOR P=0 TO 3
190 SCREEN ,,P+4,P+4
200 GOSUB 270
...
220 P=4
230 SCREEN ,,P,P
240 FOR N=1 TO 40: NEXT
250 P=P+1
260 IF P<8 THEN 230 ELSE 220
```

So the demo draws four frames into graphics pages 4 through 7, then flips
the visible page through 4, 5, 6, and 7.

## Mode

Corona's modified `GWBASIC.EXE` adds mode `SCREEN 105`. For the MDA-like
Corona graphics path used by this machine, the mode appears to be:

- width: 640 pixels, x range 0..639
- height: 325 pixels, y range 0..324
- depth: 1 bit per pixel
- page stride: 32 KiB

The bundled `GWBASIC.EXE` contains both 640 x 325-ish table entries
(`xmax=639`, `ymax=324`) and 640 x 400-ish table entries (`xmax=639`,
`ymax=399`). The entries that match this machine's observed MDA-like port
behavior are the 640 x 325 entries. The Ultimate Oldschool PC Font Pack
documentation also describes the PPC-21 as 640 x 325 monochrome graphics,
with 16x13 text cells. The 400-line entries likely belong to another
Corona/Cordata hardware path or to the later PPC-400 / PC-400 family.
Reference: https://www.alica.idv.tw/font/docs/font_list.pdf

A Corona "Super Resolution" GW-BASIC introduction hosted by the Computer
History Museum archive confirms the important BASIC-level details. It shows
the coordinate range as `(0,0)` to `(639,324)`, uses `SCREEN 105`, describes
the 128K setup as page/memory area `3` at `3 * 32K = 96K`, and recommends
page/memory area `5` on machines with more than 128K because it is the first
area available after the BASIC data area. Reference:
https://archive.computerhistory.org/resources/access/text/2024/10/102637948-05-001-acc.pdf

This also matches `ROLLING.BAS`: the globe itself is centered at
`(300,120)`, but the perspective floor reaches much lower. In line 320,
for frame `P=3`, the first floor line is:

```text
y = HL + 940 / (5 - P/4)
y = 100 + 940 / 4.25
y = about 321
```

On a 325-line screen that is almost the bottom edge. On a 400-line screen
it would leave nearly 80 unused scanlines below the demo.

The CPU-visible framebuffer is not at the IBM MDA text segment `B000:`.
For graphics mode, GW-BASIC writes directly into conventional RAM:

```text
page n segment = n * 0800h
page n physical = n * 8000h
```

This gives eight possible 32 KiB pages in the first 256 KiB:

```text
page 0 = 00000h
page 1 = 08000h
page 2 = 10000h
page 3 = 18000h
page 4 = 20000h
page 5 = 28000h
page 6 = 30000h
page 7 = 38000h
```

GW-BASIC's page-selection routine accepts pages 3..7 for this mode.
`ROLLING.BAS` uses pages 4..7 and asks for at least 256 KiB, which keeps
the animation frames safely high in RAM.

With a 640 KiB machine, the graphics scan-out is still tied to the low
fixed pages. `CPROBE.COM` showed the display-start value wrapping at the
256 KiB boundary: candidate segments `1800h, 2000h, 2800h, 3000h, 3800h`
displayed correctly, then higher candidates produced junk until the scan
address aliased back into the low range. For a single reliable page,
reserve/use page 7 at `3800:0000`.

This also explains Corona's original documentation language: page/memory
area numbers are 32 KiB slots in conventional RAM, not independent video
RAM banks. The video logic can rapidly display different memory-mapped
images, but the CRTC address path found so far only reaches the low 256 KiB
window.

## Pixel Layout

For page segment `page*0800h`, pixel `(x,y)` is:

```text
offset = ((y MOD 13) << 11) + ((y / 13) * 80) + (x >> 3)
mask   = 01h << (x & 7)
```

Set a pixel with:

```asm
or es:[offset], mask
```

Clear a pixel with:

```asm
and es:[offset], not mask
```

The bit order is low-bit first within each byte. This is easy to miss with
horizontal lines because a horizontal line fills whole bytes, but vertical
single-pixel lines drawn with `80h >> bit` appear about seven pixels too
far to the right.

The active 325 scanlines are stored as 13 interleaved banks, matching the
PPC-21's 13-scanline text character height. Each bank holds one scanline
from every 13-line group: 25 rows * 80 bytes, padded to an `0800h` stride.
The visible image uses 13 * 0800h = 26624 bytes inside a 32 KiB page.

Reverse-engineering note: the relevant `GWBASIC.EXE` coordinate routine
contains `mov bl,0Dh` / `div bl`, confirming the 13-line bank rhythm. The
hardware-aligned box test then confirmed the low-bit-first mask.

## Mode Switch

`SCREEN 105` is initialized by first asking BIOS for normal MDA text mode:

```asm
mov ax,0007h
int 10h
```

Then Corona GW-BASIC writes the MDA mode-control port. Mode 105 uses base
value `0A9h`. Some GW-BASIC paths OR in bit 1 for visible pages 4..7,
producing `0ABh`, but hardware testing shows this bit is not the important
page selector on this machine.

```asm
mov dx,03B8h
mov al,0A9h
out dx,al
```

The visible page is selected through the 6845/MDA CRTC start-address
register. `GWBASIC.EXE` contains two formulas for register `0Ch`:

```text
Corona-detected path:     CRTC 0Ch = (page AND 3) * 8; port 3B8h ORs bit 1 for pages 4..7
Fallback/unmasked path:   CRTC 0Ch = page * 8;         port 3B8h stays at the mode byte
```

The real hardware tests match the fallback/unmasked path. Register `0Dh`
is zero for page-aligned framebuffers.

```asm
mov dx,03B4h
mov al,0Ch
out dx,al
inc dx
mov al,page * 8
out dx,al

dec dx
mov al,0Dh
out dx,al
inc dx
xor al,al
out dx,al
```

For page 7, this means CRTC start high `38h` and port `3B8h = 0A9h`.
The `38h/0ABh` combination also works. Earlier `18h` single-page tests
showed random data because they selected `1800:0000` while drawing into
`3800:0000`; the later `CPROBE.COM` test drew matching labels into each
candidate segment and confirmed that `1800h` through `3800h` can scan out
when the selected segment is also the segment being written.

The CRTC start high register appears to wrap modulo `40h`. That is the
expected behavior for a 6845-style 14-bit start address: only the low six
bits of register `0Ch` contribute to the start address. In this Corona
mapping, `40h` in register `0Ch` would correspond to physical `40000h`,
but the missing/wrapped high bits make it alias to `00000h` instead:

```text
CRTC 0Ch = 40h -> aliases 0000h
CRTC 0Ch = 48h -> aliases 0800h
CRTC 0Ch = 50h -> aliases 1000h
CRTC 0Ch = 58h -> aliases 1800h
CRTC 0Ch = 60h -> aliases 2000h
...
CRTC 0Ch = 78h -> aliases 3800h
```

This explains the observed probe sequence: candidates up through `3800h`
work, several higher candidates show unrelated low-memory contents, and
then the visible labels repeat once the masked address lands back on
segments the probe had drawn.

External hardware documentation supports this interpretation. The Motorola
MC6845 data sheet says the start address is a 14-bit register pair, with
the high register carrying only `MA8..MA13`, and the CRTC provides memory
addresses `MA0..MA13`. MAME also models the Corona PPC-21 as an IBM PC
clone using an MC6845-family display device, though its entry still marks
graphics as imperfect/not working. References:
https://www.bitsavers.org/components/motorola/_dataSheets/6845.pdf and
https://arcade.vastheman.com/minimaws/machine/coppc21

Minimal mode/page-7 setup:

```asm
mov ax,0007h
int 10h

mov dx,03B8h
mov al,0A9h
out dx,al

mov dx,03B4h
mov al,0Ch
out dx,al
inc dx
mov al,38h
out dx,al

dec dx
mov al,0Dh
out dx,al
inc dx
xor al,al
out dx,al
```

## Page Probe

`CPAGES.COM` was an experimental probe for higher framebuffer addresses,
but it is large enough that DOS can load it overlapping the fixed graphics
pages it writes to. If it cycles rapidly or behaves erratically, that is
probably self-overwrite rather than video behavior.

The safer old page-selector probes were the tiny single-page binaries:

```text
C18AB.COM  writes 3800:0000 and selects port 3B8h=A9h|02h, CRTC 0Ch=18h
C38A9.COM  writes 3800:0000 and selects port 3B8h=A9h,      CRTC 0Ch=38h
C38AB.COM  writes 3800:0000 and selects port 3B8h=A9h|02h, CRTC 0Ch=38h
C18A9.COM  writes 3800:0000 and selects port 3B8h=A9h,      CRTC 0Ch=18h

C90A9.COM  writes 9000:0000 and selects port 3B8h=A9h,      CRTC 0Ch=90h
C90AB.COM  writes 9000:0000 and selects port 3B8h=A9h|02h, CRTC 0Ch=90h
C98A9.COM  writes 9800:0000 and selects port 3B8h=A9h,      CRTC 0Ch=98h
C98AB.COM  writes 9800:0000 and selects port 3B8h=A9h|02h, CRTC 0Ch=98h
```

Hardware testing showed that this machine uses the fallback/unmasked path:
page 7 is `CRTC 0Ch = 38h` with `port 3B8h = A9h`. The `18h/A9h` and
`18h/ABh` paths produced random screen data. `38h/ABh` also produced
usable graphics, so bit 1 of port `3B8h` does not appear to hurt once the
raw CRTC start value is correct.

The `98h` probes produced random screen data, and `CPROBE.COM` later
confirmed the 256 KiB wrap behavior. There is still no evidence that this
mode can scan `9800:0000`; through the known CRTC/page mechanism, the
practical hardware-selected page range tops out at the low page-7 address,
`3800:0000`.

`CBOX.COM` / `CBOX13.COM` are the current useful drawing probes. They use:

```text
page segment: 3800h
CRTC 0Ch:     38h
port 3B8h:    A9h
y mapping:    y MOD 13, y / 13
bit order:    01h << (x AND 7)
```

`CPROBE.COM` is the current page-enumeration probe. It is intentionally
small enough to avoid the old `CPAGES.COM` self-overwrite problem. It:

- moves its stack inside the `.COM` image, because DOS normally starts a
  `.COM` stack at the top of the allocated memory block
- shrinks its own DOS memory block to the actual program size with
  `INT 21h/AH=4Ah`
- asks DOS for the largest free block with `INT 21h/AH=48h`
- allocates that largest free block, so every tested page belongs to the
  probe while it runs
- computes the first candidate as the next 32 KiB-aligned segment inside
  that allocated block
- prints the allocated block, first candidate, last candidate, count, and
  full candidate segment list while still in text mode
- waits for a `Y`/`y` confirmation before switching to graphics mode;
  any other key exits cleanly
- clears each candidate page and draws a large two-digit hex label into it
- enters graphics mode and displays the current candidate page
- advances to the next candidate on any non-Esc key
- exits to text mode on Esc, then frees the allocated probe block

The startup text looks like this:

```text
Corona PPC-21 graphics page probe
Allocated free block: xxxx to xxxx
First 32K page:     xxxx
Last 32K page:      xxxx
Page count:         xxxx
Pages to test:      xxxx xxxx ...
Proceed with graphics test (Y/N)?
```

The `Allocated free block` line shows the DOS memory block that the probe
successfully allocated for scratch page testing. Candidate pages are then
chosen only at 32 KiB segment boundaries inside that block. If there is no
32 KiB-aligned candidate page inside the largest free block, the program
prints `No 32K candidate pages found in free DOS memory.` and exits without
entering graphics mode.

The two-digit label is the high byte of the candidate segment. For example,
candidate segment `3800h` is labeled `38`; candidate segment `9800h` is
labeled `98`. A page is considered valid for scan-out only if the matching
label appears when that candidate is selected. Junk or an unrelated label
means the adapter is not scanning that candidate address correctly.

Run:

```dos
CPROBE
```

If the `.COM` cannot be copied directly, recreate it with DOS DEBUG:

```dos
DEBUG < CPROBE.SCR
```

The old `CPAGES.COM` did this, but it should be treated as obsolete/noisy
because of its size and apparent self-overlap:

It writes large two-digit labels into 32 KiB-aligned candidate segments:

```text
2000h, 2800h, 3000h, 3800h, 4000h, 4800h, 5000h, 5800h,
6000h, 6800h, 7000h, 7800h, 8000h, 8800h, 9000h, 9800h
```

The label is the segment high byte: segment `3800h` gets `38`, segment
`9800h` gets `98`, and so on.

Run:

```dos
CPAGES
```

Press any non-Esc key to advance to the next display-start test. Press
Esc to return to text mode and exit. On the tested machine it appeared to
cycle rapidly without reliable keyboard stops, so prefer the tiny
single-page probes above.

The first four key stops used the GW-BASIC-style page selectors for pages
4..7. After that, the program tried raw CRTC start-high values
`20h, 28h, ..., 98h` with port `3B8h = 0ABh`.

If `98` ever appears, the adapter can scan the physical page at
`9800:0000`. If it only ever shows the low labels, wraps, blanks, or shows
junk, then the adapter likely cannot select arbitrary high conventional
RAM through this mechanism.

The fallback DEBUG script is `CORONA_PAGES_DEBUG.SCR`, but it is large
because it enters the binary byte-by-byte. Copying `CPAGES.COM` directly
is preferable when possible.

## CGA BIOS Shim

`CGA105.COM` is the first-pass TSR for CGA API-level emulation on the
PPC-21 graphics mode. It is not a hardware-level CGA card emulator. It
does not trap direct writes to `B800:0000`, and it cannot see direct port
writes to CGA registers such as `03D8h`, `03D9h`, `03DAh`, or `03D4h`.
Those require the later hardware-assisted `B800h` RAM path.

The TSR hooks:

- `INT 10h` for selected CGA BIOS video functions
- `INT 11h` so BIOS equipment queries report CGA 80-column display bits

The TSR leaves the BIOS Data Area equipment word at `0040:0010` set to
CGA so programs that read the BDA directly, including some DOS `MODE.COM`
versions, see a color display. Before calling the real Corona BIOS, it
temporarily switches the equipment bits back to monochrome/MDA so the
physical PPC-21 text console remains usable.

`INT 10h` text modes `02h` and `03h` are treated as CGA text aliases:
the TSR asks the real BIOS for mode `07h` so the screen remains visible,
then resumes reporting CGA through the BDA/`INT 11h` path. This is intended
to make `MODE CO80` accept the display as CGA-compatible, but it still does
not provide visible `B800:` text memory.

Implemented `INT 10h` functions:

```text
AH=00h AL=04h/05h  set CGA 320x200 4-color-like graphics
AH=00h AL=06h      set CGA 640x200 mono-like graphics
AH=0Bh             remember palette/background requests
AH=0Ch             write graphics pixel
AH=0Dh             read graphics pixel
AH=0Fh             report current active emulated video state
```

The TSR keeps a 16 KiB CGA shadow framebuffer internally so BIOS pixel
reads and XOR pixel writes have CGA-like behavior. It separately reserves
one 32 KiB-aligned Corona graphics page inside the TSR's own resident DOS
memory block. The page is chosen as the first 32 KiB boundary after the
resident TSR code/data, and it must end below segment `4000h`, matching
the observed 256 KiB scan-out limit. During installation, the program first
moves `SS:SP` to a small stack inside its own resident image; otherwise the
32 KiB Corona page clear can overwrite DOS's default `.COM` stack near the
top of the allocation.

Mode `04h`/`05h` maps each 320-wide CGA pixel to two horizontal PPC-21
pixels. Because the PPC-21 display path is 1bpp, CGA color indexes are
dithered into monochrome:

```text
color 0: 0 percent on
color 1: 25 percent checker
color 2: 50 percent checker
color 3: 100 percent on
```

Mode `06h` maps CGA 640x200 1bpp directly to Corona 640-wide pixels. By
default, the TSR vertically stretches 200 CGA rows across all 325 Corona
rows using a `13/8` row expansion. This duplicates five rows out of every
eight, filling the screen without requiring fractional pixels. Start with
`/N` to disable that stretch and leave the CGA image in the top 200 rows.

Run:

```dos
CGA105
```

or, with 640x200 vertical stretch disabled:

```dos
CGA105 /N
```

Unload, if `CGA105` is still the top `INT 10h` and `INT 11h` hook:

```dos
CGA105 /U
```

If the `.COM` cannot be copied directly, recreate it with DOS DEBUG:

```dos
DEBUG < CGA105.SCR
```

Expected install message:

```text
CGA105 install trace
1 parse command tail
2 choose Corona page
  selected page segment xxxx
3 clear CGA shadow buffer
4 clear Corona page
5 save INT 10h vector
6 save INT 11h vector
7 hook INT 10h
8 hook INT 11h
9 set CGA equipment bits for DOS programs
CGA105 resident. BDA/INT 11h report CGA. Corona buffer at xxxx:0000, mode 6 stretch ON
```

If the final resident line does not appear, the last numbered line shown
indicates the step that completed before the failure or hang.

The reported buffer segment is the actual 32 KiB Corona page used by the
TSR. If install fails with `no 32K-aligned Corona graphics page is
available below 40000h`, the TSR was loaded too high or the low memory map
is too fragmented for the current strategy.

The `/U` path checks a resident signature through the current `INT 10h`
vector, confirms that both `INT 10h` and `INT 11h` still point directly to
`CGA105`, restores the saved original vectors, resets the BDA equipment
bits to monochrome/MDA, and frees the resident DOS memory block. If another
TSR has hooked either interrupt after `CGA105`, unload is refused with a
message so the interrupt chain is not broken. Builds from before the
resident signature was added cannot be unloaded this way; reboot before
testing `/U` with this newer build.

## Future PicoMEM Path

The PicoMEM board is a plausible hardware assist for direct-write CGA
compatibility. Its README describes an 8-bit ISA card connected to the full
memory and I/O bus, with memory emulation at 16 KiB granularity. That maps
well to CGA graphics RAM at `B8000h-BBFFFh`, which is exactly one 16 KiB
block. Reference: https://github.com/FreddyVRetro/ISA-PicoMEM

A likely design:

```text
PicoMEM emulates:
  B8000h-BBFFFh    CGA 16 KiB framebuffer
  optional UMB     converted/working buffer or dirty map
  CGA I/O ports    03D8h, 03D9h, 03DAh, maybe 03D4h/03D5h

TSR owns:
  low Corona page  32 KiB below 40000h, usually page 7 at 3800:0000
  timer/poll loop  convert dirty CGA rows/blocks into the Corona page
```

For PicoMEM v1, the final write into the Corona page probably still needs
the 8088. The README notes that current memory emulation does not support
DMA, while PicoMEM 2 lists DMA support as future/new hardware functionality.
Without bus-master/DMA capability, the Pico can respond to host memory and
I/O accesses, but it cannot independently copy pixels into the PPC-21's
motherboard RAM page at `3800:0000`.

The best first hardware-assisted target would be:

- emulate `B8000h-BBFFFh` as CGA RAM
- track dirty rows or dirty 16/32-byte blocks in PicoMEM firmware
- expose a small status/command I/O interface for the TSR
- optionally have the Pico pre-convert dirty CGA rows into Corona byte
  layout in an internal/UMB buffer
- have the TSR copy converted dirty rows into the real Corona scan-out page

This avoids full-frame polling. It also avoids needing PicoMEM to generate
video; the PPC-21's own display hardware still scans the real Corona page.
The open question is whether the PPC-21 display hardware can scan a low
page supplied by ISA memory emulation instead of motherboard RAM. Do not
assume that without testing. If PicoMEM can emulate `3800:0000`, rerun the
page/box tests with the Corona page supplied by PicoMEM RAM and confirm
whether the display logic actually sees it.
