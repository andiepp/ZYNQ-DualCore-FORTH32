# ZYNQ-DualCore-FORTH32

Two 32-bit interactive Forths with hardware floating point, each on its own HF32 CPU in the
FPGA of a Digilent **Arty Z7-20**, with a Windows app to program both.

ZYNQ-DualCore-FORTH32 4.0 continues [ZYNQ-FPGA-FORTH32](https://github.com/andiepp/ZYNQ-FPGA-FORTH32)
3.1 (one core) with a **second HF32 core** and a **hardware divider**. Each core runs a
Forth of its own; they share the board's I/O and work together through mailboxes, locks and
a shared memory. Sources written for 3.1, or for the 16-bit
[ZYNQ-FORTH](https://github.com/andiepp/ZYNQ-FORTH), run on either core. How it was built,
step by step: [docs/DualCore-Plan.md](docs/DualCore-Plan.md).

![The app in the Lab panel skin](docs/images/app-lab-panel.png)

- **Two HF32 cores**, 32-bit dual-stack CPUs in the Zynq's programmable logic whose
  instructions are Forth primitives: one instruction per clock at 50 MHz, 128 KB of RAM
  each, which the other core cannot reach.
- Per core a **floating-point unit** for IEEE single precision (round to nearest even) with
  its own **float stack** (`f+ f- f*` in 5–6 clocks, `f/ fsqrt` in 31), and a **divider**:
  `um/mod` and `u/mod` in about 20 clocks.
- **Working together**: a 32-cell mailbox in each direction (`send receive mail?`), eight
  locks (`lock try-lock unlock`) and 4 KB of shared memory (`shared`); `core#` tells a
  program where it runs. Pins and peripherals belong to the core that opened them, and
  restarting one core resets only what it held while the other keeps running.
- A **Forth kernel** of 430 words, written in Forth and cross-compiled on the PC: the
  interpreter and compiler, the Forth-2012 floating-point words (literals like `1.5e-3`,
  `f. fs. fe.`, `fsin fcos ftan fatan2 fasin facos fexp fln flog f** fsqrt`…), correctly
  rounded number conversion, the board's LEDs, RGB LEDs, buttons and switches, 36 shield
  pins, 4 PWM channels, 9 analog inputs through the XADC (also in volts as floats), and the
  pattern generator.
- **Serial interfaces on any pin**: 2 UARTs, 2 SPI masters (up to 12.5 MHz) and an I2C
  master (on the shield's SCL/SDA by default), with words like `uart-open uart-emit
  spi-xfer i2c@ i2c! i2c-scan`.
- A **DDS** for a square wave of any frequency on any pin (200 MHz, 0.05 Hz steps) and a
  **tone generator** on the board's audio jack (sine, square, triangle, sawtooth,
  click-free volume): `1e6 dds-hz 13 dds-pin`, `440e tone`.
- A **pattern generator**: 16 digital channels on the Pmod headers JA and JB, played in
  steps of 5 ns from its own 200 MHz clock; 4096 steps with repeats, jumps, waits for a
  pin, button or software trigger ([docs/PatternGenerator.md](docs/PatternGenerator.md)).
- The **ARM core** loads both kernels and carries both terminals over the USB serial port.
  Any terminal program (PuTTY, Tera Term) talks to core 0 directly; the app adds service
  requests and both cores' output on the same line ([docs/Protocol.md](docs/Protocol.md)).
- **HASE compatible**: the firmware is also the Forth node of the
  [HASE](https://github.com/andiepp/HASE) laboratory and switches to HASE's MCNF protocol by
  itself when a HASE host talks to it; the node serves core 0.
- One Forth source per core can be **saved in flash** and runs at every start of that core
  (hold BTN3 to skip it). Core 0 keeps the single-core firmware's sector, so its source
  carries over.
- The **app**: a Core 0 / Core 1 switch (Ctrl+1 / Ctrl+2) with an editor, terminal, data and
  float stack, dictionary and saved source per core; a pattern editor (timing diagram) and a
  live view of the board, shared; five skins: IDE dark, IDE light, Green phosphor, Amber and
  Lab panel. The port **SIM** is a simulated two-core board for trying the app without one.

| IDE dark | Green phosphor |
|---|---|
| ![IDE dark](docs/images/app-ide-dark.png) | ![Green phosphor](docs/images/app-green-phosphor.png) |
| **Amber** | **IDE light** |
| ![Amber](docs/images/app-amber.png) | ![IDE light](docs/images/app-ide-light.png) |

## Documentation

- [docs/Manual.md](docs/Manual.md) — the user manual: getting started, the app, the
  interpreter, every word, floating point, the two cores, examples, troubleshooting.
- [docs/Protocol.md](docs/Protocol.md) — the serial protocol (protocol 3 for two cores) and
  the HASE functions.
- [docs/design.md](docs/design.md), also as [docs/Implementation-Details.pdf](docs/Implementation-Details.pdf) — the design
  in detail: the HF32 CPU and its instruction set, the floating-point unit and divider, the
  two cores and their I/O bus, memory, I/O and register maps, the peripherals, the ARM
  program, the Forth kernel, tools and verification.
- [docs/PatternGenerator.md](docs/PatternGenerator.md) — the pattern generator's design.
- [docs/DualCore-Plan.md](docs/DualCore-Plan.md) — the steps from one core to two.

## Try it

```forth
2 3 + .                     \ 5
100000 100000 * .           \ 1410065408 (32-bit cells wrap)
1e 3e f/ f.                 \ 0.3333333
2e fsqrt f.                 \ 1.414214
pi 4e f/ fsin fs.           \ 7.071068E-1
: circle ( F: r -- area ) fdup f* pi f* ;   2.5e circle f.   \ 19.63495
0 volts@ f.                 \ voltage on A0 in volts
ftemp@ f.                   \ chip temperature in degrees C
5 led!                      \ LD0 and LD2 on
1000 0 pwm-hz  250 0 pwm-duty  13 0 pwm-pin   \ 1 kHz, 25 % on IO13
words
```

Both cores: on **Core 1** `: worker begin receive dup * send again ;  worker`, then on
**Core 0** `: ask send receive ;  7 ask .` prints 49.

More in [examples/](examples) and in chapter 6 of the manual.

### Pattern generator pinout

As the headers look on the board, 3.3 V and GND at the left:

```
          Pmod JA                               Pmod JB
 pin    6    5    4    3    2    1        6    5    4    3    2    1
      3V3  GND  CH3  CH2  CH1  CH0      3V3  GND  CH11 CH10 CH9  CH8
      3V3  GND  CH7  CH6  CH5  CH4      3V3  GND  CH15 CH14 CH13 CH12
 pin   12   11   10    9    8    7       12   11   10    9    8    7
```

3.3 V outputs, not short-circuit protected (the fast Pmods have no series resistors). A
1 MHz clock on channel 0:

```forth
pg-stop 1 pg-enable 0 pg-at  1 500 ns pg-step  0 500 ns 0 pg-jump  pg-start
```

## Repository

| Path | Content |
|---|---|
| `rtl/` | the HF32 CPU, its multiply, divide and floating-point unit, one core with its RAM (`hf32_node.v`), and the Forth system (Verilog): the two cores' I/O bus, mailboxes, locks, shared RAM, owner tables, FIFOs, I/O, shield pins and pin router, PWM, XADC scanner, pattern generator, UARTs, SPI, I2C, DDS, tone generator, AXI-Lite slave |
| `constr/pins.xdc` | the Arty Z7-20 pins |
| `hw/build_hw.tcl` | Vivado build: Zynq block design, bitstream, `.xsa` |
| `forth/kernel.fs` | the Forth kernel |
| `tools/hf32.py` | cross-compiler and instruction-set simulator (with bit-exact models of the FPU and the divider, and a two-core run) |
| `tools/test_fpu.py`, `tools/test_float_words.py` | checks of the FPU model against IEEE and of the kernel's float words |
| `sw/` | the ARM program (bare metal), build, JTAG run, boot image and flash scripts |
| `sim/` | RTL testbenches (`run_sim.ps1` system, `run_dual.ps1` both cores against the simulator, `run_regress.ps1` several inputs, `run_mcu.ps1` FPU and divider, `run_periph.ps1` serial interfaces/DDS/tone, `run_patgen.ps1`) and test inputs |
| `app/` | the Windows app (C#, WPF, .NET 10) with its tests |
| `tools/zforth.py` | a command-line client (pyserial) |
| `examples/` | Forth sources |

## Building

Needs AMD/Xilinx **Vivado and Vitis 2023.2** (the Arty Z7-20 board files are included in
that version), **Python 3** and the **.NET 10 SDK**. The Xilinx launchers are not on PATH;
call them by their full path, below through `$xilinx`, the folder Vivado and Vitis are
installed in. The PowerShell scripts find Vivado and Vitis themselves (`XILINX_VIVADO`,
`XILINX_VITIS`, or `\Xilinx\…\2023.2` on any drive; else pass `-Vivado` / `-Vitis`). From the
repository root:

```powershell
$xilinx = 'C:\Xilinx'      # where Vivado and Vitis 2023.2 are installed

# bitstream and hardware description: build\hw\forth.bit, forth.xsa
& "$xilinx\Vivado\2023.2\bin\vivado.bat" -mode batch -nojournal -nolog -source hw/build_hw.tcl

# kernel image and ARM program: build\sw\forth_app\Debug\forth_app.elf
& "$xilinx\Vitis\2023.2\bin\xsct.bat" sw/build_sw.tcl

# boot image: build\boot\BOOT.bin
.\sw\build_boot.ps1

# the app and its tests
dotnet build app\ZynqForth.slnx
dotnet test app\ZynqForth.slnx
```

To put it on the board:

- **Flash** (permanent): JP4 to JTAG, power on, `.\sw\program_flash.ps1`, then JP4 to QSPI
  and power-cycle. This replaces whatever firmware is in flash (ZYNQ-FPGA-FORTH32 3.x or the
  16-bit ZYNQ-FORTH); flash its BOOT.bin to go back. The saved sources are kept: each
  firmware has its own sectors, and 3.x's carries over as core 0's.
- **JTAG** (until power-off, for development): JP4 to JTAG, power on,
  `& "$xilinx\Vitis\2023.2\bin\xsct.bat" sw/run.tcl`.

A kernel change (`forth/kernel.fs`) needs only `sw/build_sw.tcl` and a new boot image, no new
bitstream. Test it first in the simulator:

```powershell
python tools/hf32.py run forth/kernel.fs -f sim/smoke.txt
python tools/hf32.py run forth/kernel.fs -f sim/mail0.txt --input-file1 sim/mail1.txt   # two cores
python tools/test_float_words.py
.\sim\run_sim.ps1 -InputFile sim\float.txt     # the same session on the RTL
.\sim\run_dual.ps1 -Input0 mail0 -Input1 mail1 # both cores on the RTL, each against the simulator
.\sim\run_mcu.ps1                              # the FPU and divider against their bit-exact model
```

`.\tools\Install-App.ps1` installs the released app (from `dist\publish`, or downloaded from
the GitHub release) for the current user and puts a **ZYNQ-DualCore-FORTH32** shortcut on the
desktop. A development build runs from
`app\src\ZynqForth\bin\Debug\net10.0-windows\ZynqDualForth32.exe` (`--connect SIM` for the
simulated board). It keeps its settings in `%LocalAppData%\ZYNQ-DualCore-FORTH32`, apart from
the single-core and 16-bit apps'. Its skins are generated from one colour table: edit
`app/tools/make_skins.py` and run it.

## License

MIT, see [LICENSE](LICENSE).
