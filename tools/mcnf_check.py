#!/usr/bin/env python3
"""Talks to the board as a HASE host would (MCNF, docs/Protocol.md "HASE mode") and prints
the node's answers: type, version, status, both data stack views, the float stack and the
dictionary with 16- and 32-bit addresses. Typed Forth lines go in through function 0x32.

    python tools/mcnf_check.py -p COMx ["1 -2 100000 1.5e pi"]

Needs pyserial. Afterwards the board stays in HASE mode until a terminal byte arrives; the
script sends a CR at the end, which returns it to the terminal.
"""

import argparse
import struct
import sys
import time

import serial


def frame(channel, function, params=b'', r=2):
    body = bytes([channel, 2 + len(params), r, 0, function]) + params
    return body + bytes([(0xFF - sum(body)) & 0xFF])


def call(port, channel, function, params=b'', r=2):
    port.reset_input_buffer()
    port.write(frame(channel, function, params, r))
    reply = port.read(r)
    if len(reply) != r:
        raise IOError(f'function {function:#04x}: {len(reply)} of {r} bytes')
    if (0xFF - sum(reply[:-1])) & 0xFF != reply[-1]:
        raise IOError(f'function {function:#04x}: bad checksum')
    if reply[0]:
        raise IOError(f'function {function:#04x}: error {reply[0]:#04x}')
    return reply[1:-1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-p', '--port', required=True)
    ap.add_argument('line', nargs='?', default='1 -2 100000 -40000 1.5e pi 1e30')
    args = ap.parse_args()
    port = serial.Serial(args.port, 115200, timeout=2)
    time.sleep(0.3)
    port.reset_input_buffer()

    t = call(port, 0xA4, 220, r=6)
    print('node type', '.'.join(f'{b:02X}' for b in t))
    v = call(port, 0xA5, 0x15, r=8)
    print(f'firmware {v[0]}.{v[1]}, kernel {struct.unpack(">H", v[2:4])[0]} cells, '
          f'checksum {struct.unpack(">H", v[4:6])[0]:04X}')

    # a line for Forth, then fetch its output
    sent = call(port, 0xA5, 0x32, (args.line + '\r').encode(), r=3)
    time.sleep(1.0)
    out = b''
    for _ in range(20):
        chunk = call(port, 0xA5, 0x33, r=200)
        n = chunk[0]
        out += chunk[1:1 + n]
        if n == 0:
            break
    print(f'sent {sent[0]} bytes; Forth printed: {out.decode("ascii", "replace")!r}')

    s = call(port, 0xA5, 0x30, r=20)
    print(f'status: running {s[0]}, pc {struct.unpack(">H", s[1:3])[0]:04X}, '
          f'starts {struct.unpack(">H", s[11:13])[0]}')

    d16 = call(port, 0xA5, 0x42, r=43)
    print('0x42 data stack (16-bit view):', list(struct.unpack('>20h', d16[1:]))[:d16[0]])
    d32 = call(port, 0xA5, 0x45, r=83)
    print('0x45 data stack (32-bit):', list(struct.unpack('>20i', d32[1:]))[:d32[0]])
    f = call(port, 0xA5, 0x46, r=83)
    print('0x46 float stack:', [struct.unpack('<f', struct.pack('<I', x))[0]
                                for x in struct.unpack('>20I', f[1:])[:f[0]]])

    snap = call(port, 0xA5, 0x40, r=8)
    count, latest, here = struct.unpack('>HHH', snap)
    snap32 = call(port, 0xA5, 0x47, r=12)
    count32, latest32, here32 = struct.unpack('>HII', snap32)
    print(f'0x40 dictionary: {count} words, latest {latest:04X}, here {here:04X}')
    print(f'0x47 dictionary: {count32} words, latest {latest32:05X}, here {here32:05X}')
    for fn, wide in ((0x41, 0), (0x48, 2)):
        page = call(port, 0xA5, fn, b'\x00\x00', r=120)
        n, at, names = page[0], 1, []
        for _ in range(min(n, 4)):
            xt = int.from_bytes(page[at:at + 2 + wide], 'big')
            length = page[at + 3 + wide]
            names.append(f'{xt:05X} {page[at + 4 + wide:at + 4 + wide + length].decode()}')
            at += 4 + wide + length
        print(f'{fn:#04x} first entries:', ', '.join(names))

    port.write(b'\r')          # back to the terminal
    port.close()


if __name__ == '__main__':
    sys.exit(main())
