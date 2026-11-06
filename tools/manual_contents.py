#!/usr/bin/env python3
"""Rewrites the contents list at the top of docs/Manual.md from its headings: every chapter
(##) with its sections (###) as links, so a reader can jump straight to a section, on GitHub
and in the PDF. The anchors are those python-markdown's toc extension (the PDF) and GitHub
both make from a heading. Run it after adding or renaming a section:

    python tools/manual_contents.py
"""

import os
import re

from markdown.extensions.toc import slugify

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(HERE, 'docs', 'Manual.md')


def main():
    with open(PATH, encoding='utf-8') as f:
        text = f.read()

    lines, in_code = [], False
    for line in text.splitlines():
        if line.startswith('```'):
            in_code = not in_code
        elif not in_code and (line.startswith('## ') or line.startswith('### ')):
            level = 2 if line.startswith('## ') else 3
            title = line[level + 1:].strip()
            plain = re.sub(r'[`*]', '', title)
            entry = f'[{plain}](#{slugify(plain, "-")})'
            if level == 2:
                lines.append(f'- **{entry}**')
            else:
                lines.append(f'  - {entry}')

    block = 'Contents:\n\n' + '\n'.join(lines) + '\n'
    new, n = re.subn(r'Contents:\n\n(?:(?:\d+\. |- |  - ).*\n)+', block, text, count=1)
    if n != 1:
        raise SystemExit('contents block not found')
    with open(PATH, 'w', encoding='utf-8', newline='\n') as f:
        f.write(new)
    print(f'contents: {sum(1 for l in lines if l.startswith("- "))} chapters, '
          f'{sum(1 for l in lines if l.startswith("  - "))} sections')


if __name__ == '__main__':
    main()
