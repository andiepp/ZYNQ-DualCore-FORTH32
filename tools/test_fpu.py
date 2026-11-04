#!/usr/bin/env python3
"""Checks the floating-point model in tools/hf32.py (the mirror of rtl/hf32_mcu.v)
against IEEE single precision, and writes test vectors for the RTL testbench.

    python tools/test_fpu.py [-n 200000] [--vectors build/sim/mcu_vectors.txt]

The reference rounds the exact double result to single (for + - * / and sqrt the double
is close enough that this gives the correctly rounded single), with this machine's rules
applied: subnormal inputs count as zero, results below 2^-126 after rounding become zero,
and every NaN is 0x7FC00000.
"""

import argparse
import math
import os
import random
import struct
import sys

sys.path.insert(0, os.path.dirname(__file__))
import hf32  # noqa: E402

M32 = 0xFFFFFFFF


def val(x):
    return struct.unpack('<f', struct.pack('<I', x))[0]


def bits(v):
    try:
        return struct.unpack('<I', struct.pack('<f', v))[0]
    except OverflowError:
        return 0xFF800000 if v < 0 else 0x7F800000


def ftz_in(x):
    return x & 0x80000000 if (x >> 23) & 0xFF == 0 else x


def ftz_out(x):
    if (x >> 23) & 0xFF == 0xFF and x & 0x7FFFFF:
        return hf32.QNAN
    if (x >> 23) & 0xFF == 0:
        return x & 0x80000000
    return x


def to_single(v):
    """Round a double to single with an unbounded exponent below, then flush."""
    if math.isnan(v):
        return hf32.QNAN
    if math.isinf(v) or v == 0:
        return bits(v)
    m, e = math.frexp(abs(v))                      # v = m * 2^e, m in [0.5, 1)
    mant = round(m * (1 << 24))                    # exact: m has 53 bits; banker's rounding
    if mant == 1 << 24:
        mant >>= 1
        e += 1
    be = e - 1 + 127
    s = 0x80000000 if v < 0 else 0
    if be >= 255:
        return s | 0x7F800000
    if be <= 0:
        return s
    return s | (be << 23) | (mant & 0x7FFFFF)


def reference(op, a, b):
    x, y = val(ftz_in(a)), val(ftz_in(b))
    try:
        if op == 'add':
            r = x + y
        elif op == 'sub':
            r = x - y
        elif op == 'mul':
            r = x * y
        elif op == 'div':
            if y == 0:
                r = math.nan if x == 0 or math.isnan(x) else math.copysign(math.inf, x) * math.copysign(1, y)
            else:
                r = x / y
        elif op == 'sqrt':
            r = math.nan if x < 0 else math.sqrt(x)
    except (OverflowError, ValueError):
        r = math.nan
    if op in ('add', 'sub') and r == 0 and not math.isnan(r):
        # exact zero: +0 unless both operands are negative zeros (after the sign flip)
        ys = -y if op == 'sub' else y
        neg = math.copysign(1, x) < 0 and math.copysign(1, ys) < 0
        return 0x80000000 if neg else 0
    if op == 'mul' and r == 0:
        return 0x80000000 if (math.copysign(1, x) < 0) != (math.copysign(1, y) < 0) else 0
    if op == 'sqrt' and x == 0:
        return ftz_in(a) & 0x80000000
    return to_single(r)


MODEL = {
    'add': lambda a, b: hf32.f_add(a, b),
    'sub': lambda a, b: hf32.f_add(a, b, sub=True),
    'mul': hf32.f_mul,
    'div': hf32.f_div,
    'sqrt': lambda a, b: hf32.f_sqrt(a),
}
RTL_OP = {'add': 2, 'sub': 3, 'mul': 4, 'div': 5, 'sqrt': 6, 'itof': 7, 'ftoi': 8,
          'trunc': 9, 'mullo': 0, 'mulhi': 1}

SPECIAL = [0x00000000, 0x80000000, 0x3F800000, 0xBF800000, 0x7F800000, 0xFF800000,
           0x7FC00000, 0x7F800001, 0x00000001, 0x807FFFFF, 0x00800000, 0x80800000,
           0x7F7FFFFF, 0xFF7FFFFF, 0x40000000, 0x3F000000, 0x4B000000, 0x4B7FFFFF,
           0x3EAAAAAB, 0x40490FDB, 0x4F000000, 0xCF000000, 0x4EFFFFFF, 0x5F000000]


def rand_float(rng):
    k = rng.random()
    if k < 0.05:
        return rng.choice(SPECIAL)
    if k < 0.15:                                   # near each other: cancellation
        return rng.getrandbits(32)
    e = rng.randint(64, 190) if k < 0.9 else rng.randint(1, 254)
    return (rng.getrandbits(1) << 31) | (e << 23) | rng.getrandbits(23)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-n', type=int, default=100000)
    ap.add_argument('--seed', type=int, default=32)
    ap.add_argument('--vectors', help='write RTL test vectors (op a b expected, hex)')
    ap.add_argument('--vector-count', type=int, default=4000)
    args = ap.parse_args()
    rng = random.Random(args.seed)
    bad = 0
    vectors = []

    for op in ('add', 'sub', 'mul', 'div', 'sqrt'):
        fails = 0
        for i in range(args.n):
            a = rand_float(rng)
            b = rand_float(rng)
            if op in ('add', 'sub') and rng.random() < 0.3:   # close magnitudes
                b = (a & 0xFF800000) ^ (rng.getrandbits(1) << 31) | rng.getrandbits(23)
            got = MODEL[op](a, b)
            want = reference(op, a, b)
            # near the underflow boundary the reference cannot see the unbounded rounding
            tiny = (want & 0x7FFFFFFF) <= 0x00800001 and (got & 0x7FFFFFFF) <= 0x00800001
            if got != want and not tiny:
                fails += 1
                if fails <= 5:
                    print(f'{op} {a:08X} {b:08X}: model {got:08X} reference {want:08X} '
                          f'({val(a)!r} {val(b)!r})')
            if i < args.vector_count:
                vectors.append((RTL_OP[op], a, b, got))
        print(f'{op:5s}: {args.n} cases, {fails} mismatches')
        bad += fails

    # conversions
    fails = 0
    for i in range(args.n):
        n = rng.choice([0, 1, M32, 0x80000000, 0x7FFFFFFF, 16777217, 0xFEFFFFFF]) \
            if i < 50 else rng.getrandbits(rng.randint(1, 32))
        if rng.random() < 0.5:
            n = (-n) & M32
        s = n - (1 << 32) if n >> 31 else n
        got, want = hf32.i_to_f(n), to_single(float(s))
        if got != want:
            fails += 1
            if fails <= 5:
                print(f'itof {n:08X}: model {got:08X} reference {want:08X}')
        if i < args.vector_count:
            vectors.append((RTL_OP['itof'], n, 0, got))

        x = rand_float(rng)
        v = val(ftz_in(x))
        if math.isnan(v):
            want = 0
        elif v >= 2 ** 31:
            want = 0x7FFFFFFF
        elif v < -2 ** 31:
            want = 0x80000000
        else:
            want = int(v) & M32
        got = hf32.f_to_i(x)
        if got != want:
            fails += 1
            if fails <= 5:
                print(f'ftoi {x:08X}: model {got:08X} reference {want:08X}')
        if i < args.vector_count:
            vectors.append((RTL_OP['ftoi'], x, 0, got))

        if math.isnan(v):
            want = hf32.QNAN
        elif math.isinf(v):
            want = x
        else:
            want = ftz_out(bits(math.copysign(float(math.trunc(v)), v)))
        got = hf32.f_trunc(x)
        if got != want:
            fails += 1
            if fails <= 5:
                print(f'trunc {x:08X}: model {got:08X} reference {want:08X}')
        if i < args.vector_count:
            vectors.append((RTL_OP['trunc'], x, 0, got))

        a, b = rng.getrandbits(32), rng.getrandbits(32)
        if i < args.vector_count:
            vectors.append((RTL_OP['mullo'], a, b, (a * b) & M32))
            vectors.append((RTL_OP['mulhi'], a, b, (a * b) >> 32))
    print(f'conv : {args.n} cases each, {fails} mismatches')
    bad += fails

    if args.vectors:
        os.makedirs(os.path.dirname(args.vectors) or '.', exist_ok=True)
        with open(args.vectors, 'w') as f:
            for op, a, b, r in vectors:
                f.write(f'{op:x} {a:08x} {b:08x} {r:08x}\n')
        print(f'{len(vectors)} vectors -> {args.vectors}')
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
