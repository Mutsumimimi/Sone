#!/usr/bin/env python3
"""Generate a macOS .icns app icon from a source logo image.

Pure Python (Pillow only): the source is trimmed of its background margins,
placed centred inside a rounded-square (macOS style) on a transparent canvas,
and written out as a multi-resolution .icns container. No sips/iconutil needed.

Usage:  make_icon.py <source.png> <output.icns>
"""
import io
import os
import struct
import sys

from PIL import Image, ImageDraw

CANVAS = 1024      # master size (px)
RECT = 824         # rounded square size inside the canvas (macOS convention)
RADIUS = 185       # corner radius of that square
LOGO_FRAC = 0.70   # artwork width as a fraction of the rounded square

# icns element type -> pixel size (all PNG payloads)
ICNS_TYPES = [
    ("icp4", 16), ("icp5", 32), ("icp6", 64),
    ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024),
    ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512),
]


def build_master(src):
    im = Image.open(src).convert("RGB")
    # Trim background margins: treat near-white as background.
    mask = im.convert("L").point(lambda v: 255 if v < 245 else 0)
    bbox = mask.getbbox()
    if bbox:
        im = im.crop(bbox)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    d = ImageDraw.Draw(canvas)
    x0 = (CANVAS - RECT) // 2
    d.rounded_rectangle([x0, x0, x0 + RECT - 1, x0 + RECT - 1],
                        radius=RADIUS, fill=(255, 255, 255, 255))

    target_w = int(RECT * LOGO_FRAC)
    scale = target_w / im.size[0]
    logo = im.resize((target_w, max(1, round(im.size[1] * scale))), Image.LANCZOS)
    canvas.paste(logo, ((CANVAS - logo.size[0]) // 2, (CANVAS - logo.size[1]) // 2))
    return canvas


def write_icns(master, out):
    entries = b""
    for typ, size in ICNS_TYPES:
        buf = io.BytesIO()
        master.resize((size, size), Image.LANCZOS).save(buf, format="PNG")
        data = buf.getvalue()
        entries += typ.encode("ascii") + struct.pack(">I", len(data) + 8) + data
    with open(out, "wb") as f:
        f.write(b"icns" + struct.pack(">I", 8 + len(entries)) + entries)


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    src, out = sys.argv[1], sys.argv[2]
    out_dir = os.path.dirname(os.path.abspath(out)) or "."
    os.makedirs(out_dir, exist_ok=True)
    write_icns(build_master(src), out)
    print("wrote " + out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
