#!/usr/bin/env python3
"""HF32 cross-compiler and instruction-set simulator.

    python tools/hf32.py build forth/kernel.fs -o build/forth
        writes build/forth.hex (for $readmemh), build/forth_image.h (for the ARM loader)
        and build/forth.map (symbol addresses)

    python tools/hf32.py run forth/kernel.fs [-i "2 3 + ."] [--steps N]
        compiles and runs the image in the simulator, feeding the input text as
        terminal keystrokes (a CR is sent after each line) and printing the output

The machine model and encodings are described in docs/design.md. The floating-point
functions below mirror rtl/hf32_mcu.v step by step, so the simulator and the RTL give
the same bits.
"""

import argparse
import os
import re
import sys
from fractions import Fraction

RAM_BYTES = 131072
IO_BASE = 0x100000
M32 = 0xFFFFFFFF

# ---------------------------------------------------------------------------
# Floating point (rtl/hf32_mcu.v)
# ---------------------------------------------------------------------------

QNAN = 0x7FC00000


def f_parts(x):
    e, f = (x >> 23) & 0xFF, x & 0x7FFFFF
    return (x >> 31, e, 0x800000 | f, e == 0, e == 0xFF and f == 0, e == 0xFF and f != 0)


def norm_round(s, e, m):
    """m * 2^(e - 127) / 2^48, m 50 bits with a sticky bit 0: normalize, round, pack."""
    if m == 0:
        return 0
    if m >> 49:
        m = ((m >> 2) << 1) | ((m >> 1 | m) & 1)
        e += 1
    else:
        lz = 48 - (m.bit_length() - 1)
        m = (m << lz) & ((1 << 50) - 1)
        e -= lz
    mant = m >> 25
    if (m >> 24) & 1 and ((m & 0xFFFFFF) or (mant & 1)):
        mant += 1
    if mant >> 24:
        e += 1
    if e >= 255:
        return (s << 31) | 0x7F800000
    if e <= 0:
        return s << 31
    return (s << 31) | (e << 23) | (mant & 0x7FFFFF)


def f_add(a, b, sub=False):
    sa, ea, ma, za, ia, na = f_parts(a)
    sb, eb, mb, zb, ib, nb = f_parts(b)
    sb ^= int(sub)
    if na or nb:
        return QNAN
    if ia and ib:
        return a if sa == sb else QNAN
    if ia:
        return a
    if ib:
        return (sb << 31) | (b & 0x7FFFFFFF)
    if za and zb:
        return (sa & sb) << 31
    if za:
        return (sb << 31) | (b & 0x7FFFFFFF)
    if zb:
        return a
    a_ge = (a & 0x7FFFFFFF) >= (b & 0x7FFFFFFF)
    s, e = (sa, ea) if a_ge else (sb, eb)
    big, small = (ma, mb) if a_ge else (mb, ma)
    d = abs(ea - eb)
    add_a, add_b = big << 25, small << 25
    if d >= 50:
        add_b = 1
    else:
        add_b = (add_b >> d) | (1 if add_b & ((1 << d) - 1) else 0)
    m = add_a - add_b if sa != sb else add_a + add_b
    return norm_round(s, e, m)


def f_mul(a, b):
    sa, ea, ma, za, ia, na = f_parts(a)
    sb, eb, mb, zb, ib, nb = f_parts(b)
    s = sa ^ sb
    if na or nb or (ia and zb) or (za and ib):
        return QNAN
    if ia or ib:
        return (s << 31) | 0x7F800000
    if za or zb:
        return s << 31
    return norm_round(s, ea + eb - 127, (ma * mb) << 2)


def f_div(a, b):
    sa, ea, ma, za, ia, na = f_parts(a)
    sb, eb, mb, zb, ib, nb = f_parts(b)
    s = sa ^ sb
    if na or nb or (ia and ib) or (za and zb):
        return QNAN
    if ia or zb:
        return (s << 31) | 0x7F800000
    if ib or za:
        return s << 31
    rem, q = ma, 0
    for _ in range(27):
        ge = rem >= mb
        sub = rem - mb if ge else rem
        q = ((q << 1) | ge) & ((1 << 27) - 1)
        rem = (sub & 0xFFFFFF) << 1
    return norm_round(s, ea - eb + 127, (q << 22) | (1 if sub else 0))


def f_sqrt(a):
    sa, ea, ma, za, ia, na = f_parts(a)
    if na:
        return QNAN
    if za:
        return sa << 31
    if sa:
        return QNAN
    if ia:
        return a
    rad = (ma << 29) if ea & 1 else (ma << 28)
    srem, q = 0, 0
    for _ in range(27):
        rem2 = (srem << 2) | ((rad >> 52) & 3)
        trial = (q << 2) | 1
        ge = rem2 >= trial
        sub = rem2 - trial if ge else rem2
        q = ((q << 1) | ge) & ((1 << 27) - 1)
        srem = sub & ((1 << 30) - 1)
        rad = (rad << 2) & ((1 << 54) - 1)
    return norm_round(0, (ea >> 1) + 64, (q << 22) | (1 if sub else 0))


def i_to_f(a):
    if a == 0:
        return 0
    s = a >> 31
    mag = (-a) & M32 if s else a
    return norm_round(s, 158, mag << 17)


def f_to_i(a):
    sa, ea, ma, za, ia, na = f_parts(a)
    if na or za or ea < 127:
        return 0
    if ea >= 158:
        return 0x80000000 if sa else 0x7FFFFFFF
    mag = ((ma << (ea - 127)) >> 23) & M32
    return (-mag) & M32 if sa else mag


def f_trunc(a):
    sa, ea, ma, za, ia, na = f_parts(a)
    if na:
        return QNAN
    if za or ea < 127:
        return sa << 31
    if ea >= 150:
        return a
    return a & ~((1 << (150 - ea)) - 1) & M32


def f_cmp(n, t):
    """(FN < FT, FN = FT, FT < 0, FT = 0) as the CPU's compare ops see them."""
    def key(x):
        nan = (x >> 23) & 0xFF == 0xFF and x & 0x7FFFFF
        mag = 0 if (x >> 23) & 0xFF == 0 else x & 0x7FFFFFFF
        return nan, bool(x >> 31) and mag != 0, mag
    tn, tneg, tmag = key(t)
    nn, nneg, nmag = key(n)
    ok = not tn and not nn
    if nneg != tneg:
        lt = nneg
    else:
        lt = nmag > tmag if nneg else nmag < tmag
    return ok and lt, ok and nneg == tneg and nmag == tmag, tneg and not tn, tmag == 0


def fraction_to_f32(v):
    """Correctly rounded single (nearest even), with this machine's flush to zero."""
    if v == 0:
        return 0
    s = 1 if v < 0 else 0
    v = abs(v)
    e = v.numerator.bit_length() - v.denominator.bit_length()
    if Fraction(2) ** e > v:
        e -= 1
    while Fraction(2) ** (e + 1) <= v:
        e += 1
    scaled = v / Fraction(2) ** (e - 23)          # in [2^23, 2^24)
    mant = scaled.numerator // scaled.denominator
    rest = scaled - mant
    if rest > Fraction(1, 2) or (rest == Fraction(1, 2) and mant & 1):
        mant += 1
    if mant >> 24:
        mant >>= 1
        e += 1
    be = e + 127
    if be >= 255:
        return (s << 31) | 0x7F800000
    if be <= 0:
        return s << 31
    return (s << 31) | (be << 23) | (mant & 0x7FFFFF)


def f32_value(x):
    """The value of single x as a Python float (inf and nan included)."""
    import struct
    return struct.unpack('<f', struct.pack('<I', x & M32))[0]


# ---------------------------------------------------------------------------
# Instruction encoding
# ---------------------------------------------------------------------------

OPS = {
    'T': 0, 'N': 1, 'N+T': 2, 'N&T': 3, 'N|T': 4, 'N^T': 5, '~T': 6, 'N=T': 7,
    'N<T': 8, 'Nu<T': 9, 'N>>T': 10, 'N<<T': 11, 'R': 12, '[T]': 13, 'c[T]': 14,
    'depth': 15, 'N-T': 16, 'T+1': 17, 'T-1': 18, 'T=0': 19, 'T<0': 20, 'N*T': 21,
    'T/2': 22, '-T': 23, 'N*Thi': 24, 'N>>>T': 25, 'FT': 26, 'FN<FT': 27, 'FN=FT': 28,
    'FT<0': 29, 'FT=0': 30, 'F>S': 31, 'fdepth': 32,
}
FOPS = {
    'FT': 0, 'FN': 1, 'T': 2, '[T]': 3, 'FN+FT': 4, 'FN-FT': 5, 'FN*FT': 6, 'FN/FT': 7,
    'sqrt': 8, 'float(T)': 9, '-FT': 10, '|FT|': 11, 'trunc': 12,
}
DELTA = {0: 0, 1: 1, -1: 3, -2: 2}

F_IMMEDIATE, F_HIDDEN, F_INLINE = 0x80, 0x40, 0x20


def alu(op, r2p=False, t2n=False, n2m=False, byte=False, rd=0, dd=0,
        f2m=False, ft2fn=False, fd=0, fop='FT'):
    return (0x60000000 | (r2p << 28) | (OPS[op] << 22) | (t2n << 21) | (n2m << 20)
            | (byte << 19) | (DELTA[rd] << 17) | (DELTA[dd] << 15) | (f2m << 14)
            | (ft2fn << 13) | (DELTA[fd] << 11) | (FOPS[fop] << 6))


EXIT = alu('T', r2p=True, rd=-1)
INVERT = alu('~T')
NOP = alu('T')
FDROP = alu('T', fop='FN', fd=-1)

PRIMS = {
    'dup':     [alu('T', dd=1)],
    'drop':    [alu('N', dd=-1)],
    'swap':    [alu('N', t2n=True)],
    'over':    [alu('N', dd=1)],
    'nip':     [alu('T', dd=-1)],
    '>r':      [alu('N', rd=1, dd=-1)],
    'r>':      [alu('R', rd=-1, dd=1)],
    'r@':      [alu('R', dd=1)],
    '+':       [alu('N+T', dd=-1)],
    '-':       [alu('N-T', dd=-1)],
    'and':     [alu('N&T', dd=-1)],
    'or':      [alu('N|T', dd=-1)],
    'xor':     [alu('N^T', dd=-1)],
    '=':       [alu('N=T', dd=-1)],
    '<':       [alu('N<T', dd=-1)],
    'u<':      [alu('Nu<T', dd=-1)],
    'rshift':  [alu('N>>T', dd=-1)],
    'lshift':  [alu('N<<T', dd=-1)],
    'arshift': [alu('N>>>T', dd=-1)],
    '*':       [alu('N*T', dd=-1)],
    '(um*)':   [alu('N*Thi', dd=-1)],     # high cell of the unsigned product
    'invert':  [alu('~T')],
    '1+':      [alu('T+1')],
    '1-':      [alu('T-1')],
    '0=':      [alu('T=0')],
    '0<':      [alu('T<0')],
    '2/':      [alu('T/2')],
    'negate':  [alu('-T')],
    '@':       [alu('[T]')],
    'c@':      [alu('c[T]')],
    # A store is always followed by an instruction that does not read memory
    # (store hazard, see design.md)
    '!':       [alu('N', n2m=True, dd=-1), alu('N', dd=-1)],
    'c!':      [alu('N', n2m=True, byte=True, dd=-1), alu('N', dd=-1)],
    'depth':   [alu('depth', dd=1)],
    'exit':    [EXIT],
    'nop':     [NOP],
    # float stack
    'fdup':    [alu('T', fop='FT', fd=1)],
    'fdrop':   [FDROP],
    'fswap':   [alu('T', fop='FN', ft2fn=True)],
    'fover':   [alu('T', fop='FN', fd=1)],
    'f+':      [alu('T', fop='FN+FT', fd=-1)],
    'f-':      [alu('T', fop='FN-FT', fd=-1)],
    'f*':      [alu('T', fop='FN*FT', fd=-1)],
    'f/':      [alu('T', fop='FN/FT', fd=-1)],
    'fsqrt':   [alu('T', fop='sqrt')],
    'fnegate': [alu('T', fop='-FT')],
    'fabs':    [alu('T', fop='|FT|')],
    'ftrunc':  [alu('T', fop='trunc')],
    's>f':     [alu('N', dd=-1, fop='float(T)', fd=1)],
    'f>s':     [alu('F>S', dd=1, fop='FN', fd=-1)],
    'f>bits':  [alu('FT', dd=1, fop='FN', fd=-1)],
    'bits>f':  [alu('N', dd=-1, fop='T', fd=1)],
    'f@':      [alu('N', dd=-1, fop='[T]', fd=1)],
    'f!':      [alu('N', f2m=True, dd=-1, fop='FN', fd=-1), NOP],
    'f0<':     [alu('FT<0', dd=1, fop='FN', fd=-1)],
    'f0=':     [alu('FT=0', dd=1, fop='FN', fd=-1)],
    'f<':      [alu('FN<FT', dd=1, fop='FN', fd=-1), FDROP],
    'f=':      [alu('FN=FT', dd=1, fop='FN', fd=-1), FDROP],
    'fdepth':  [alu('fdepth', dd=1)],
}


def literal(n):
    n &= M32
    if n < 0x80000000:
        return [0x80000000 | n]
    return [0x80000000 | (~n & 0x7FFFFFFF), INVERT]


FLOAT_RE = re.compile(r'([+-]?)(\d+\.?\d*|\.\d+)(?:[eE]([+-]?\d*))?')


def parse_float(tok):
    """Bits of a float literal (digits with a '.' or an exponent), else None."""
    m = FLOAT_RE.fullmatch(tok)
    if not m or ('.' not in tok and 'e' not in tok.lower()):
        return None
    digits = m.group(2)
    value = Fraction(digits if not digits.endswith('.') else digits[:-1] or '0')
    exp = m.group(3)
    if exp not in (None, '', '+', '-'):
        value *= Fraction(10) ** int(exp)
    if m.group(1) == '-':
        return fraction_to_f32(-value) if value else 0x80000000
    return fraction_to_f32(value)


# ---------------------------------------------------------------------------
# Cross-compiler
# ---------------------------------------------------------------------------

class CompileError(Exception):
    pass


class Compiler:
    def __init__(self):
        self.mem = bytearray(RAM_BYTES)
        self.dp = 0
        self.latest = 0            # header address of the newest word
        self.words = {}            # lower-case name -> dict(xt, header)
        self.stack = []            # host data stack (interpret mode)
        self.fstack = []           # host float stack (bits)
        self.cstack = []           # control-flow stack (compile mode)
        self.targets = set()       # byte addresses that are branch targets
        self.fixups = []           # (cell address, name, line) for forward calls
        self.current = None        # word being compiled
        self.last_call = None      # address of the last emitted call
        self.src = ''
        self.pos = 0
        self.line = 1

    # --- memory ---------------------------------------------------------
    def c_comma(self, b):
        if self.dp >= RAM_BYTES:
            raise CompileError('image larger than RAM')
        self.mem[self.dp] = b & 0xFF
        self.dp += 1

    def align(self):
        while self.dp & 3:
            self.c_comma(0)

    def comma(self, w):
        self.align()
        for k in range(4):
            self.c_comma(w >> (8 * k))

    def cell(self, addr):
        return int.from_bytes(self.mem[addr:addr + 4], 'little')

    def set_cell(self, addr, w):
        self.mem[addr:addr + 4] = (w & M32).to_bytes(4, 'little')

    def emit(self, insns):
        for w in insns:
            self.last_call = None
            self.comma(w)

    def emit_call(self, xt):
        self.comma(0x40000000 | (xt >> 2))
        self.last_call = self.dp - 4

    # --- source scanning ------------------------------------------------
    def token(self):
        s = self.src
        while self.pos < len(s) and s[self.pos].isspace():
            if s[self.pos] == '\n':
                self.line += 1
            self.pos += 1
        start = self.pos
        while self.pos < len(s) and not s[self.pos].isspace():
            self.pos += 1
        return s[start:self.pos] if self.pos > start else None

    def parse(self, delim):
        """Text up to delim (like Forth PARSE); skips one leading blank."""
        if self.pos < len(self.src) and self.src[self.pos] in ' \t':
            self.pos += 1
        end = self.src.find(delim, self.pos)
        if end < 0:
            raise CompileError(f'missing {delim!r}')
        text = self.src[self.pos:end]
        self.line += text.count('\n')
        self.pos = end + 1
        return text

    def need(self, what):
        t = self.token()
        if t is None:
            raise CompileError(f'{what} expected')
        return t

    # --- dictionary -----------------------------------------------------
    def header(self, name, flags=0):
        if len(name) > 31:
            raise CompileError(f'name too long: {name}')
        self.align()
        h = self.dp
        self.comma(self.latest)
        self.c_comma(len(name) | flags)
        for ch in name.encode('ascii'):
            self.c_comma(ch)
        self.align()
        self.latest = h
        xt = self.dp
        self.words[name.lower()] = {'xt': xt, 'header': h, 'name': name}
        return xt

    def lookup(self, name):
        return self.words.get(name.lower())

    @staticmethod
    def number(tok):
        m = re.fullmatch(r'(-?)(\$[0-9a-fA-F]+|[0-9]+)', tok)
        if not m:
            return None
        digits = m.group(2)
        val = int(digits[1:], 16) if digits.startswith('$') else int(digits)
        return -val if m.group(1) else val

    # --- compile mode ---------------------------------------------------
    def mark_target(self):
        self.targets.add(self.dp)

    def finish_definition(self):
        inline = self.current['inline']
        here = self.dp
        if not inline and here not in self.targets and here > self.current['xt']:
            last = self.cell(here - 4)
            if self.last_call == here - 4:
                # tail call: call -> jump
                self.set_cell(here - 4, last & 0x1FFFFFFF)
                self.last_call = None
                return
            if (last & 0xE0000000) == 0x60000000 and not (last & 0x10000000) \
                    and (last & 0x00060000) == 0:
                self.set_cell(here - 4, last | 0x10000000 | (DELTA[-1] << 17))
                return
        self.emit([EXIT])

    def compile_token(self, tok):
        low = tok.lower()
        cs = self.cstack

        if low == ';':
            if cs:
                raise CompileError(f'unbalanced control structure in {self.current["name"]}')
            self.finish_definition()
            self.current = None
        elif low in ('\\', '('):
            self.comment(low)
        elif low == 'if':
            cs.append(('orig', self.dp))
            self.emit([0x20000000])
        elif low == 'else':
            kind, orig = cs.pop()
            cs.append(('orig', self.dp))
            self.emit([0x00000000])
            self.resolve(orig)
        elif low == 'then':
            kind, orig = cs.pop()
            self.resolve(orig)
        elif low == 'begin':
            self.mark_target()
            cs.append(('dest', self.dp))
        elif low == 'until':
            kind, dest = cs.pop()
            self.emit([0x20000000 | (dest >> 2)])
        elif low == 'again':
            kind, dest = cs.pop()
            self.emit([dest >> 2])
        elif low == 'while':
            dest = cs.pop()
            cs.append(('orig', self.dp))
            cs.append(dest)
            self.emit([0x20000000])
        elif low == 'repeat':
            kind, dest = cs.pop()
            self.emit([dest >> 2])
            kind, orig = cs.pop()
            self.resolve(orig)
        elif low == 'do':
            self.emit(PRIMS['swap'] + PRIMS['>r'] + PRIMS['>r'])
            self.mark_target()
            cs.append(('do', self.dp))
        elif low in ('loop', '+loop'):
            kind, dest = cs.pop()
            self.call_word('(loop)' if low == 'loop' else '(+loop)')
            self.emit([0x20000000 | (dest >> 2)])
            self.emit(PRIMS['r>'] + PRIMS['drop'] + PRIMS['r>'] + PRIMS['drop'])
        elif low == 'i':
            self.emit(PRIMS['r@'])
        elif low == 'unloop':
            self.emit(PRIMS['r>'] + PRIMS['drop'] + PRIMS['r>'] + PRIMS['drop'])
        elif low == 'recurse':
            self.emit_call(self.current['xt'])
        elif low == '."':
            text = self.parse('"')
            self.call_word('(.")')
            self.c_comma(len(text))
            for ch in text.encode('ascii'):
                self.c_comma(ch)
            self.align()
        elif low == '[char]':
            self.emit(literal(ord(self.need('character'))))
        elif low == "[']":
            name = self.need('name')
            w = self.lookup(name)
            if not w:
                raise CompileError(f"['] of unknown word {name}")
            self.emit(literal(w['xt']))
        elif low == '[op]':
            name = self.need('primitive').lower()
            if name not in PRIMS:
                raise CompileError(f'[op] of non-primitive {name}')
            self.emit(literal(PRIMS[name][0]))
        elif low in PRIMS:
            self.emit(PRIMS[low])
        elif self.number(tok) is not None:
            self.emit(literal(self.number(tok)))
        elif parse_float(tok) is not None:
            self.emit(literal(parse_float(tok)) + PRIMS['bits>f'])
        else:
            self.call_word(tok)

    def resolve(self, orig):
        self.set_cell(orig, self.cell(orig) | (self.dp >> 2))
        self.mark_target()

    def call_word(self, name):
        w = self.lookup(name)
        if w:
            self.emit_call(w['xt'])
        else:
            self.fixups.append((self.dp, name, self.line))
            self.emit_call(0)

    def comment(self, low):
        if low == '\\':
            end = self.src.find('\n', self.pos)
            self.pos = len(self.src) if end < 0 else end
        else:
            self.parse(')')

    # --- interpret mode -------------------------------------------------
    def interpret_token(self, tok):
        low = tok.lower()
        st = self.stack
        if low in (':', ':inline'):
            name = self.need('name')
            flags = F_INLINE if low == ':inline' else 0
            xt = self.header(name, flags)
            self.current = {'name': name, 'xt': xt, 'inline': bool(flags)}
            self.last_call = None
        elif low in ('\\', '('):
            self.comment(low)
        elif low == 'immediate':
            self.mem[self.latest + 4] |= F_IMMEDIATE
        elif low in ('variable', 'create', 'fvariable'):
            xt = self.header(self.need('name'))
            self.emit(literal(xt + 8) + [EXIT])
            if low != 'create':
                self.comma(0)
        elif low == 'constant':
            self.header(self.need('name'))
            self.emit(literal(st.pop()) + [EXIT])
        elif low == 'fconstant':
            self.header(self.need('name'))
            self.emit(literal(self.fstack.pop()) + PRIMS['bits>f'] + [EXIT])
        elif low == 'allot':
            for _ in range(st.pop()):
                self.c_comma(0)
        elif low == ',':
            self.comma(st.pop())
        elif low == 'f,':
            self.comma(self.fstack.pop())
        elif low == 'c,':
            self.c_comma(st.pop())
        elif self.number(tok) is not None:
            st.append(self.number(tok))
        elif parse_float(tok) is not None:
            self.fstack.append(parse_float(tok))
        else:
            raise CompileError(f'unknown word outside a definition: {tok}')

    # --- driver ---------------------------------------------------------
    def compile(self, src):
        self.src, self.pos, self.line = src, 0, 1
        # Reset vector: jump to COLD, patched at the end
        self.emit([0x00000000])
        while True:
            tok = self.token()
            if tok is None:
                break
            try:
                if self.current:
                    self.compile_token(tok)
                else:
                    self.interpret_token(tok)
            except (CompileError, IndexError) as e:
                raise CompileError(f'line {self.line}: {tok}: {e}') from None
        if self.current:
            raise CompileError(f'unterminated definition {self.current["name"]}')

        for addr, name, line in self.fixups:
            w = self.lookup(name)
            if not w:
                raise CompileError(f'line {line}: undefined word {name}')
            self.set_cell(addr, self.cell(addr) | (w['xt'] >> 2))

        cold = self.lookup('cold')
        if not cold:
            raise CompileError('no COLD word')
        self.set_cell(0, cold['xt'] >> 2)

        # Initial values of the dictionary pointers
        self.align()
        for var, value in (('dp', self.dp), ('latest', self.latest)):
            w = self.lookup(var)
            if not w:
                raise CompileError(f'kernel must define variable {var}')
            self.set_cell(w['xt'] + 8, value)
        return self.dp


# ---------------------------------------------------------------------------
# Instruction-set simulator (mirrors rtl/hf32_cpu.v)
# ---------------------------------------------------------------------------

# Shield pins 0..19, 26..41 and 42..47 (SCL, SDA, the SPI header); IO pins have pull-ups,
# A0..A5 (14..19) read low
PIN_EXISTS = 0xFFFF_FC0F_FFFF
PIN_IDLE = 0xFFFF_FC00_3FFF

# Simulated XADC results (12-bit codes by status register), the same values as
# sim/xadc_stim.txt: 45 C, VCCINT 1.0 V, VCCAUX 1.8 V, VCCBRAM 1.0 V, VCCPINT 1.0 V,
# VCCPAUX 1.8 V, VCCO_DDR 1.5 V; A0 = 1.65 V, A1 = 3.3 V at the shield (0.497 V and
# 0.994 V after the divider), A6/A7 = 0.25 V.
XADC_SIM = {0x00: 2585, 0x01: 1365, 0x02: 2458, 0x06: 1365, 0x0D: 1365, 0x0E: 2458,
            0x0F: 2048, 0x11: 2036, 0x19: 4071, 0x1C: 1024}


class Machine:
    def __init__(self, mem, rx=b''):
        self.mem = bytearray(mem)
        self.pc = 0
        self.t = 0
        self.ft = 0
        self.dsp = 0
        self.rsp = 0
        self.fsp = 0
        self.ds = [0] * 32
        self.rs = [0] * 32
        self.fs = [0] * 32
        self.rx = bytearray(rx)
        self.tx = bytearray()
        self.leds = 0
        self.rgb = 0
        self.buttons = 0
        self.ms = 0
        self.steps = 0
        self.idle_reads = 0
        self.pin_out = 0
        self.pin_dir = 0
        self.xadc = [0] * 32
        for reg, value in XADC_SIM.items():
            self.xadc[reg] = value << 4
        # PWM channel c: [period low as written, period (32 bits), duty, control]
        self.pwm = [[0, 0, 0, 0] for _ in range(4)]
        # The serial interfaces, simply: UART 0 and 1 wired TX to RX both ways (no timing),
        # SPI as a MOSI-MISO loopback, an I2C bus without devices, DDS and tone registers
        self.uart_rx = [bytearray(), bytearray()]
        self.uart_regs = [[0, 0, 434, 0], [0, 0, 434, 0]]
        self.spi_regs = [[0, 0, 0, 25, 0, 0, 0, 0] for _ in range(2)]
        self.i2c_regs = [0, 125, 0, 0]
        self.dds_regs = [0, 0]
        self.tone_regs = [0, 0, 32768, 0]

    def pwm_pins(self):
        """Pins owned by an enabled PWM channel, and their level: the ISS has no time
        base for the waveform, so a pin reads high only at full duty (0xFFFF)."""
        owns = level = 0
        for _, _, duty, control in self.pwm:
            if control & 0x8000:
                bit = 1 << (control & 0x3F)
                owns |= bit
                if duty == 0xFFFF:
                    level |= bit
        return owns, level

    def pins(self):
        """Pin levels: driven pins read back their latch (or their PWM channel), inputs
        see PIN_IDLE."""
        owns, level = self.pwm_pins()
        out = (self.pin_out & ~owns) | (level & owns)
        drive = self.pin_dir | owns
        return ((out & drive) | (PIN_IDLE & ~drive)) & PIN_EXISTS

    def rd32(self, a):
        if a & IO_BASE:
            k = (a >> 2) & 0xFF
            return self.io_read(k) if k < 128 else self.io_read_hi(k - 128)
        a &= RAM_BYTES - 4
        return int.from_bytes(self.mem[a:a + 4], 'little')

    def io_read(self, k):
        if k >> 5 == 1:
            return self.xadc[k & 31]
        if k >> 4 == 4:
            _, period, duty, control = self.pwm[(k >> 2) & 3]
            return [period & 0xFFFF, period >> 16, duty, control][k & 3]
        if k >> 4 == 6:
            return 0                                     # pattern generator: idle
        port = ((k >> 2) & 7) - 2
        if k >> 5 == 0 and 0 <= port <= 2:
            shift, sel = 16 * port, k & 3
            vec = [self.pins(), self.pin_out, self.pin_dir, 0][sel]
            return ((vec & PIN_EXISTS) >> shift) & 0xFFFF
        if k >> 3:
            return 0
        if k == 0:
            return self.rx[0] if self.rx else 0
        if k == 1:
            if not self.rx:
                self.idle_reads += 1
            return (1 if self.rx else 0) | 2
        if k == 2:
            return self.leds
        if k == 3:
            return self.buttons
        if k == 4:
            return self.rgb
        if k == 5:
            return self.ms & M32
        if k == 6:
            return (self.steps // 50) & M32          # nominal: 50 instructions per us
        return 0

    def io_read_hi(self, k):
        if k < 8:                                        # UART 0, 1
            u, r = k >> 2, k & 3
            if r == 0:
                rx = self.uart_rx[u]
                return (0x100 | rx.pop(0)) if rx else 0
            if r == 1:
                return (1 if self.uart_rx[u] else 0) | 2 | 4
            return self.uart_regs[u][r]
        if 8 <= k < 24:                                  # SPI 0, 1
            regs, r = self.spi_regs[(k - 8) >> 3], k & 7
            return 0 if r == 1 else regs[r]
        if 24 <= k < 28:                                 # I2C: never busy, no ACK
            return self.i2c_regs[k - 24] if k > 24 else 0
        if 32 <= k < 34:
            return self.dds_regs[k - 32]
        if 40 <= k < 44:
            return self.tone_regs[k - 40]
        return 0

    def store_hi(self, k, v):
        if k < 8:
            u, r = k >> 2, k & 3
            if r == 0:
                if self.uart_regs[u][3] & 0x8000 and self.uart_regs[1 - u][3] & 0x8000:
                    self.uart_rx[1 - u].append(v & 0xFF)
            elif r > 1:
                self.uart_regs[u][r] = v & M32
        elif 8 <= k < 24:
            regs, r = self.spi_regs[(k - 8) >> 3], k & 7
            if r == 0:
                width = (regs[2] >> 4) & 3
                regs[0] = v & (0xFF if width == 0 else 0xFFFF if width == 1 else M32)
            else:
                regs[r] = v & M32
        elif 24 <= k < 28:
            self.i2c_regs[k - 24] = v & M32
        elif 32 <= k < 34:
            self.dds_regs[k - 32] = v & M32
        elif 40 <= k < 44:
            self.tone_regs[k - 40] = v & M32

    def store(self, a, v, byte):
        if a & IO_BASE:
            if (a >> 2) & 0x80:
                return self.store_hi(((a >> 2) & 0xFF) - 128, v)
            k = (a >> 2) & 0x7F
            if k >> 4 == 4:
                ch, sel, v = self.pwm[(k >> 2) & 3], k & 3, v & 0xFFFF
                if sel == 0:
                    ch[0] = v
                elif sel == 1:
                    ch[1] = (v << 16) | ch[0]
                else:
                    ch[sel] = v
                return
            port = ((k >> 2) & 7) - 2
            if k >> 5 == 0 and 0 <= port <= 2:
                shift, sel, mask = 16 * port, k & 3, 0xFFFF << (16 * port)
                if sel == 1:
                    self.pin_out = (self.pin_out & ~mask) | ((v & 0xFFFF) << shift)
                elif sel == 2:
                    self.pin_dir = (self.pin_dir & ~mask) | ((v & 0xFFFF) << shift)
                return
            if k >> 3:
                return
            if k == 0:
                self.tx.append(v & 0xFF)
            elif k == 2:
                self.leds = v & 0xF
            elif k == 4:
                self.rgb = v & 0x3F
            return
        a &= RAM_BYTES - 1
        if byte:
            self.mem[a] = v & 0xFF
        else:
            a &= RAM_BYTES - 4
            self.mem[a:a + 4] = (v & M32).to_bytes(4, 'little')

    def step(self):
        a = (self.pc << 2) & (RAM_BYTES - 4)
        insn = int.from_bytes(self.mem[a:a + 4], 'little')
        t, n, r = self.t, self.ds[self.dsp], self.rs[self.rsp]
        ft, fn = self.ft, self.fs[self.fsp]
        pc1 = (self.pc + 1) & 0x7FFF
        self.steps += 1
        if self.steps % 100 == 0:          # nominal timer: 1 ms per 100 instructions
            self.ms += 1

        if insn & 0x80000000:
            self.dsp = (self.dsp + 1) & 31
            self.ds[self.dsp] = t
            self.t = insn & 0x7FFFFFFF
            self.pc = pc1
            return
        kind = (insn >> 29) & 3
        target = insn & 0x7FFF
        if kind == 0:
            self.pc = target
        elif kind == 1:
            self.t = n
            self.dsp = (self.dsp - 1) & 31
            self.pc = target if t == 0 else pc1
        elif kind == 2:
            self.rsp = (self.rsp + 1) & 31
            self.rs[self.rsp] = (pc1 << 2) & M32
            self.pc = target
        else:
            op = (insn >> 22) & 63
            fop = (insn >> 6) & 31
            sgn = lambda x: x - 0x100000000 if x & 0x80000000 else x
            flag = lambda c: M32 if c else 0
            if op == 0:    v = t
            elif op == 1:  v = n
            elif op == 2:  v = n + t
            elif op == 3:  v = n & t
            elif op == 4:  v = n | t
            elif op == 5:  v = n ^ t
            elif op == 6:  v = ~t
            elif op == 7:  v = flag(n == t)
            elif op == 8:  v = flag(sgn(n) < sgn(t))
            elif op == 9:  v = flag(n < t)
            elif op == 10: v = 0 if t > 31 else n >> t
            elif op == 11: v = 0 if t > 31 else n << t
            elif op == 12: v = r
            elif op == 13:
                v = self.rd32(t & ~3)
                if t == IO_BASE and self.rx:
                    self.rx.pop(0)
            elif op == 14:
                w = self.rd32(t & ~3)
                v = (w >> (8 * (t & 3))) & 0xFF
                if t == IO_BASE and self.rx:
                    self.rx.pop(0)
            elif op == 15: v = self.dsp
            elif op == 16: v = n - t
            elif op == 17: v = t + 1
            elif op == 18: v = t - 1
            elif op == 19: v = flag(t == 0)
            elif op == 20: v = flag(t & 0x80000000)
            elif op == 21: v = n * t
            elif op == 22: v = (t >> 1) | (t & 0x80000000)
            elif op == 23: v = -t
            elif op == 24: v = (n * t) >> 32
            elif op == 25: v = (M32 if n >> 31 else 0) if t > 31 else sgn(n) >> t
            elif op == 26: v = ft
            elif 27 <= op <= 30: v = flag(f_cmp(fn, ft)[op - 27])
            elif op == 31: v = f_to_i(ft)
            elif op == 32: v = self.fsp
            else:          v = t
            v &= M32

            if fop == 0:    fv = ft
            elif fop == 1:  fv = fn
            elif fop == 2:  fv = t
            elif fop == 3:
                fv = self.rd32(t & ~3)
                if t == IO_BASE and self.rx:
                    self.rx.pop(0)
            elif fop == 4:  fv = f_add(fn, ft)
            elif fop == 5:  fv = f_add(fn, ft, sub=True)
            elif fop == 6:  fv = f_mul(fn, ft)
            elif fop == 7:  fv = f_div(fn, ft)
            elif fop == 8:  fv = f_sqrt(ft)
            elif fop == 9:  fv = i_to_f(t)
            elif fop == 10: fv = ft ^ 0x80000000
            elif fop == 11: fv = ft & 0x7FFFFFFF
            elif fop == 12: fv = f_trunc(ft)
            else:           fv = ft

            if insn & 0x00100000:
                self.store(t, n, bool(insn & 0x00080000))
            if insn & 0x00004000:
                self.store(t, ft, False)
            dd = DELTAS[(insn >> 15) & 3]
            rd = DELTAS[(insn >> 17) & 3]
            fd = DELTAS[(insn >> 11) & 3]
            new_dsp = (self.dsp + dd) & 31
            new_rsp = (self.rsp + rd) & 31
            new_fsp = (self.fsp + fd) & 31
            if (insn & 0x00200000) or dd == 1:
                self.ds[new_dsp] = t
            if rd == 1:
                self.rs[new_rsp] = t
            if (insn & 0x00002000) or fd == 1:
                self.fs[new_fsp] = ft
            self.pc = (r >> 2) & 0x7FFF if insn & 0x10000000 else pc1
            self.dsp, self.rsp, self.fsp, self.t, self.ft = new_dsp, new_rsp, new_fsp, v, fv

    def run(self, max_steps, idle_limit=2000):
        """Run until max_steps, or until all input is consumed and the program
        has polled an empty RX FIFO idle_limit times (waiting at KEY)."""
        while self.steps < max_steps:
            self.step()
            if not self.rx and self.idle_reads > idle_limit:
                break


DELTAS = {0: 0, 1: 1, 3: -1, 2: -2}


# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

def write_outputs(comp, size, base):
    os.makedirs(os.path.dirname(base) or '.', exist_ok=True)
    words = [comp.cell(a) for a in range(0, RAM_BYTES, 4)]
    with open(base + '.hex', 'w') as f:
        for w in words:
            f.write(f'{w:08x}\n')
    used = (size + 3) // 4

    def data(name):
        return comp.lookup(name)['xt'] + 8

    with open(base + '_image.h', 'w') as f:
        f.write('/* Generated by tools/hf32.py from forth/kernel.fs. Do not edit. */\n')
        f.write('#define FORTH_IMAGE_WORDS %d\n' % used)
        # byte addresses of the cells holding the newest header and HERE, for the ARM's
        # dictionary walk
        f.write('#define FORTH_LATEST_ADDR 0x%05x\n' % data('latest'))
        f.write('#define FORTH_DP_ADDR 0x%05x\n' % data('dp'))
        # and of the stack copies QUIT makes before each line, for the stack views
        f.write('#define FORTH_SDEPTH_ADDR 0x%05x\n' % data('sdepth'))
        f.write('#define FORTH_SSNAP_ADDR 0x%05x\n' % data('ssnap'))
        f.write('#define FORTH_FSDEPTH_ADDR 0x%05x\n' % data('fsdepth'))
        f.write('#define FORTH_FSSNAP_ADDR 0x%05x\n' % data('fssnap'))
        f.write('static const unsigned int forth_image[FORTH_IMAGE_WORDS] = {\n')
        for i in range(0, used, 6):
            f.write('    ' + ', '.join(f'0x{w:08x}' for w in words[i:min(i + 6, used)]) + ',\n')
        f.write('};\n')
    with open(base + '.map', 'w') as f:
        for w in sorted(comp.words.values(), key=lambda w: w['xt']):
            f.write(f"{w['xt']:05x}  {w['name']}\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    b = sub.add_parser('build')
    b.add_argument('source')
    b.add_argument('-o', '--output', default='build/forth')
    r = sub.add_parser('run')
    r.add_argument('source')
    r.add_argument('-i', '--input', action='append', default=[],
                   help='a line of terminal input (repeatable)')
    r.add_argument('-f', '--input-file', help='file with lines of terminal input')
    r.add_argument('--steps', type=int, default=50_000_000)
    args = ap.parse_args()

    comp = Compiler()
    with open(args.source, encoding='ascii') as f:
        src = f.read()
    try:
        size = comp.compile(src)
    except CompileError as e:
        sys.exit(f'{args.source}: {e}')

    if args.cmd == 'build':
        write_outputs(comp, size, args.output)
        print(f'HF32: {size} bytes ({size * 100 // RAM_BYTES}% of RAM), '
              f'{len(comp.words)} words -> {args.output}.hex/_image.h/.map')
    else:
        lines = list(args.input)
        if args.input_file:
            with open(args.input_file, encoding='ascii') as f:
                lines += f.read().splitlines()
        rx = ''.join(line + '\r' for line in lines).encode('ascii')
        m = Machine(comp.mem, rx)
        m.run(args.steps)
        sys.stdout.write(m.tx.decode('ascii', 'replace'))
        print(f'\n[{m.steps} instructions, dsp={m.dsp}, rsp={m.rsp}, fsp={m.fsp}, '
              f'leds={m.leds:04b}]')


if __name__ == '__main__':
    main()
