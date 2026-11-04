# ZYNQ-DualCore-FORTH32 — plan

ZYNQ-DualCore-FORTH32 continues [ZYNQ-FPGA-FORTH32](https://github.com/andiepp/ZYNQ-FPGA-FORTH32)
3.1 (this repository started as a copy of its commit 178f766) with two changes: a **hardware
divider** and a **second HF32 core**. The version line is 4.x.

## Decisions (2026-11-04)

- **Two independent Forths.** Each core has its own 128 KB RAM, kernel, dictionary, data,
  return and float stacks, input ring and saved source. They share the board's I/O, and they
  talk through hardware mailboxes (and a shared RAM window). Neither core waits for the other's
  memory accesses, so both stay at one instruction per clock.
- **One serial line, two terminals.** The ARM multiplexes them (protocol 3, see
  [Protocol.md](Protocol.md#two-cores-protocol-3)). A terminal program still sees core 0 only.
- **The app shows one core at a time**, switched with Core 0 / Core 1 (Ctrl+1 / Ctrl+2):
  terminal, source editor, stacks, dictionary and saved source belong to the shown core; the
  board view and the pattern editor are shared. Both terminals keep collecting output.

## Steps

| # | Step | State |
|---|---|---|
| 1 | Standalone app for two cores, protocol 3 drafted, simulated board in the app | done 2026-11-04 |
| 2 | Hardware divider in the multi-cycle unit (single core first), ISS and kernel | done 2026-11-04 (board test with step 6) |
| 3 | Second HF32 + its own unit and RAM in `forth_system`; per-core I/O decode, mailboxes, shared RAM window, pin ownership per core | |
| 4 | ARM firmware 4.0: two kernel loads, per-core input rings, `input`/`mux`/core markers, core-addressed requests, second source sector | done 2026-11-04 (on the board over JTAG; not flashed) |
| 5 | Kernel words for two cores (`core#`, `send`, `receive`, `mail?`, locks); manual | |
| 6 | Board tests (both cores, divider, peripherals shared), timing, release 4.0 | |
| later | HASE: the node shows core 0 as today; core 1 in the HASE panel needs its own HASE-Lab ADR | |

## Step 2: hardware divider (done)

As built (design.md 3.3, 4.1, 7.9): the multi-cycle unit (`rtl/hf32_mcu.v`, op 10) divides
64 by 32 bits unsigned, two quotient bits per clock, 17 clocks. That made one instruction
enough for both `um/mod` and `u/mod` (the latter with a high cell of 0), rather than the
32/32 pair first planned.

- **Instructions:** op 33 `(um/mod)` ( lo hi d -- quot ), reading NN through a second read
  port of the data stack; op 34 `(urem)` ( -- rem ), a single-cycle read of the remainder the
  unit keeps.
- **Results:** the restoring algorithm of the former Forth `um/mod` loop, so overflow and
  division by zero (quotient −1, remainder the low dividend cell) give what 3.x gave.
- **Kernel:** `u/mod` and `um/mod` are inline (`0 swap (um/mod) (urem) swap`,
  `(um/mod) (urem) swap`); `/mod / mod */` unchanged on top of them.
- **Verification:** `tools/test_fpu.py` checks the model against exact division,
  `sim/run_mcu.ps1` the RTL against the model (6,000 divide vectors), and the kernel on the
  whole RTL gives the ISS's output (`sim/run_regress.ps1`) for `smoke`, `divide`, `float`
  and `manual_checks`; the slower peripheral inputs were not run (several minutes each, and
  they don't exercise the divider beyond number output). The ISS gives the same output as the
  3.1 kernel on all `sim/*.txt` inputs. The board test
  comes with the dual-core firmware (step 6), or earlier if a single-core 3.2 build is wanted.

## Step 3: the second core (in progress)

Three parts, each checked before the next:

1. **Two cores side by side** (2026-11-04): `rtl/hf32_node.v` is one core with its RAM and
   terminal FIFOs; `forth_system` has two of them and one I/O bus with an arbiter (design.md
   5.2). The core-number register is `$10001C`. AXI: core 1's registers at 0x40..0x54, the
   number of cores at 0x3C; core 1 is held until the ARM releases it, so firmware 3.1 still
   runs on this logic as a single core. Checked with `sim/run_dual.ps1` (both cores at once,
   each against the simulator; each core read the core number 6,000 times while both wrote
   the LEDs, no errors, about 13,600 clocks of waiting each in 2.8 million) and single-core
   `smoke`/`divide` (unchanged). Built: 12,485 LUTs, 73 block RAMs, 21 DSPs; 0.905 ns slack
   at 50 MHz (3.2 ns with one core), 0.134 ns at 200 MHz. Not on the board yet (step 4).
2. **Mailboxes, locks and shared RAM** (2026-11-04, design.md 5.2 and 5.3): a 32-word
   mailbox per direction (`$100050` data, `$100054` status), 8 locks (`$100060 + 4n`, taken
   by a store and checked by a read, so the CPU's read-ahead never takes one), 4 KB shared
   RAM at `$101000`. AXI 0x3C also gives each mailbox's fill level. The simulator has a
   two-core run (`--input-file1`): both cores step in turn and share these. Checked with
   `run_dual.ps1 -Input0 mail0 -Input1 mail1`; without the locks, the simulator's shared
   counter ends at 1709 instead of 2000, so the test would catch a broken lock. RTL = ISS
   on both cores (2000 in the RTL too), and part 1's test still passes. Built: +252 LUTs,
   +1 block RAM; 0.779 ns slack at 50 MHz, 0.142 ns at 200 MHz.
3. **Pin and peripheral ownership per core** (2026-11-04, design.md 5.3, 5.16, 7.12): the
   pin owner table moved from the kernel into the hardware (`$100300 + 4n`: id and core,
   taken by a write and checked by a read), peripherals have an owner core (`$1003C0 + 4u`,
   taken by the open words, released by the close words), GPIO latches and directions are
   changed with set/clear/toggle registers (`$100140`, `$100170`) instead of
   read-modify-write. A core's restart resets and releases what it held; the other core
   keeps running. Checked with `run_dual.ps1 -Input0 own0 -Input1 own1` (the other core's
   pins read 16 + id, its peripherals refuse, releases work, 1,000 and 1,001 toggles from
   both cores on one port all arrive), the new kernel's ISS output equals the old one on
   every input (apart from `here` and `words`), single-core `shield`/`pwm` RTL = ISS. The
   ISS now shares the board I/O between its two cores, and its XADC codes are truncated
   like the Xilinx model's (`shield` had differed by 1 mV). Built: 13,351 LUTs; timing met,
   but only 0.136 ns at 50 MHz. A core's restart while the other runs is not simulated yet
   (it needs the ARM's restart, step 4).
4. **A register stage on the I/O bus** (2026-11-04, design.md 5.2): each core's request is
   registered and served in the next clock; a core waits while its request is not served
   and in the clock after a read. All stalls come from registers, so the store hold of
   part 1 is gone and the CPU is back to its step-2 form (plus stacks that start at 0, as
   in the simulator: an underflow had read unknown values and frozen the testbench).
   50 MHz slack 3.974 ns (from 0.136), 200 MHz 0.465 ns; the three two-core tests and
   single-core `smoke`/`shield` RTL = ISS. An I/O access costs one clock more.

## Step 4: ARM firmware 4.0 (done)

`sw/src/main.c` keeps one `struct core` per core (register offset, flash sector, 64 KB input
ring, 4 KB output ring, start count, saved source) and implements protocol 3 (Protocol.md):
`version` reports `cores 2`, per-core requests take a trailing core number, `input n` steers
the terminal input, `mux on|off` sends both cores' output with core markers (the first output
after `mux on` is always marked). The HASE node keeps talking about core 0 (it now reports
firmware 4.0). On a single-core bitstream (CORES register 0) it runs core 0 only.

Checked on the board over JTAG (bitstream of step 3 with the bus register stage, firmware
built from this tree): both cores start and read their own core number, the mailbox carries a
word from core 0 to core 1 and back, `status`/`stack`/`words`/`restart` per core, `status 2`
refused, core 1's output held with `mux off` and delivered behind its marker after `mux on`,
core 0 keeps running through a restart of core 1. The app (protocol 3) connects, shows both
cores with their own terminal, stacks and dictionary (and its buttons are enabled right after
connecting now; they had waited for the first mouse or key input). Not checked yet: the saved
source of core 1 (`store … 1`, flash sector 0xFD0000), the HASE node with firmware 4.0, the
peripherals from both cores at once on the board.

## Step 3 onwards: notes

- **Logic:** a second `hf32_cpu` with its own `hf32_mcu` (FPU and divider) and 32 more block
  RAMs for its 128 KB: 73 of 140 block RAMs, roughly 12,000 of 53,200 LUTs. 50 MHz should
  still close; the critical path today is inside one core (ALU result to RAM address).
- **I/O:** each core keeps the I/O map at `$100000`. Its own: terminal FIFOs, mailbox
  registers, a core-number register. Shared: LEDs, buttons, pins, PWM, UARTs, SPI, I2C, DDS,
  tone, XADC, pattern generator, timers. Writes to a shared register from both cores in the
  same clock: core 0 wins, core 1 is stalled one clock (rare, invisible to programs).
- **Pin ownership** becomes per core: the router's owner table records which core opened a
  pin or peripheral, so one core cannot take the other's pins by accident.
- **Mailboxes:** a 32-entry FIFO in each direction, with full/empty flags; `receive` waits
  for a word, `send` waits for room. A small shared RAM window (one block RAM) and a few
  test-and-set lock registers for data the cores share.
- **ARM:** loads the same kernel image into both RAMs (the core-number register tells the
  kernel which one it is), keeps one input ring per core, multiplexes the output, answers
  the core-addressed requests.

## The app (step 1)

- `ZynqForth.Core/Board/BoardClient` takes a core number on every per-core request, keeps track
  of where the board's input points and sends `input n` only when it changes; `Cores` comes
  from `version` (1 for firmware 3.x, which the app still talks to as before).
- `ZynqForth.Core/Protocol/StreamSplitter` and `ForthLink` read the core markers and tag the
  output with its core.
- `ZynqForth.Core/Simulation/SimulatedBoard` is a protocol 3 board inside the app (port `SIM`):
  two small interpreters (integers, floats, colon definitions, `."`, LEDs, `core#`, `send`,
  `receive`, `mail?`), saved sources per core, the input switch and multiplexing. It is a
  stand-in for trying the app and for the unit tests, not the HF32 kernel.
- `ZynqForth/ViewModels/CoreViewModel` holds one core's terminal, editor, stacks, dictionary
  and saved source; `MainViewModel` holds the connection, the selected core, the board view
  and the pattern editor.
- Tests: `tests/ZynqForth.Core.Tests/DualCoreTests.cs` (protocol 3 parsing, addressing, the
  input switch, single-core fallback, and the simulator end to end).
