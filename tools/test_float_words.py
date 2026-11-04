#!/usr/bin/env python3
"""Runs the kernel's float words in the simulator (tools/hf32.py) against Python:

  - >FLOAT (the text interpreter's float literals) against correctly rounded singles
  - FS. against the exact decimal value of the single, rounded to PRECISION digits
  - the elementary functions against math, as a relative error

    python tools/test_float_words.py [-n 400]
"""

import argparse
import math
import os
import random
import struct
import sys
from decimal import Decimal, ROUND_HALF_EVEN, getcontext

sys.path.insert(0, os.path.dirname(__file__))
import hf32  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
getcontext().prec = 80


def run(comp, lines, steps=400_000_000):
    rx = ''.join(line + '\r' for line in lines).encode('ascii')
    m = hf32.Machine(comp.mem, rx)
    m.run(steps)
    return m.tx.decode('ascii', 'replace')


def answers(text, lines):
    """The output of each input line: what follows the echoed line, up to ' ok'."""
    out = []
    for got in text.split('\r\n'):
        if got.endswith(' ok') and len(out) < len(lines) and got.startswith(lines[len(out)]):
            out.append(got[len(lines[len(out)]) + 1:-3])
    return out


def f32(x):
    return struct.unpack('<f', struct.pack('<I', x))[0]


def expected_fs(bits, digits):
    v = Decimal(f32(bits))
    if v == 0:
        return '0.' + '0' * (digits - 1) + 'E0'
    sign = '-' if v < 0 else ''
    v = abs(v)
    e = v.adjusted()
    q = (v / Decimal(10) ** e).quantize(Decimal(1).scaleb(-(digits - 1)), ROUND_HALF_EVEN)
    if q >= 10:
        q = (q / 10).quantize(Decimal(1).scaleb(-(digits - 1)), ROUND_HALF_EVEN)
        e += 1
    s = f'{q:.{digits - 1}f}'
    if digits == 1:
        s = s + '.'
    return f'{sign}{s}E{e}'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-n', type=int, default=300)
    ap.add_argument('--seed', type=int, default=5)
    args = ap.parse_args()
    rng = random.Random(args.seed)
    comp = hf32.Compiler()
    with open(os.path.join(ROOT, 'forth', 'kernel.fs'), encoding='ascii') as f:
        comp.compile(f.read())
    bad = 0

    # --- >FLOAT in the normal range: correctly rounded -----------------------
    texts = []
    for _ in range(args.n):
        e = rng.randint(-10, 9) if rng.random() < 0.6 else rng.randint(-44, 30)
        digits = str(rng.randint(1, 999999999))
        point = rng.randint(0, len(digits))
        t = digits[:point] + '.' + digits[point:] + f'e{e}'
        texts.append(('-' if rng.random() < 0.3 else '') + t)
    texts += ['1.17549435e-38', '3.4028234e38', '3.4028235e38', '3.40282356e38', '3.40282357e38', '0.1', '.5', '1e', '-0.0', '16777217e',
              '0.000123456789', '9.99999999e9']
    lines = [f'{t} f>bits u.' for t in texts]
    got = answers(run(comp, lines), lines)
    fails = 0
    for t, g in zip(texts, got):
        want = hf32.parse_float(t)
        if g.strip() != str(want):
            fails += 1
            if fails <= 8:
                print(f'>float {t}: got {g.strip()} want {want} ({f32(want)!r})')
    print(f'>float: {len(texts)} literals, {fails} differ from correct rounding')
    bad += fails

    # --- FS. at 9 and 7 digits -----------------------------------------------
    for digits in (9, 7):
        vals = []
        for _ in range(args.n):
            e = rng.randint(94, 159) if rng.random() < 0.6 else rng.randint(1, 254)
            vals.append((rng.getrandbits(1) << 31) | (e << 23) | rng.getrandbits(23))
        vals += [0x3EAAAAAB, 0x3DCCCCCD, 0x3F800000, 0x4B189680, 0x501502F9]
        lines = [f'{digits} set-precision'] + [f'{v} bits>f fs.' for v in vals]
        got = answers(run(comp, lines), lines)[1:]
        fails = 0
        for v, g in zip(vals, got):
            want = expected_fs(v, digits)
            if g.strip() != want:
                fails += 1
                if fails <= 8:
                    print(f'fs. {digits} {v:08X} ({f32(v)!r}): got {g.strip()} want {want}')
        print(f'fs. {digits}: {len(vals)} values, {fails} differ from the exact rounding')
        bad += fails

    # --- elementary functions --------------------------------------------------
    funcs = [
        ('fsin', math.sin, lambda: rng.uniform(-20, 20)),
        ('fcos', math.cos, lambda: rng.uniform(-20, 20)),
        ('ftan', math.tan, lambda: rng.uniform(-1.5, 1.5)),
        ('fatan', math.atan, lambda: rng.uniform(-50, 50)),
        ('fasin', math.asin, lambda: rng.uniform(-1, 1)),
        ('facos', math.acos, lambda: rng.uniform(-1, 1)),
        ('fexp', math.exp, lambda: rng.uniform(-80, 80)),
        ('fln', math.log, lambda: math.exp(rng.uniform(-80, 80))),
        ('flog', math.log10, lambda: math.exp(rng.uniform(-80, 80))),
        ('fsqrt', math.sqrt, lambda: math.exp(rng.uniform(-80, 80))),
        ('ftanh', math.tanh, lambda: rng.uniform(-5, 5)),
        ('fsinh', math.sinh, lambda: rng.uniform(-5, 5)),
        ('flnp1', math.log1p, lambda: rng.choice([-1, 1]) * 10 ** rng.uniform(-9, 0)),
        ('fexpm1', math.expm1, lambda: rng.choice([-1, 1]) * 10 ** rng.uniform(-9, 1)),
        ('fcosh', math.cosh, lambda: rng.uniform(-5, 5)),
    ]
    for name, ref, gen in funcs:
        xs = [hf32.fraction_to_f32(__import__('fractions').Fraction(gen())) for _ in range(args.n // 3)]
        lines = [f'{x} bits>f {name} f>bits u.' for x in xs]
        got = answers(run(comp, lines), lines)
        worst, at = 0.0, None
        for x, g in zip(xs, got):
            r = f32(int(g.strip()))
            w = ref(f32(x))
            # error in units of the last place of the true result
            ulp = math.ldexp(1, math.frexp(w)[1] - 24) if w else 1e-45
            err = abs(r - w) / ulp
            if name in ('fsin', 'fcos', 'ftan') and abs(w) < 1e-3:
                err = abs(r - w) / math.ldexp(1, -24)   # absolute near zeros
            if err > worst:
                worst, at = err, (f32(x), r, w)
        limit = 4
        flag = '' if worst <= limit else '  <-- above limit'
        print(f'{name:6s}: {len(xs)} args, worst {worst:.2f} ulp at {at}{flag}')
        if worst > limit:
            bad += 1

    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
