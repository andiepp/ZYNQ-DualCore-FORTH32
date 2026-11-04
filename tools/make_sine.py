#!/usr/bin/env python3
"""Writes the quarter-wave sine table of rtl/tone.v (between its 'sine table' markers):
256 entries, entry i = round(32767 * sin(pi/2 * (i + 0.5) / 256)).

    python tools/make_sine.py
"""

import math
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, 'rtl', 'tone.v')
BEGIN = '        // sine table begin (tools/make_sine.py)\n'
END = '        // sine table end\n'

values = [round(32767 * math.sin(math.pi / 2 * (i + 0.5) / 256)) for i in range(256)]
body = ''.join(f"            8'd{i}: quarter_sine = 15'd{v};\n" for i, v in enumerate(values))

text = open(PATH, encoding='ascii').read()
start = text.index(BEGIN) + len(BEGIN)
stop = text.index(END)
open(PATH, 'w', encoding='ascii', newline='\n').write(text[:start] + body + text[stop:])
print(f'wrote {len(values)} entries into {PATH}')
