#!/usr/bin/env python3
"""Types a file of Forth lines into the board's terminal, one after the other, and compares
each answer with the simulator's (tools/hf32.py). Lines whose answer depends on the real
board (temperature, voltages, timers) are reported but not compared when they contain one
of the --live words.

    python tools/board_session.py -p COMx sim/float.txt

Needs pyserial. Restart Forth first (Ctrl-R) if the session should start from a clean state.
"""

import argparse
import os
import sys
import time

import serial

sys.path.insert(0, os.path.dirname(__file__))
import hf32  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def board_answer(port, line, timeout=10.0):
    port.write(line.encode('ascii') + b'\r')
    text, end = b'', time.time() + timeout
    while time.time() < end:
        text += port.read(256)
        if text.endswith(b'\r\n') and (b' ok\r\n' in text or b'?' in text or text.count(b'\r\n') >= 1):
            time.sleep(0.05)
            text += port.read(4096)
            break
    return text.decode('ascii', 'replace').replace('\r', '').strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-p', '--port', required=True)
    ap.add_argument('file')
    ap.add_argument('--live', default='volts@,ftemp@,temp@,mv@,supply@,ms@,us@,.temp,adc@,xadc@')
    args = ap.parse_args()
    live = args.live.split(',')
    lines = [l for l in open(args.file, encoding='ascii').read().splitlines() if l.strip()]

    comp = hf32.Compiler()
    comp.compile(open(os.path.join(ROOT, 'forth', 'kernel.fs'), encoding='ascii').read())
    m = hf32.Machine(comp.mem)
    m.run(10 ** 8)

    port = serial.Serial(args.port, 115200, timeout=0.2)
    port.write(b'\x12')                         # restart Forth
    time.sleep(1.5)
    port.read(65536)
    same = differ = skipped = 0
    for line in lines:
        m.tx.clear()
        m.rx = bytearray((line + '\r').encode('ascii'))
        m.idle_reads = 0
        m.run(m.steps + 10 ** 8)
        want = m.tx.decode('ascii', 'replace').replace('\r', '').strip()
        got = board_answer(port, line)
        if any(w in line for w in live):
            skipped += 1
            print(f'live  | {got}')
        elif got == want:
            same += 1
            print(f'same  | {got}')
        else:
            differ += 1
            print(f'DIFF  | board: {got}\n      |   sim: {want}')
    print(f'{same} lines as in the simulator, {differ} different, {skipped} live readings')
    return 1 if differ else 0


if __name__ == '__main__':
    sys.exit(main())
