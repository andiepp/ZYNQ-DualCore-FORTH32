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
| 2 | Hardware divider in the multi-cycle unit (single core first), ISS and kernel | next |
| 3 | Second HF32 + its own unit and RAM in `forth_system`; per-core I/O decode, mailboxes, shared RAM window, pin ownership per core | |
| 4 | ARM firmware 4.0: two kernel loads, per-core input rings, `input`/`mux`/core markers, core-addressed requests, second source sector | |
| 5 | Kernel words for two cores (`core#`, `send`, `receive`, `mail?`, locks); manual | |
| 6 | Board tests (both cores, divider, peripherals shared), timing, release 4.0 | |
| later | HASE: the node shows core 0 as today; core 1 in the HASE panel needs its own HASE-Lab ADR | |

## Step 2: hardware divider

Today `u/mod`, `/mod` and `um/mod` are Forth loops (about 650 instructions, 13 µs). The
multi-cycle unit (`rtl/hf32_mcu.v`) gets an unsigned radix-2 divider, 32/32 bits, one
quotient bit per clock (about 34 clocks with decode and the result).

- **Instructions:** two free `op` codes (33 and up are free; the field has 6 bits) and two
  free unit codes (10 and up): *N / T unsigned, quotient* and *N / T unsigned, remainder*.
  The unit keeps the last operands and both results, so the second of a `u/mod` pair with the
  same operands finishes in 2 clocks instead of a second division.
- **Division by zero:** a fixed result (quotient all ones, remainder N, as RISC-V does);
  the kernel's `/` and `mod` keep their own check if they report an error today.
- **Kernel:** `u/mod`, `/mod`, `/`, `mod` on top of the new primitives; signs handled in
  Forth (floored or symmetric exactly as today, so 3.x sources give the same results).
  `um/mod` (64/32) keeps its Forth long division, now built on 32/32 steps, unless a 64-bit
  dividend variant proves worth the extra register.
- **Verification:** the same pattern as the FPU: a Python model in `tools/hf32.py` (ISS),
  a random-vector testbench of the RTL against the model (`sim/run_mcu.ps1`), the RTL = ISS
  check of the kernel (`sim/run_sim.ps1`), then the board.

## Step 3 onwards: the second core

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
