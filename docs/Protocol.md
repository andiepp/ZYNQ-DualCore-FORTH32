# ZYNQ-DualCore-FORTH32 serial protocol

Protocol version 2, firmware 3.1; the dual-core additions (protocol 3, firmware 4.0) are in "Two cores" below. Protocol 2 is protocol 1 of the 16-bit ZYNQ-FORTH with
32-bit cells: the `stack` answer carries 32-bit items and the float stack, and the `words`
addresses have five hex digits. Everything else is unchanged.

The board's USB serial port (the Arty Z7's FTDI channel B, 115200 baud, 8N1, no handshake)
carries two things at once:

- **Forth's terminal**, as plain bytes in both directions. A terminal program such as PuTTY
  or Tera Term talks to Forth directly: type a line, press Enter (CR), and Forth answers.
- **Service requests** from the ZYNQ-DualCore-FORTH32 app (or your own program): version, status,
  the dictionary, the data and float stacks, the board's I/O state and the source saved in flash. They are
  set apart by the byte SOH (0x01), which Forth never needs.

The ARM core answers service requests itself, while Forth keeps running: a request never
waits for Forth, and it works even while a Forth word loops for ever.

The same port also serves the **HASE laboratory**, whose host speaks
MCNF; the board switches by itself (see "HASE mode" at the end).

## Terminal

| Direction | Bytes |
|---|---|
| PC → board | Every byte except SOH (0x01) and Ctrl-R (0x12) goes to Forth's input. Lines end with CR. Up to 64 KB wait in the ARM's input ring while Forth is busy; more is lost. |
| PC → board | **Ctrl-R** (0x12) reloads the kernel and restarts Forth (with the saved source, if autostart is on): the way out of an endless loop from a terminal program. |
| board → PC | Forth's output. Forth echoes what it reads and ends lines with CR LF. A 0x01 that Forth prints itself (`1 emit`) is sent doubled, 0x01 0x01. |

At every start the ARM prints a line before Forth's banner:

```
[zynq-dual-forth32] 4.0, core 0, kernel 6219 words loaded and verified
[zynq-dual-forth32] autostart: 195 bytes of saved source
```

## Requests and answers

A request is SOH, one line of ASCII text, LF:

```
01 "status" 0A
```

Words are separated by single spaces. `store` is followed by a payload of the stated length.
Send the next request only after the answer to the previous one; terminal bytes may be sent
at any time between requests.

An answer is SOH, a header line ending in LF and, for `ok`, a payload:

```
01 "ok <request> <length>" 0A <length bytes>
01 "err <request> <reason>" 0A
```

The answer is never mixed into Forth's output: it comes between two bytes of it. A reader
splits the stream like this:

1. A byte other than SOH is terminal output.
2. SOH SOH is the terminal byte 0x01.
3. SOH followed by anything else starts an answer: read the header line up to LF; if it
   starts with `ok`, read the payload of the given length.

A request that is not completed within 2 seconds (a missing LF, a short payload) is
dropped; an unfinished `store` answers `err store timeout`.

## Requests

Text payloads are lines ending in LF. Numbers are decimal unless they are shown as hex.

| Request | Payload of the `ok` answer | Refusals |
|---|---|---|
| `echo <word>` | the word | – |
| `version` | `firmware zynq-dual-forth32 4.0`, `protocol 3` (single-core firmware: `zynq-forth32 3.x`, `protocol 2`), `kernel <cells> <checksum hex>` (the kernel image's size in 32-bit cells and the low 16 bits of the sum of its cells), `cell 32`, `float 32` | – |
| `status` | see below | – |
| `restart` | empty; reloads and verifies the kernel and starts Forth, which then prints its banner and runs the saved source if autostart is on | `verify`: the image read back wrong, the CPU stays in reset |
| `restart skip` | the same without the saved source | `verify` |
| `words` | the dictionary, see below | – |
| `stack` | the data and float stacks as they were at the last prompt, see below | `busy`: Forth was copying them; ask again |
| `board` | the board's I/O state, see below | – |
| `source` | the saved source, exactly as stored (lines end in CR) | `none`, `damaged` |
| `store <length> <crc32 hex> on\|off` + payload | empty; saves the payload in flash with the autostart flag. The CRC is CRC-32 as zlib computes it (`CBF43926` for `123456789`). Takes up to about 3 s. | `args`, `length` (more than 65,520 bytes), `crc`, `flash`, `timeout` |
| `erase` | empty; erases the saved source | `flash` |
| `autostart on\|off` | empty; changes the flag of the saved source | `args`, `none`, `flash` |

Any other request is answered `err <request> unknown`.

### status

One `key value` per line:

```
state running        running, or held (the kernel failed its check)
pc 02BC              the HF32 program counter (hex, cell address)
input 0              bytes waiting for Forth: input ring plus the rest of the saved source
starts 1             starts since power-up (power-up, restarts, Ctrl-R)
source stored        none, stored or damaged (its CRC does not match)
length 195           the saved source's length in bytes (0 unless stored)
crc AA4BEAA3         its CRC-32 (hex)
autostart on         on or off
last fed             the last start: fed (saved source ran), skipped (BTN3 or restart skip), none
```

### words

The first line is `here XXXXX`, the next free byte of the dictionary in hex. Then one line
per word, newest first: the code address in hex (five digits), the flags and the name.

```
here 04E64
04E50 - hello
```

Flags are `-` (none) or letters: `i` immediate, `h` hidden (being defined), `n` inline. The
ARM pauses the HF32 for the few microseconds the walk takes.

### stack

Two lines. The first: the data stack's depth, then each item as eight hex digits, bottom
first. The second: `f`, the float stack's depth, then each float's IEEE single bits as eight
hex digits, bottom first.

```
3 00000001 FFFFFFFE 000186A0      1 -2 100000, with 100000 on top
f 2 3F800000 40490FDB             1.0 and 3.141593, with 3.141593 on top
```

Forth's `quit` copies both stacks before it reads each line, so this is the state at the
last ` ok`, the same `.s` and `f.s` would have shown there. At most 20 items each.

### board

Raw register values in hex; the layout is in [design.md](design.md#61-axi-lite-registers-arm-side).

```
board 00120115                LEDs, RGB LEDs, buttons, switches
ports 2000FFFB 08000000 00000000
pwm 00002C02
xadc A11D 56ED 998F 0000 …    32 XADC status registers
pg 00030001 FFFF0001          pattern generator (firmware 2.2 and later)
fn 801A 801B 0000 …           14 pin functions (firmware 3.1 and later)
```

- `board`: bits 3..0 = LD3..LD0, bits 9..4 = RGB (bits 4/5/6 = LD4 red/green/blue,
  7/8/9 = LD5 red/green/blue), bits 19..16 = BTN3..BTN0, bits 21..20 = SW1..SW0.
- `ports`: three words for pins 0–15, 16–31 and 32–47. Bits 15..0 are the pin levels as read
  at the pins, bits 31..16 say which pins are driven (an output, or a PWM channel's pin).
  Pin numbers as in Forth: 0–13 = IO0–IO13, 14–19 = A0–A5, 26–41 = IO26–IO41.
- `pwm`: bits 3..0 = channels 3..0 enabled, then six bits per channel with its pin number
  (channel c at bits 4+6c..9+6c).
- `xadc`: the XADC status registers 0x00–0x1F; the result is in bits 15..4. Temperature
  (register 0) in °C = code × 503.975 / 4096 − 273.15; supplies (1, 2, 6, 0x0D–0x0F) in volts
  = code × 3 / 4096; A0–A5 = registers 0x11, 0x19, 0x16, 0x1F, 0x15, 0x1D with 3.32 V full
  scale; A6/A7, A8/A9, A10/A11 = 0x1C, 0x10, 0x18 with 1 V full scale.
- `pg`: the pattern generator ([PatternGenerator.md](PatternGenerator.md)). First word: bits
  27..16 = the current step, bits 6..0 = status (0 running, 1 waiting for the trigger, 2 ended,
  3 a pattern write was ignored, 4 a step ran late, 5 loops nested too deep, 6 busy). Second
  word: bits 31..16 = channel enable mask, bits 15..0 = current output levels (channel n = bit
  n; 0–7 on Pmod JA, 8–15 on JB). Older firmware sends no `pg` line; clients ignore lines they
  do not know.
- `fn`: the pin functions of the serial interfaces, the DDS and the tone generator, in this
  order: UART0 TX, UART0 RX, UART1 TX, UART1 RX, SPI0 SCK, SPI0 MOSI, SPI0 MISO, SPI1 SCK,
  SPI1 MOSI, SPI1 MISO, I2C SCL, I2C SDA, DDS, tone. Bit 15 = on, bits 5..0 = the pin (pins
  42..47 are SCL, SDA and the SPI header's MISO, MOSI, SCK, SS; the tone's 63 means the
  audio jack). The `ports` words include pins 42..47 in bits 10..15 of the third word.

## Two cores (protocol 3)

> **ZYNQ-DualCore-FORTH32 4.0** (firmware `zynq-dual-forth32 4.0`, `sw/src/main.c`). The app
> implements it, and so does its built-in simulated board (port `SIM`). Everything above
> stays valid: a protocol 2 client, or a terminal program, sees core 0 as if it were the only
> one. On a single-core bitstream the firmware reports `cores 1` and runs core 0 only.

The board has two independent HF32 Forths, **core 0** and **core 1**. Each has its own RAM,
kernel, dictionary, stacks, input ring and saved source; they share the board's I/O. The one
serial line carries both terminals.

### What changes

| Item | Protocol 3 |
|---|---|
| `version` | `protocol 3` and a new line `cores 2`. A client that finds no `cores` line, or a protocol below 3, talks to a single-core board. |
| Requests about one Forth | `status`, `stack`, `words`, `restart [skip]`, `source`, `store …`, `erase` and `autostart on\|off` may end in a **core number**: `status 1`, `restart skip 1`, `store 195 AA4BEAA3 on 1`. Without one they go to core 0, exactly as in protocol 2. An unknown core is refused with `err <request> core`. The answer header names the request as before (`ok status 99`). |
| `board`, `echo`, `version` | One answer for the whole board; no core number. |
| `status` | Two more keys: `core n` and `mailbox n` (words waiting in this core's mailbox from the other core). |
| Saved sources | Core 0 keeps the flash sector at 0xFE0000 (the single-core firmware's, so its source carries over); core 1 has its own at 0xFD0000. |
| Ctrl-R | Restarts the core the input points at (see `input`). |

### Terminal input: `input <core>`

`input n` (answer `ok input 0`, empty) points the terminal input at core *n*: every terminal
byte after the answer goes to that core's input ring, until the next `input`. After power-up
the input points at core 0. A client sends `input` only when it changes cores; the app sends
it before the first line it types to a core after another core had the input.

### Terminal output: `mux on|off` and core markers

`mux off` (the state after power-up) sends only core 0's output, as a terminal program expects.
Core 1's output waits in a 4 KB ring in the ARM; when it is full, the oldest bytes are dropped.

`mux on` (answer `ok mux 0`) sends the output of both cores. Before a run of output from a
core other than the last one marked, the board sends a **core marker**:

```
01 "@1" 0A          the bytes that follow are core 1's output
01 "@0" 0A          and from here on core 0's again
```

After the answer to `mux on`, the first output carries a marker too, whichever core it
comes from, so a client never has to guess. Output held while multiplexing was off follows
the answer at once, each behind its marker. With both cores printing, the board changes
cores at the end of a line (or when a core has nothing more), so neither waits long.
After `mux off`, the output is core 0's, without markers. A marker never
appears inside an answer, and core output never between a marker and its LF. A reader
extends rule 3 of the stream splitting: a header line `@` plus one digit is a marker, not an
answer, and carries no payload.

`mux` lasts until `mux off` or the next power-up (restarting a core keeps it): a client switches it on after
every `version` it uses to connect. In HASE mode (below) the functions concern core 0, and
from firmware 4.1 the same functions plus 0x80 core 1.

### Example

```
PC:    01 "version" 0A
board: 01 "ok version …" 0A  "firmware zynq-dual-forth32 4.0" 0A … "cores 2" 0A
PC:    01 "mux on" 0A
board: 01 "ok mux 0" 0A  01 "@1" 0A  "[zynq-dual-forth32] 4.0, core 1, kernel …"
PC:    01 "input 1" 0A
board: 01 "ok input 0" 0A
PC:    "2 3 + ." 0D
board: "2 3 + . 5  ok" 0D 0A          still core 1: no marker needed
PC:    01 "stack 1" 0A
board: 01 "ok stack 6" 0A  "0" 0A "f 0" 0A
```

## HASE mode

The firmware is also the Forth node of the HASE laboratory
([andiepp/HASE](https://github.com/andiepp/HASE), instrument family Forth-Lab): the HASE
Runtime Host talks to it in **MCNF**, binary frames that each start with a byte `0xA_`
(`0xA1` connectivity test, `0xA4` node administration, `0xA5` device functions). A
terminal or the app never sends such a byte to Forth, which takes printable ASCII only, so
the board can tell the two apart:

| Situation | What the board does |
|---|---|
| After power-up | Terminal: banner, autostart and Forth's output go out as described above. |
| A byte `0xA_` arrives between two terminal requests | A **probe** starts: Forth's output is held back from now on. A connectivity test `0xA1` is answered with `0x21`. |
| A valid MCNF frame (checksum right, channel `0xA4` or `0xA5`) within 2 s | **HASE mode.** The board answers MCNF requests only. Forth's output waits in a 4 KB ring until the host fetches it; when nobody does, the oldest bytes are dropped (and counted). |
| An invalid frame, an unfinished one, or 2 s without a valid frame | Back to the terminal, nothing answered. Held output goes out. |
| In HASE mode, a terminal byte between two frames: printable ASCII, CR, LF, Tab, Backspace, SOH or Ctrl-R | Back to the terminal at once; the byte is handled as usual, and what Forth printed meanwhile goes out first. |

So whichever program holds the serial port decides the mode: the HASE host while it runs, a
terminal program or the app once it sends anything. The HASE host waits until the port has
been quiet for 200 ms before its first frame, which leaves Forth's start-up output to the
terminal. A stray `0xA1` typed into a terminal only shows a `!`.

In HASE mode the node has the type of the 16-bit Forth-Lab node, `AE.07.30.80`, and reports
its firmware as major.minor (4.2). Its frames and device functions are those of HASE-Lab's Forth-Lab family, so
today's Forth-Lab panel works with it unchanged: 0x15 (version), 0x30–0x33 (status, restart,
input, output), 0x40–0x42 (dictionary and data stack), 0x43 (the registers of the `board`
request, binary, 84 bytes), 0x44 (the pattern generator, the `pg` line's two words as u32,
8 bytes) and 0x50–0x55 (saved source). The saved source is the same flash sector the `store`
request writes.

Those functions carry 16-bit values where the 16-bit node did; the node clips what does not
fit: in 0x42 a cell outside −32768..32767 reads as the nearer limit, in 0x40/0x41 an address
above 0xFFFF reads 0xFFFF, and in 0x30 the program counter is the cell address (15 bits).
Four new functions give the full values (big-endian like the others):

| Function | Request parameters | Response payload |
|---|---|---|
| 0x45 data stack, 32 bits | – | depth (u8), then 20 cells as u32, bottom first, unused ones 0 (81 bytes; R = 83) |
| 0x46 float stack | – | depth (u8), then 20 floats as their IEEE single bits (u32), bottom first (81 bytes) |
| 0x47 dictionary snapshot, 32 bits | – | as 0x40: count (u16), then `latest` and `here` as u32 (10 bytes) |
| 0x48 dictionary page, 32 bits | first index (u16) | as 0x41, each entry's code address as u32: count (u8), then per entry xt (u32), flags (u8), length (u8), name; zero-padded to R − 2 |
| 0x49 pin functions (firmware 3.1) | – | the `fn` line's 14 entries as u16 (28 bytes; R = 30) |

0x45 and 0x46 refuse with 0x15 (busy) like 0x42. HASE-Lab's Forth-Lab family reads them from
firmware 3.0 on (ADR-0092, 2026-11-03): its panel shows the 32-bit data stack, the float stack
and five-digit dictionary addresses, and opens this project's manual. It reads 0x49 from
firmware 3.1 on (ADR-0093, 2026-11-04) and adds the `fn` line to its board text: the panel's
board view shows pins 42..47 and the pins the serial interfaces and the DDS own.

### Core 1 (firmware 4.1)

The functions above concern core 0. From firmware 4.1, each function that concerns one core
has a twin for core 1, its code plus 0x80, with the same parameters and answers:

| Core 0 | Core 1 | Function |
|---|---|---|
| 0x30–0x33 | 0xB0–0xB3 | status, restart, input, output |
| 0x40–0x42 | 0xC0–0xC2 | dictionary snapshot and page, data stack (16-bit values) |
| 0x45–0x48 | 0xC5–0xC8 | data stack (32 bits), float stack, dictionary snapshot and page (32-bit addresses) |
| 0x50–0x55 | 0xD0–0xD5 | saved source: info, write, commit, read, erase, autostart (core 1's sector, 0xFD0000) |

0x15 (version), 0x43 (board), 0x44 (pattern generator) and 0x49 (pin functions) concern the
whole board and have no twin. Each core has its own dictionary table, so a snapshot of one
core and pages of the other may interleave. The source functions share one staging buffer:
upload one core's source at a time. A node without core 1 (firmware 3.x or 4.0, or 4.1 on a
single-core bitstream) answers the twins with "unknown function". HASE-Lab's Forth-Lab family
uses them from firmware 4.1 (ADR-0094).

## Example in Python

`tools/zforth.py` is a complete client (it needs pyserial):

```
python tools/zforth.py -p COMx version status "send:2 3 + ." stack words
python tools/zforth.py -p COMx store:lights.fs:on restart wait:2
```

The reading side in a few lines:

```python
import serial
port = serial.Serial('COMx', 115200, timeout=2)     # the board's port
port.write(b'\x01status\n')
while port.read(1) != b'\x01':          # skip Forth's output
    pass
head = port.readline().decode().split()  # ['ok', 'status', '99']
print(port.read(int(head[2])).decode())
```
