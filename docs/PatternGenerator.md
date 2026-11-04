# Pattern generator — design

Status: **in progress** (2026-11-02). The FPGA part (`rtl/patgen.v`, `sim/tb_patgen.v`), the
kernel words, the firmware's `board` line (firmware 2.2) and the app's live view and pattern
editor are built and tested on the board over JTAG; the manual chapter and a scope check of the
5 ns edges are still to come.

A 16-channel digital pattern generator in the PL. Forth (or the app's graphical editor, which
writes Forth) loads a pattern and starts it; from then on the hardware plays it at a fixed 5 ns
time step, independent of the 50 MHz Forth CPU.

## Decisions

| Question | Decision |
|---|---|
| Channels and pins | 16 outputs on Pmod JA (channels 0–7) and JB (channels 8–15). Both headers are free today, and the board's pin file names their pins as P/N pairs (differential-pair routing), so they carry fast edges better than the shield pins. |
| Time step | 5 ns: the generator runs from its own 200 MHz clock (PS clock FCLK1). |
| Extras in the first version | external trigger input, loops with repeat counts, live view in the app |
| How patterns reach the board | as Forth source only. The app's editor generates Forth words; the same text can be saved with `store`, so a pattern survives a power cycle and can autostart without a new flash format. A binary upload request can follow if large patterns load too slowly. |
| HASE | unchanged in the first version: the MCNF node and the HASE panel do not see the generator (Forth words still work from the HASE terminal). |

## Pins

| Channel | Pmod pin | FPGA pin | | Channel | Pmod pin | FPGA pin |
|---|---|---|---|---|---|---|
| 0 | JA1 | Y18 | | 8 | JB1 | W14 |
| 1 | JA2 | Y19 | | 9 | JB2 | Y14 |
| 2 | JA3 | Y16 | | 10 | JB3 | T11 |
| 3 | JA4 | Y17 | | 11 | JB4 | T10 |
| 4 | JA7 | U18 | | 12 | JB7 | V16 |
| 5 | JA8 | U19 | | 13 | JB8 | W16 |
| 6 | JA9 | W18 | | 14 | JB9 | V12 |
| 7 | JA10 | W19 | | 15 | JB10 | W13 |

```
          Pmod JA                               Pmod JB
 pin    6    5    4    3    2    1        6    5    4    3    2    1
      3V3  GND  CH3  CH2  CH1  CH0      3V3  GND  CH11 CH10 CH9  CH8
      3V3  GND  CH7  CH6  CH5  CH4      3V3  GND  CH15 CH14 CH13 CH12
 pin   12   11   10    9    8    7       12   11   10    9    8    7
```

As the headers look on the board. Pmod pins 5/11 are GND and 6/12 are 3.3 V. Outputs are LVCMOS33 (fast slew, 8 mA), registered in
the I/O block on the 200 MHz clock, so all channels switch on the same clock edge. A channel that
is not enabled is high-impedance; after power-up and after each Forth restart all are. JA and JB are the Arty Z7's high-speed Pmod headers (their data pins are routed as
differential pairs); Digilent fits these with 0 Ω shunts instead of protection resistors, so
the outputs are not protected against a short. The manual says so.

## The sequencer

The pattern memory holds **4096 steps** of 80 bits each (9 block RAMs):

| Bits | Field | Meaning |
|---|---|---|
| 79..64 | `out` | the 16 channel levels during this step |
| 63..32 | `dur` | duration in 5 ns ticks, 1 to 2³²−1 (5 ns to 21.4 s) |
| 31..28 | `op` | what happens at the end of the step, below |
| 27..16 | `target` | step number for `loop` and `jump` |
| 15..0 | `count` | repeat count for `loop` |

| op | Name | Behavior |
|---|---|---|
| 0 | step | output `out` for `dur` ticks, then the next step |
| 1 | loop | output `out` for `dur` ticks, then jump back to `target` until the block `target`..this step has run `count` times in all; `count` 0 = forever |
| 2 | jump | output `out` for `dur` ticks, then continue at `target` |
| 3 | wait | output `out`, wait for the trigger, then hold `out` for `dur` more ticks |
| 4 | end | output `out` and stop; the outputs keep this level until the next start |

Loops nest up to **4 levels deep** (a small loop-counter stack in hardware). A loop-end step
recognizes whether its loop is already active by its own step number on top of the stack. So
loops that are nested properly work without a separate "loop begin" step.

**Timing:** every step lasts exactly `dur` ticks; a duration of 0 counts as 1. A fetcher reads
steps ahead into a 16-step FIFO, one step per clock, and the player takes the next one from it at
the last tick of the current step, so back-to-back 1-tick steps play without gaps. The fetcher
reads the step after each step speculatively; at a jump or a repeat it throws that read away and
loses one clock. It makes that up during steps longer than one tick, and the FIFO (filled before
the first step plays) covers short stretches without slack. The rule for exact timing: **in a
loop that runs long, one pass must last at least one tick more than it has steps** — so a loop
whose steps are all 5 ns cannot keep up for long. If the FIFO runs dry, the current step is
stretched by a tick and status bit 4 ("late") is set; the levels stay right. The testbench
compares the pins tick by tick with a model of these rules (`sim/tb_patgen.v`).

**Trigger:** the trigger source is a shield pin (0–41), a button (BTN0–BTN3) or software only.
The edge can be rising, falling or both, and a software trigger from Forth works with any source.
The pin is synchronized to the 200 MHz clock: the wait step's `dur` ticks start 10–15 ns after
the edge (5 ns jitter), so with `dur` = 1 the next step's levels appear 15–20 ns after the edge
(the testbench measured 21 ns including the edge's position in the clock). A trigger that arrives
while the generator is not waiting is ignored, and so is the level change when the trigger source
itself is switched.

**Start and stop:** `start` begins at step 0, also while running (restart); the first step plays
about 0.1 µs later, once the FIFO is filled, and the pins show the idle levels until then. To start
on a trigger, make step 0 a `wait` step. `stop` sets the enabled channels to the idle level. The
pattern memory can only be written while the generator is stopped or ended (writes while it runs
are ignored and flagged in the status). Commands and settings take about 0.1 µs to reach the
generator; status bit 6 ("busy") is set until they have and the status reflects them.

## Forth interface

I/O registers (one cell each at 0x100180 + 4r, of which the generator uses the low 16 bits;
the 16-bit ZYNQ-FORTH had them at 0x80C0 + 2r):

| Address | Read | Write |
|---|---|---|
| 0x100180 | status: bit 0 running, 1 waiting for the trigger, 2 ended, 3 a pattern write was ignored, 4 a step ran late, 5 loops nested too deep, 6 busy | bit 0 start (wins over stop), bit 1 stop, bit 2 software trigger. Start or stop clear bit 3; start clears bits 4 and 5. |
| 0x100184 | current step | load address (step number) |
| 0x100188 | current output levels | `out` |
| 0x10018C / 0x100190 | what was written | `dur` low / high 16 bits |
| 0x100194 | what was written | `op` (bits 15..12) and `target` (bits 11..0) |
| 0x100198 | what was written | `count`; this write stores the step and advances the load address |
| 0x10019C | channel enable mask | same |
| 0x1001A0 | idle level | same |
| 0x1001A4 | trigger: bits 5..0 source (0–47 pin, 48–51 BTN0–3, other: software only; default 63), bits 9..8 edge (01 rising, 10 falling, 11 both) | same |
| 0x1001A8 | load address | – |

A fifth nested loop does not repeat (it falls through) and sets status bit 5.

Kernel words (durations are double cells in ticks, as in the 16-bit ZYNQ-FORTH, where 32 bits
did not fit a cell; a double `lo hi` means `lo + hi*65536`, so with this Forth's own `ns us
msec` hi is 0 and sources written for the 16-bit Forth run unchanged):

| Word | Stack | Meaning |
|---|---|---|
| `ns` `us` `msec` | `( n -- d )` | duration in ticks: `100 ns` = 20 ticks, `us` ×200, `msec` ×200000 (rounding down to whole 5 ns ticks; `msec` up to 21474). Not `ms`: that word already waits n milliseconds. |
| `pg-at` | `( step -- )` | where the next step is stored |
| `pg-step` | `( out d -- )` | store a step |
| `pg-loop` | `( out d target count -- )` | store a loop end |
| `pg-jump` | `( out d target -- )` | store a jump |
| `pg-wait` | `( out d -- )` | store a wait step |
| `pg-end` | `( out -- )` | store an end step |
| `pg-start` `pg-stop` `pg-trig` | `( -- )` | control |
| `pg-enable` `pg-idle` | `( mask -- )` | channel enable mask, idle levels |
| `pg-trigger` | `( source edge -- )` | trigger source and edge |
| `pg-status` `pg-pc` `pg-out@` | `( -- u )` | status bits (after `pg-sync`), current step, current levels |
| `pg-sync` | `( -- )` | wait until commands and settings have reached the generator |

The step words refuse to store while a pattern runs (" pattern running"); `pg-start`, `pg-stop`,
`pg-trig` and the settings words return once the generator has applied them. Forth's input line
holds 80 characters, so generated source keeps lines shorter.

Example: a 1 MHz clock on channel 0 with a marker on channel 1 every 1000 cycles, started by a
rising edge on IO2:

```forth
pg-stop  3 pg-enable  0 pg-idle
2 1 pg-trigger
0 pg-at
  0  100 ns pg-wait           \ 0: wait for IO2, then 100 ns low
  1  500 ns pg-step           \ 1: channel 0 high
  0  500 ns 1 999 pg-loop     \ 2: low; steps 1-2 run 999 times
  3  500 ns pg-step           \ 3: channels 0+1 high (the marker cycle)
  0  500 ns 1 0 pg-loop       \ 4: low; steps 1-4 forever
pg-start
```

The two loops end on different steps (2 and 4) and are nested properly, so no extra step is
needed. A duration that rounds down to 0 ticks is stored as 1 tick.

## ARM side and protocol

- New read-only AXI registers 0x30 PG_STATUS (bits 27..16 current step, bits 6..0 the status as
  at 0x100180) and 0x34 PG_OUT (enable mask in bits 31..16, current output levels in bits 15..0).
- The `board` answer gets one more line, `pg <status> <out>`. Older apps ignore unknown lines, so
  the protocol version stays 1.
- The firmware needs no other change: loading goes through Forth.

## The app

**Live view.** The board view draws the two Pmod headers with their 16 channels: enabled or not,
and the current level. The status line shows running / waiting / ended and the current step. These
are snapshots at the polling rate (a few per second), not a logic analyzer.

**Pattern editor**, a new panel next to the source editor:
- A timing diagram with one row per channel (with editable channel names) and one column per step.
  The column width follows the duration on a log scale, so 5 ns and 1 s steps both stay usable.
  The exact duration is written in each column.
- Click a cell to toggle a level; drag across cells to paint. Insert, delete and duplicate steps;
  edit a duration in ns/µs/ms/s (rounded to 5 ns, shown when it is rounded).
- Select a run of steps → "Repeat…" (count, or forever); repeats show as brackets above the steps
  and may nest 4 deep. Mark a step as "wait for trigger". Choose what happens at the end: stop,
  restart from the beginning, or restart from a chosen step.
- Trigger source and edge in the panel's header; the enables beside the diagram; the idle
  levels in the diagram's first column (click to switch), with the edge into step 0 drawn.
- **Load** sends the generated Forth to the board and starts it. **To editor** inserts the same
  Forth into the source editor (to save it with autostart or edit it further). **Start/Stop**.
- Patterns are saved as `.pattern` files (JSON: channel names, steps, repeats, settings).
- The app checks the limits before loading: 4096 steps, 4 nesting levels, 65535 repeats.

## Cost and risks

- About 9 block RAMs (of 140) and a few hundred LUTs. The crossing between the 50 MHz CPU and
  the 200 MHz sequencer is control registers only, synchronized with toggle handshakes (settings
  and commands one way, a status snapshot the other way); the pattern memory is written on the CPU
  clock and read on the generator clock.
- Loading speed: one step is about 25 characters of Forth, so 4096 steps take about 9 s at
  115200 baud. Typical patterns are much shorter. If it bites, a binary `pattern` request comes
  next.
- Pmod outputs have no short-circuit protection (to be confirmed in the reference manual); the
  manual will say so.
- Bench verification needs a scope or logic analyzer on JA/JB for the 5 ns claims. Without one,
  slower patterns can be checked by wiring a Pmod pin to a shield pin and reading it from Forth.

## Plan

1. RTL: `rtl/patgen.v` + testbench (step timing, 1-tick steps, loops, nesting, jump, wait, end,
   stop, ignored writes). FCLK1 = 200 MHz, Pmod constraints, registers in `forth_system.v`.
2. Kernel words + system simulation with a Forth pattern; firmware `board` line and AXI registers.
3. Bitstream, JTAG test on the board, scope check.
4. App: live view, then the pattern editor (+ tests for the Forth generator and limit checks).
5. Manual chapter, examples (`examples/patterns/`), release (firmware/app 2.2) and flashing,
   both only on your go-ahead.
