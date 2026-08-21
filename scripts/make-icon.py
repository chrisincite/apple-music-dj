#!/usr/bin/env python3
"""從程式碼畫出 app 圖示，產生 icon_1024.png 與 AppIcon.icns。

圖示是「佇列」：三條實心橫條加一格虛線——正在播的、接下來的，
以及播到剩不到 8 首時自動補進來的那一格。畫圖需要 Pillow；
沒有 Pillow 但 icon_1024.png 已存在時，仍會用它打包出 .icns。
"""
import math
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "app/Resources"
SIZE = 1024
SS = 4  # 超取樣倍率，畫完再縮小，邊緣才乾淨

INK_TOP = (43, 36, 52)     # #2B2434
INK_BOT = (13, 12, 17)     # #0D0C11
PAPER = (244, 241, 234)    # #F4F1EA
CORAL = (242, 112, 95)     # #F2705F

# x, y, w, h, 顏色, 透明度（1024 座標系）
BARS = [
    (200, 268, 604, 88, CORAL, 255),
    (200, 400, 470, 88, PAPER, 255),
    (200, 532, 548, 88, PAPER, 184),
]
DASHED = (207, 675, 378, 88)   # 自動補歌的空位
DASH_W, DASH_ON, DASH_OFF, DASH_ALPHA = 14, 44, 36, 107


def gradient(size):
    """對角線性漸層：方向向量 (0.25, 1)，低解析度畫完再放大。"""
    from PIL import Image

    small = 512
    dx, dy = 0.25, 1.0
    norm = dx * dx + dy * dy
    px = []
    for j in range(small):
        v = j / (small - 1)
        row = []
        for i in range(small):
            u = i / (small - 1)
            t = max(0.0, min(1.0, (dx * u + dy * v) / norm))
            row.append(tuple(int(INK_TOP[k] + (INK_BOT[k] - INK_TOP[k]) * t) for k in range(3)))
        px.extend(row)
    img = Image.new("RGB", (small, small))
    img.putdata(px)
    return img.resize((size, size), Image.BICUBIC).convert("RGBA")


def capsule_point(x, y, w, h, d):
    """沿膠囊形（圓角＝半高）周長走 d 距離後的座標。"""
    r = h / 2.0
    straight = w - 2 * r
    arc = math.pi * r
    if d < straight:
        return x + r + d, y
    d -= straight
    if d < arc:
        a = -math.pi / 2 + d / r
        return x + w - r + r * math.cos(a), y + r + r * math.sin(a)
    d -= arc
    if d < straight:
        return x + w - r - d, y + h
    d -= straight
    a = math.pi / 2 + d / r
    return x + r + r * math.cos(a), y + r + r * math.sin(a)


def draw_dashed(layer, s, x, y, w, h):
    """Pillow 沒有虛線，沿周長蓋圓點蓋出來（超取樣後就是圓頭虛線）。"""
    from PIL import ImageDraw

    d = ImageDraw.Draw(layer)
    r = h / 2.0
    total = 2 * (w - 2 * r) + 2 * math.pi * r
    period = DASH_ON + DASH_OFF
    rad = DASH_W / 2.0 * s
    step = 1.5
    pos = 0.0
    while pos < total:
        if pos % period < DASH_ON:
            cx, cy = capsule_point(x, y, w, h, pos)
            cx, cy = cx * s, cy * s
            d.ellipse([cx - rad, cy - rad, cx + rad, cy + rad],
                      fill=PAPER + (DASH_ALPHA,))
        pos += step


def draw(simple=False):
    """simple=True 是給 16／32px 用的簡化版：拿掉虛線格，三條置中。"""
    from PIL import Image, ImageDraw

    w = SIZE * SS
    s = w / 1024.0
    shift = 68 if simple else 0

    img = Image.new("RGBA", (w, w), (0, 0, 0, 0))
    mask = Image.new("L", (w, w), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, w - 1],
                                           radius=int(230 * s), fill=255)
    img.paste(gradient(w), (0, 0), mask)

    for bx, by, bw, bh, color, alpha in BARS:
        by += shift
        layer = Image.new("RGBA", (w, w), (0, 0, 0, 0))
        ImageDraw.Draw(layer).rounded_rectangle(
            [bx * s, by * s, (bx + bw) * s, (by + bh) * s],
            radius=bh / 2.0 * s, fill=color + (alpha,))
        img = Image.alpha_composite(img, layer)

    if not simple:
        layer = Image.new("RGBA", (w, w), (0, 0, 0, 0))
        draw_dashed(layer, s, *DASHED)
        img = Image.alpha_composite(img, layer)

    return img.resize((SIZE, SIZE), Image.LANCZOS)


ENTRIES = [(sz, suffix) for sz in (16, 32, 128, 256, 512) for suffix in ("", "@2x")]


def pack(png: Path, full=None, simple=None) -> int:
    """有 Pillow 就用它縮圖（32px 以下換簡化版），沒有就退回 sips。"""
    iconset = OUT / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    for sz, suffix in ENTRIES:
        px = sz * (2 if suffix else 1)
        dst = iconset / f"icon_{sz}x{sz}{suffix}.png"
        if full is not None:
            from PIL import Image
            src = simple if px <= 32 else full
            src.resize((px, px), Image.LANCZOS).save(dst)
        else:
            subprocess.run(["sips", "-z", str(px), str(px), str(png), "--out", str(dst)],
                           capture_output=True)
    r = subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT / "AppIcon.icns")])
    subprocess.run(["rm", "-rf", str(iconset)])
    return r.returncode


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    png = OUT / "icon_1024.png"
    try:
        import PIL  # noqa: F401
    except ImportError:
        if not png.exists():
            print("沒有 Pillow，也沒有現成的 icon_1024.png", file=sys.stderr)
            sys.exit(1)
        print("沒有 Pillow，直接用現成的 icon_1024.png 打包")
        sys.exit(pack(png))
    full = draw()
    full.save(png)
    sys.exit(pack(png, full=full, simple=draw(simple=True)))


if __name__ == "__main__":
    main()
