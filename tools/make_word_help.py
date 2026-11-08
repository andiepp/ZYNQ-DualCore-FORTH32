#!/usr/bin/env python3
"""Builds the app's word help (app/src/ZynqForth/Help/words.json) from the manual's word
reference (docs/Manual.md, chapter 5): every table row with a word, its stack effect and
description, the internal words described in prose ("`name ( stack )`"), the section, related
words (the same table) and example lines from the manual's code blocks. The manual stays the
one place where words are described.

It also checks the help against the kernel's words (tools/hf32.py compiles forth/kernel.fs):
a word without help is reported, and the run fails unless it is in NO_HELP.

    python tools/make_word_help.py
"""

import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import hf32  # noqa: E402

OUT = os.path.join(ROOT, 'app', 'src', 'ZynqForth', 'Help', 'words.json')

# kernel words that need no help entry: primitives' twins and words only the
# cross-compiler's own code calls
NO_HELP = set()

# the manual's section of internal words (prose lists of them get their paragraph's lead)
INTERNAL = '5.24'


def clean(text):
    """Markdown cell -> plain text."""
    text = re.sub(r'\[([^\]]+)\]\([^)]*\)', r'\1', text)      # links
    text = text.replace('**', '').replace('\\|', '|')
    # code spans in pairs, left to right; one starting with a space is an error message: quoted
    text = re.sub(r'`([^`]*)`', lambda m: '"' + m.group(1)[1:] + '"' if m.group(1).startswith(' ') else m.group(1), text)
    return re.sub(r'\s+', ' ', text).strip()


STRUCTURE = ('if', 'else', 'then', 'begin', 'until', 'while', 'repeat', 'again', 'do', 'loop', '+loop',
             'exit', 'recurse')


def names_in(cell):
    """The words a table cell names: `: name` is ':', `( text)` is '('; `a`, `b` are two."""
    return [n.split()[0] for n in re.findall(r'`([^`]+)`', cell) if n.strip()]


def main():
    lines = open(os.path.join(ROOT, 'docs', 'Manual.md'), encoding='utf-8').read().splitlines()
    start = next(i for i, l in enumerate(lines) if l.startswith('## 5. '))
    end = next(i for i, l in enumerate(lines) if l.startswith('## 7. '))
    entries = {}
    order = []
    section = ''
    tables = []                       # (section, [names]) for "related"
    code = []                         # (section, line) from code blocks of chapters 5 and 6
    in_code = False
    table = None
    header = None
    para = []
    paragraphs = []                   # (section, text) of chapter 5, for words named only in prose

    def add(name, stack, text, sec):
        if name in entries or not name or ' ' in name and not name.startswith(('."', 's"')):
            return
        entries[name] = {'name': name, 'stack': stack, 'text': text, 'section': sec}
        order.append(name)

    def flush_para():
        text = ' '.join(para)
        para.clear()
        if text:
            paragraphs.append((section, text))
        if not text or not section.startswith(INTERNAL):
            return
        # "`name ( stack )`" in prose: the sentence it is in describes it
        for m in re.finditer(r'`([^`\s]+) (\([^`]*\))`', text):
            sentences = re.split(r'(?<=[.;:])\s+', text)
            sent = next((s for s in sentences if m.group(0) in s), text)
            add(m.group(1), clean(m.group(2)), clean(sent), section)
        # bare lists of internal words: the paragraph's lead describes them
        lead = re.match(r'\*\*([^*]+)\*\*', text)
        for n in re.findall(r'`([^`\s()]+)`', text):
            if re.fullmatch(r'[^\s]+', n) and not n.startswith('$') and not n.isdigit():
                add(n, '', 'Internal: ' + (clean(lead.group(1)).rstrip(':. ') if lead else 'kernel helper')
                    + '. ' + clean(text)[:240] + ('…' if len(clean(text)) > 240 else ''), section)

    for i in range(start, end):
        l = lines[i]
        if l.startswith('```'):
            in_code = not in_code
            continue
        if in_code:
            code.append((section, l))
            continue
        if l.startswith('### '):
            flush_para()
            section = l[4:].strip()
            table = header = None
            continue
        if l.startswith('|'):
            flush_para()
            cells = [c.strip() for c in re.split(r'(?<!\\)\|', l.strip())[1:-1]]
            if header is None:
                header = [c.lower() for c in cells]
                table = []
                tables.append((section, table))
                continue
            if set(''.join(cells)) <= set('-: '):
                continue
            if header[0] == 'structure':
                # `f if ... else ... then`: each control word gets the first row it is in
                usage = clean(cells[0])
                for n in [t for t in re.findall(r'`([^`]+)`', cells[0])[0].split() if t in STRUCTURE]:
                    add(n, usage, clean(cells[-1]), section)
                    table.append(n)
                continue
            if header[0] != 'word':
                continue
            names = names_in(cells[0])
            stack = clean(cells[1]) if len(cells) > 2 and header[1] == 'stack' else ''
            text = clean(cells[-1])
            for n in names:
                add(n, stack, text, section)
                table.append(n)
            continue
        header = None
        if l.strip() == '':
            flush_para()
        else:
            para.append(l.strip())
    flush_para()

    # kernel words named only in the text of a section: the sentence that names them
    comp = hf32.Compiler()
    comp.compile(open(os.path.join(ROOT, 'forth', 'kernel.fs'), encoding='ascii').read())
    for k in sorted(comp.words):
        if k in {n.lower() for n in entries}:
            continue
        for sec, text in paragraphs:
            m = re.search(r'`' + re.escape(k) + r'(?: (\([^`]*\)))?`', text, re.I)
            if m:
                sent = next((s for s in re.split(r'(?<=[.;])\s+', text) if m.group(0) in s), text)
                add(m.group(0).strip('`').split()[0], clean(m.group(1) or ''), clean(sent), sec)
                break

    # examples: code lines of chapter 6 as well
    ex6 = next(i for i, l in enumerate(lines) if l.startswith('## 6. '))
    in_code = False
    for l in lines[ex6:end]:
        if l.startswith('```'):
            in_code = not in_code
        elif in_code:
            code.append(('6', l))

    related = {}
    for sec, names in tables:
        for n in names:
            related.setdefault(n, list(dict.fromkeys(x for x in names if x != n))[:12])
    for n in order:
        e = entries[n]
        e['area'] = re.sub(r'^\d+\.\d+\s+', '', e['section'])
        e['related'] = related.get(n, [])
        pat = re.compile(r'(^|\s)' + re.escape(n) + r'(\s|$)', re.I)
        ex = []
        for _, cl in code:
            line = re.sub(r'\s{2,}(\\ )', r'   \1', cl.strip())     # close up the gap before a comment
            if pat.search(cl) and len(line) <= 90 and line not in ex:
                ex.append(line)
            if len(ex) == 3:
                break
        e['examples'] = ex

    # coverage against the kernel
    kernel = set(comp.words)
    have = {n.lower() for n in entries}
    missing = sorted(k for k in kernel if k not in have and k not in NO_HELP)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'w', encoding='utf-8', newline='\n') as f:
        json.dump([entries[n] for n in order], f, indent=0, ensure_ascii=False)
    print(f'{OUT}: {len(order)} entries; kernel {len(kernel)} words, {len(missing)} without help')
    if missing:
        print('without help:', ' '.join(missing))
        sys.exit(1)


if __name__ == '__main__':
    main()
