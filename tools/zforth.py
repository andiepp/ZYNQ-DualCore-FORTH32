#!/usr/bin/env python3
"""Bench tool for a ZYNQ-FORTH board: Forth terminal and service requests over the USB UART.

Examples:
  python tools/zforth.py -p COM17 version status
  python tools/zforth.py -p COM17 "send:2 3 + ."          # type a line, print Forth's answer
  python tools/zforth.py -p COM17 words stack board
  python tools/zforth.py -p COM17 store:sim/autostart.fs:on source restart
  python tools/zforth.py -p COM17 autostart:off erase "restart:skip"

Each argument is one action, run in order:
  version status words stack board source erase   service requests (docs/Protocol.md)
  restart | restart:skip                          reload the kernel (skip the autostart)
  autostart:on | autostart:off
  store:<file>[:on]                               save a source in flash (LF -> CR)
  send:<text>                                     a terminal line (CR appended), then
                                                  print what Forth answers within --wait s
  wait:<seconds>                                  print Forth's output for that long
  echo:<word>                                     resynchronisation check
Needs pyserial.
"""

import argparse
import sys
import time
import zlib

import serial

SOH = 0x01


class Link:
    """Splits the byte stream into Forth's terminal output and service answers."""

    def __init__(self, port, baud=115200):
        self.port = serial.Serial(port, baud, timeout=0.02)
        self.buffer = bytearray()
        self.terminal = bytearray()

    def close(self):
        self.port.close()

    def _next(self, deadline):
        """The next received byte, or None once the deadline has passed."""
        while not self.buffer:
            self.buffer += self.port.read(4096)
            if not self.buffer and time.monotonic() > deadline:
                return None
        b = self.buffer[0]
        del self.buffer[0]
        return b

    def _byte(self, deadline):
        b = self._next(deadline)
        if b is None:
            raise TimeoutError('no answer from the board')
        return b

    def _answer(self, deadline):
        """Reads after a SOH: a doubled SOH is Forth's own byte, else an answer."""
        first = self._byte(deadline)
        if first == SOH:
            self.terminal.append(SOH)
            return None
        head = bytearray([first])
        while head[-1:] != b'\n':
            head.append(self._byte(deadline))
        words = head.decode('ascii').split()
        if words[0] == 'ok':
            payload = bytes(self._byte(deadline) for _ in range(int(words[2])))
            return ('ok', words[1], payload)
        return ('err', words[1], ' '.join(words[2:]))

    def pump(self, seconds):
        """Collects terminal output for a while (answers arriving meanwhile are dropped)."""
        end = time.monotonic() + seconds
        while (b := self._next(end)) is not None:
            if b == SOH:
                self._answer(time.monotonic() + 5)
            else:
                self.terminal.append(b)

    def request(self, text, payload=b'', timeout=10.0):
        self.port.write(bytes([SOH]) + text.encode('ascii') + b'\n' + payload)
        deadline = time.monotonic() + timeout
        while True:
            b = self._byte(deadline)
            if b != SOH:
                self.terminal.append(b)
                continue
            answer = self._answer(deadline)
            if answer is not None:
                return answer

    def send(self, text):
        self.port.write(text.encode('ascii') + b'\r')

    def take_terminal(self):
        out = self.terminal.decode('ascii', 'replace')
        self.terminal.clear()
        return out


def show(answer):
    status, name, data = answer
    if status == 'err':
        print(f'[{name}] ERROR {data}')
        return False
    text = data.decode('ascii', 'replace') if isinstance(data, bytes) else data
    print(f'[{name}] ok, {len(data)} bytes' + (':\n' + text.rstrip('\n') if text else ''))
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('-p', '--port', default='COM17')
    ap.add_argument('-b', '--baud', type=int, default=115200)
    ap.add_argument('--wait', type=float, default=0.5, help='seconds to collect after send')
    ap.add_argument('actions', nargs='+')
    args = ap.parse_args()

    link = Link(args.port, args.baud)
    ok = True
    try:
        for action in args.actions:
            name, _, arg = action.partition(':')
            if name == 'send':
                link.send(arg)
                link.pump(args.wait)
                print(link.take_terminal(), end='')
                print()
            elif name == 'wait':
                link.pump(float(arg))
                print(link.take_terminal(), end='')
            elif name == 'store':
                path, auto = arg, ''
                if arg.endswith((':on', ':off')):
                    path, _, auto = arg.rpartition(':')
                text = open(path, 'rb').read().replace(b'\r\n', b'\n').replace(b'\n', b'\r')
                crc = zlib.crc32(text) & 0xFFFFFFFF
                ok &= show(link.request(f'store {len(text)} {crc:08X} {auto or "off"}', text,
                                        timeout=30))
            elif name in ('restart', 'autostart', 'echo'):
                ok &= show(link.request(f'{name} {arg}'.strip()))
            else:
                ok &= show(link.request(name))
            pending = link.take_terminal()
            if pending and name not in ('send', 'wait'):
                print(f'(terminal) {pending!r}')
    finally:
        link.close()
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
