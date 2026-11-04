# Changelog

ZYNQ-DualCore-FORTH32 starts from ZYNQ-FPGA-FORTH32 3.1 (its commit 178f766) and continues its
version numbers as 4.x. The entries from 3.1 down are ZYNQ-FPGA-FORTH32's.

## 4.0 — unreleased

- **App for two cores** (`ZynqDualForth32.exe`, settings in `%LocalAppData%\ZYNQ-DualCore-FORTH32`):
  a Core 0 / Core 1 switch (Ctrl+1 / Ctrl+2) gives each core its own terminal, source editor,
  data and float stack, dictionary and saved source; the board view and the pattern editor
  are shared. A dot on a core's tab shows output that arrived while the other core was shown;
  the status line shows both cores' state and mailbox.
- **Protocol 3 (draft)**: `cores` in `version`, a core number at the end of the per-core
  requests, `input n`, `mux on|off` and core markers `SOH @n LF` (docs/Protocol.md). The app
  still talks to firmware 3.x (protocol 2) as a single core.
- **Simulated board** in the app (port `SIM`): protocol 3 with two small interpreters, for
  trying the app and for the unit tests before the dual-core firmware exists.
- **Hardware divider** in the multi-cycle unit: 64 / 32 bits unsigned, two quotient bits per
  clock, 17 clocks. New instructions `(um/mod)` ( lo hi d -- quot, op 33, reads NN through a
  second stack read port) and `(urem)` ( -- rem, op 34). `u/mod` and `um/mod` are now inline
  words on them (21 and 19 clocks instead of about 650 instructions, 13 µs); `/mod / mod */`,
  number output and the float conversions get faster with them. The results are the same as
  with the former Forth loops, bit for bit, including overflow and division by zero.
  Checked with `tools/test_fpu.py` (model against exact division), `sim/run_mcu.ps1` (RTL
  against the model) and the new `sim/run_regress.ps1` (RTL = ISS on `smoke`, the new
  `divide`, `float` and `manual_checks`).
- **Second HF32 core** in the logic (step 3, part 1): `rtl/hf32_node.v` is one core with its
  own 128 KB RAM and terminal FIFOs, and `forth_system` holds two of them on one shared I/O bus.
  When both cores use the I/O in the same clock, an arbiter holds one core for a clock or two,
  taking turns. New I/O register `$10001C`, the core number. AXI: core 1's registers at
  0x40..0x54, the number of cores at 0x3C. Core 1 stays held until the ARM releases it, so
  firmware 3.1 still runs on this logic as a single core. Checked with the new
  `sim/run_dual.ps1` (both cores at once, each against the simulator's `--core n`) and
  single-core `smoke`/`divide`; 12,485 LUTs, 73 block RAMs, timing met (0.9 ns at 50 MHz).
- **Mailboxes, locks and shared RAM** (step 3, part 2): a 32-word mailbox in each direction
  (`$100050`, status `$100054`), 8 locks (`$100060 + 4n`: write 1 to take, 0 to release, read
  0/1/2 = free/mine/the other's), 4 KB shared RAM at `$101000`. The simulator runs both cores
  together with `--input-file1`; checked with `sim/mail0.txt`/`mail1.txt` (RTL = ISS).
  12,737 LUTs, 74 block RAMs, timing met (0.78 ns at 50 MHz).
- **Pin and peripheral owners per core** (step 3, part 3): the pin owner table is in the
  hardware now (`$100300 + 4n`, read 0 free, the id when this core's, 16 + id when the
  other's), and every peripheral has an owner core (`$1003C0 + 4u`): the open words take it,
  the close words give it back, the other core gets ` in use by the other core`. `output`
  takes a pin as owner 15, `input` gives it back; `output input high low toggle` refuse the
  other core's pins. GPIO uses new set/clear/toggle registers (`$100140 + 16p`,
  `$100170 + 4p`), so the cores never undo each other's changes. A core's restart resets
  and releases its peripherals and pins while the other core runs. New words `(owner)`,
  `(mine)`, `unit`, `(unit)`, `unit-free`; `pin-owner` is gone. The ISS shares the board
  I/O between its cores, and its XADC codes are truncated like the Xilinx model's.
  13,351 LUTs; timing met with 0.136 ns at 50 MHz.
- **Register stage on the I/O bus**: the cores' I/O requests are registered and served in
  the next clock, so the decode no longer hangs off the cores' next-T logic. An I/O access
  costs one clock more; the 50 MHz margin is back to 3.974 ns (from 0.136 ns). The arbiter's
  store hold is gone, and the CPU is its step-2 self again. The CPU's stacks start at 0, as
  in the simulator.

## ZYNQ-FPGA-FORTH32

ZYNQ-FPGA-FORTH32 continues the version numbers of the 16-bit
[ZYNQ-FORTH](https://github.com/andiepp/ZYNQ-FORTH) (whose changelog has releases 1.0 to
2.3), as its 32-bit generation 3.x.

## Unreleased

- **Implementation details**: `docs/design.md`, also as `docs/Implementation-Details.pdf` (`python
  tools/manual_pdf.py design`), now describes the whole design in detail: the HF32 CPU and its
  memory timing, the FPU's datapath, every peripheral, the ARM program, the Forth kernel
  layer by layer, tools, verification and the build. Release packages include the PDF.

## 3.1 — 2026-11-04

- **Serial interfaces in hardware**, every signal on any pin: two UARTs (8N1, any baud
  rate, 64-byte FIFOs), two SPI masters (modes 0..3, 8/16/32 bits, MSB/LSB first, up to
  12.5 MHz) and an I2C master (up to 400 kHz, open drain, clock stretching, on the shield's
  SCL/SDA by default). Words: `uart-open uart-close uart-emit uart-type uart-key uart-key?
  uart-status`, `spi-open spi-close spi-hz spi-mode spi-bits spi-lsb spi-xfer spi-write
  spi-read`, `i2c-open i2c-open-pins i2c-close i2c@ i2c! i2c-scan i2c-probe i2c-addr
  i2c-start i2c-stop i2c-write i2c-read`.
- **DDS**: a square wave on any pin from a 32-bit phase accumulator at 200 MHz (0.047 Hz
  steps, 5 ns edges): `dds-hz dds-pin dds-off`.
- **Tone generator** on the board's audio jack: sine, square, triangle, sawtooth, a
  click-free volume ramp, delta-sigma output into the board's filter: `tone tone-off wave
  volume beep`, constants `sine square triangle sawtooth`.
- **Pins 42..47**: the shield's SCL and SDA and the SPI header's MISO, MOSI, SCK, SS are now
  pins too (`pin-scl` … `pin-ss`), usable as GPIO. A **pin router** gives peripherals their
  pins; the kernel records the owner of each pin (`owner`) and refuses a pin that is taken
  (` pin taken`), PWM included.
- Firmware 3.1: the `board` answer's `fn` line and HASE function 0x49 report the pin
  functions; the app's board view shows the six new pins and labels pins a peripheral owns.
- I/O decoding widened to 256 registers; the new blocks live at `$100200..$1002AC`.

## 3.0 — 2026-11-03

Started from ZYNQ-FORTH 2.3.

- **HF32 CPU**: 32-bit cells and 32-bit instructions in the same J1-style classes, 128 KB of
  RAM (was 16 KB), 15-bit cell-address program counter, 32-entry data, return and float
  stacks, arithmetic right shift. One instruction per clock at 50 MHz.
- **Floating point** in hardware (`rtl/hf32_mcu.v`): IEEE single precision, round to
  nearest even, subnormals flushed to zero, one quiet NaN; add, subtract, multiply, divide,
  square root, int↔float conversion and truncation, plus compares and sign operations in the
  ALU. The 32 × 32 multiply moved into the same multi-cycle unit (3 clocks). A bit-exact
  Python model (`tools/hf32.py`) is checked against IEEE (`tools/test_fpu.py`) and the RTL
  against the model (`sim/run_mcu.ps1`).
- **Kernel**: all words of ZYNQ-FORTH 2.3 with the same names and stack effects, now on
  32-bit cells (durations and periods stay double cells, where a double `lo hi` means
  `lo + hi*65536`, so 16-bit sources keep working), plus `us@` (a microsecond counter),
  `arshift`, `s>d`, `dnegate`, `fill`; the floating-point words: float literals,
  `f@ f! fconstant fvariable fliteral`, stack words, arithmetic, compares, `floor fround
  ftrunc`, `s>f f>s d>f f>d`, `>float represent precision set-precision f. fs. fe. f.s`,
  `pi fsin fcos fsincos ftan fasin facos fatan fatan2 fexp fln flog falog f** fsinh fcosh
  ftanh flnp1 fexpm1`, and `volts@ ftemp@`. Number conversion in both directions is correctly
  rounded; the functions are within about 2 ulp.
- **I/O map**: register k at `$100000 + 4k` (was `$8000 + 2k`); the ms counter is 32 bits.
- **Firmware 3.0, protocol 2**: `stack` answers 32-bit cells and a second line with the float
  stack; `words` addresses have five hex digits; `version` adds `cell 32` and `float 32`.
  The saved source has its own flash sector (0xFE0000, magic `HF32`), so the 16-bit one at
  0xFF0000 survives.
- **HASE**: still the Forth-Lab MCNF node (type AE.07.30.80, reports 3.0) with the 16-bit
  node's functions, so the HASE Forth-Lab panel works unchanged (stack cells clipped to
  16 bits there); new functions 0x45 (data stack, 32 bits), 0x46 (float stack), 0x47 and
  0x48 (dictionary with 32-bit addresses).
- **App 3.0** (`ZynqForth32.exe`, product ZYNQ-FPGA-FORTH32): the stack panel shows 32-bit
  cells and a float stack list; settings in `%LocalAppData%\ZYNQ-FPGA-FORTH32`.
