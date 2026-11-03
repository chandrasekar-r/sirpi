"""Builds Resources/AppIcon.icns from the Sirpi logo artwork (docs/images/logo-source.png).

The artwork is a rounded square on white. This cuts the square out with an anti-aliased mask (dropping the white halo),
places it on the macOS icon grid (824 px body in a 1024 px canvas) with a soft shadow, and writes every iconset size.
Usage: python scripts/make_icon.py   (needs Pillow; run from the repo root; uses macOS iconutil)
"""
import os, subprocess, tempfile
from PIL import Image, ImageDraw, ImageFilter

SRC = "docs/images/logo-source.png"
BOX, RADIUS, INSET = (103, 102, 1149, 1152), 280, 3   # measured on the 1254 px source

src = Image.open(SRC).convert("RGBA")
x0, y0, x1, y1 = BOX
k = 4
mask = Image.new("L", (src.width * k, src.height * k), 0)
ImageDraw.Draw(mask).rounded_rectangle([(x0 + INSET) * k, (y0 + INSET) * k, (x1 - INSET) * k, (y1 - INSET) * k],
                                       radius=(RADIUS - INSET) * k, fill=255)
src.putalpha(mask.resize(src.size, Image.LANCZOS))
body = src.crop((x0, y0, x1 + 1, y1 + 1)).resize((824, 824), Image.LANCZOS)

master = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
shadow = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
shadow.paste(Image.new("RGBA", body.size, (8, 10, 40, 255)), (100, 112), body.split()[3].point(lambda a: int(a * 0.42)))
master = Image.alpha_composite(master, shadow.filter(ImageFilter.GaussianBlur(16)))
master.alpha_composite(body, (100, 100))
master.save("docs/images/icon.png")

with tempfile.TemporaryDirectory() as tmp:
    iconset = os.path.join(tmp, "AppIcon.iconset")
    os.makedirs(iconset)
    for name, px in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                     ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]:
        img = master.resize((px, px), Image.LANCZOS)
        if px <= 64:
            img = img.filter(ImageFilter.UnsharpMask(radius=0.6, percent=60, threshold=1))
        img.save(os.path.join(iconset, f"icon_{name}.png"))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", "Resources/AppIcon.icns"], check=True)
print("wrote Resources/AppIcon.icns and docs/images/icon.png")
