#!/usr/bin/env python3
"""Render docs/Manual.md to docs/Manual.pdf, or docs/design.md to
docs/Implementation-Details.pdf (Markdown -> HTML -> headless Edge).

    python tools/manual_pdf.py [manual|design] [--keep-html]

Needs the 'markdown' package (pip install --user markdown) and Microsoft Edge.
"""

import argparse
import datetime
import os
import pathlib
import re
import subprocess
import sys

import markdown

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def release_version():
    """The release, as app/Directory.Build.props names it (3.1.0 -> 3.1)."""
    props = pathlib.Path(HERE, 'app', 'Directory.Build.props').read_text(encoding='utf-8')
    version = re.search(r'<Version>(\d+)\.(\d+)', props)
    return f'{version.group(1)}.{version.group(2)}'
# source, PDF, footer and cover text, table of contents
DOCS = {
    'manual': dict(src='Manual.md', pdf='Manual.pdf', label='User Manual', toc=False,
                   sub='User Manual &mdash; a 32-bit Forth CPU with floating point on the '
                       'Digilent Arty Z7-20'),
    'design': dict(src='design.md', pdf='Implementation-Details.pdf',
                   label='Implementation Details', toc=True,
                   sub='Implementation Details &mdash; the HF32 CPU, its FPU and peripherals, '
                       'the ARM side and the Forth kernel'),
}

EDGE_PATHS = [
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
]

CSS = """
@page {
  size: A4;
  margin: 18mm 16mm 18mm 16mm;
  @bottom-left  { content: "ZYNQ-FPGA-FORTH32 \\2014  @LABEL@"; font: 8pt 'Segoe UI', sans-serif; color: #777; }
  @bottom-right { content: "Page " counter(page) " of " counter(pages); font: 8pt 'Segoe UI', sans-serif; color: #777; }
}
@page :first { @bottom-left { content: none; } @bottom-right { content: none; } }

body { font: 10pt/1.45 'Segoe UI', Arial, sans-serif; color: #1a1a1a; }
.cover { height: 240mm; display: flex; flex-direction: column; justify-content: center;
         border-left: 6px solid #1f5f99; padding-left: 14mm; page-break-after: always; }
.cover h1 { font-size: 30pt; margin: 0 0 4mm 0; border: none; }
.cover .sub { font-size: 14pt; color: #444; margin-bottom: 14mm; }
.cover .meta { font-size: 10pt; color: #666; line-height: 1.7; }

h1 { font-size: 20pt; color: #1f5f99; border-bottom: 2px solid #1f5f99; padding-bottom: 2mm; }
h2 { font-size: 15pt; color: #1f5f99; border-bottom: 1px solid #c8d6e5; padding-bottom: 1mm;
     margin-top: 9mm; page-break-before: always; }
h3 { font-size: 12pt; color: #23476b; margin-top: 6mm; }
h4 { font-size: 10.5pt; color: #23476b; margin-top: 5mm; }
h2, h3, h4 { page-break-after: avoid; break-after: avoid; }
h1 + p, h2 + p, h3 + p, h4 + p { break-before: avoid; }
.toc { page-break-after: always; }
.toc h2 { page-break-before: avoid; margin-top: 0; }
.toc ul { list-style: none; padding-left: 0; margin: 0; }
.toc ul ul { padding-left: 7mm; }
.toc > ul > li { margin-top: 2.2mm; font-weight: 600; }
.toc > ul > li li { font-weight: normal; margin: 0.4mm 0; }
img[src$=".svg"] { border: none; }

a { color: #1f5f99; text-decoration: none; }
code { font-family: Consolas, 'Courier New', monospace; font-size: 9pt;
       background: #f1f4f8; padding: 0 2px; border-radius: 2px; }
pre { font-family: Consolas, 'Courier New', monospace; font-size: 8.6pt; line-height: 1.35;
      background: #f6f8fa; border: 1px solid #dde3ea; border-left: 3px solid #1f5f99;
      padding: 2.5mm 3mm; white-space: pre-wrap; break-inside: avoid; }
pre code { background: none; padding: 0; font-size: inherit; }

table { border-collapse: collapse; width: 100%; margin: 3mm 0 4mm 0; font-size: 9pt; }
th { background: #e8eef5; text-align: left; font-weight: 600; }
th, td { border: 1px solid #ccd5df; padding: 1.2mm 2mm; vertical-align: top; }
tr { break-inside: avoid; }
td:first-child code { white-space: nowrap; }
hr { display: none; }
img { max-width: 100%; border: 1px solid #ccd5df; break-inside: avoid; }
ul, ol { padding-left: 6mm; }
li { margin: 0.6mm 0; }
"""


def build_html(md_text, doc):
    # The Markdown's own title becomes the cover page
    lines = md_text.splitlines()
    if lines and lines[0].startswith('# '):
        lines = lines[1:]
    # GitHub needs '\|' for a pipe inside a code span in a table; Python-Markdown keeps the
    # backslash there, and needs no escape
    text = re.sub(r'`[^`\n]*`', lambda m: m.group(0).replace('\\|', '|'), '\n'.join(lines))
    md = markdown.Markdown(extensions=['tables', 'fenced_code', 'toc', 'sane_lists'],
                           extension_configs={'toc': {'toc_depth': '2-3'}})
    body = md.convert(text)
    if doc['toc']:
        # md.toc is <div class="toc"><ul>...</ul></div>: give it a heading of its own and put
        # it after the introduction, before the first chapter
        toc = md.toc.replace('<div class="toc">', '<div class="toc"><h2>Contents</h2>', 1)
        first = body.find('<h2')
        body = body[:first] + toc + body[first:]
    today = datetime.date.today().isoformat()
    # The HTML is written to build/, so images referenced relative to docs/ get absolute paths
    body = re.sub(r'src="(?!\w+:)([^"]+)"',
                  lambda m: f'src="{pathlib.Path(HERE, "docs", m.group(1)).resolve().as_uri()}"', body)
    cover = f"""
<div class="cover">
  <h1>ZYNQ-FPGA-FORTH32</h1>
  <div class="sub">{doc['sub']}</div>
  <div class="meta">ZYNQ-FPGA-FORTH32 {release_version()}<br>Generated {today} from docs/{doc['src']}</div>
</div>"""
    css = CSS.replace('@LABEL@', doc['label'])
    return (f'<!doctype html><html><head><meta charset="utf-8">'
            f'<title>ZYNQ-FPGA-FORTH32 {doc["label"]}</title><style>{css}</style></head>'
            f'<body>{cover}{body}</body></html>')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('doc', nargs='?', choices=sorted(DOCS), default='manual')
    ap.add_argument('--keep-html', action='store_true', help='keep the HTML in build/')
    args = ap.parse_args()
    doc = DOCS[args.doc]
    src = os.path.join(HERE, 'docs', doc['src'])
    pdf = os.path.join(HERE, 'docs', doc['pdf'])
    html_path = os.path.join(HERE, 'build', doc['pdf'].replace('.pdf', '.html'))

    edge = next((p for p in EDGE_PATHS if os.path.exists(p)), None)
    if not edge:
        sys.exit('Microsoft Edge not found')

    with open(src, encoding='utf-8') as f:
        html = build_html(f.read(), doc)
    os.makedirs(os.path.dirname(html_path), exist_ok=True)
    with open(html_path, 'w', encoding='utf-8') as f:
        f.write(html)

    url = 'file:///' + html_path.replace('\\', '/')
    subprocess.run([edge, '--headless=new', '--disable-gpu', '--no-pdf-header-footer',
                    '--no-first-run', f'--print-to-pdf={pdf}', url],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
    if not args.keep_html:
        os.remove(html_path)
    print(f'wrote {pdf} ({os.path.getsize(pdf) // 1024} KB)')


if __name__ == '__main__':
    main()
