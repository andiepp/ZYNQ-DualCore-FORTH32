"""Draws the ZYNQ-FORTH32 icon: an FPGA chip with pins, "32" in orange, "FORTH" above it."""
import sys
from PIL import Image, ImageDraw, ImageFont

out = sys.argv[1]
S = 1024
img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

pin_color = (176, 184, 196, 255)
body = (30, 36, 48, 255)
edge = (255, 140, 26, 255)
text_main = (255, 150, 40, 255)
text_dim = (210, 218, 230, 255)

# pins on all four sides
n, pw, pl = 6, 54, 120
lo, hi = 250, S - 250
for i in range(n):
    c = lo + (hi - lo) * i / (n - 1)
    d.rounded_rectangle([c - pw / 2, 40, c + pw / 2, 40 + pl + 60], 14, fill=pin_color)
    d.rounded_rectangle([c - pw / 2, S - 40 - pl - 60, c + pw / 2, S - 40], 14, fill=pin_color)
    d.rounded_rectangle([40, c - pw / 2, 40 + pl + 60, c + pw / 2], 14, fill=pin_color)
    d.rounded_rectangle([S - 40 - pl - 60, c - pw / 2, S - 40, c + pw / 2], 14, fill=pin_color)

# chip body with an orange edge
m = 150
d.rounded_rectangle([m, m, S - m, S - m], 90, fill=edge)
d.rounded_rectangle([m + 26, m + 26, S - m - 26, S - m - 26], 70, fill=body)
# pin-1 dot
d.ellipse([m + 70, m + 70, m + 130, m + 130], fill=(90, 100, 118, 255))


def font(size, bold=True):
    for name in (('consolab.ttf' if bold else 'consola.ttf'), 'arialbd.ttf', 'arial.ttf'):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            pass
    return ImageFont.load_default()


def centered(text, f, y, fill):
    box = d.textbbox((0, 0), text, font=f)
    w = box[2] - box[0]
    d.text(((S - w) / 2 - box[0], y - box[1]), text, font=f, fill=fill)


centered('FORTH', font(150), 300, text_dim)
centered('32', font(380), 470, text_main)

sizes = [(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (24, 24), (16, 16)]
img.save(out, sizes=sizes)
img.resize((256, 256), Image.LANCZOS).save(out.replace('.ico', '.png'))
print('wrote', out)
