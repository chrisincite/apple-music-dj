#!/usr/bin/env python3
"""從程式碼畫出 app 圖示，產生 AppIcon.icns。需要 Pillow。"""
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "app/Resources"
SIZE = 1024


def draw() -> Image.Image:
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    # macOS 風格圓角方形 + 直向漸層（Apple Music 紅 → 紫）
    grad = Image.new("RGBA", (SIZE, SIZE))
    gd = ImageDraw.Draw(grad)
    top, bot = (255, 92, 106), (156, 42, 138)
    for y in range(SIZE):
        t = y / SIZE
        gd.line([(0, y), (SIZE, y)],
                fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)) + (255,))
    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, SIZE - 1, SIZE - 1],
                                           radius=int(SIZE * 0.225), fill=255)
    img.paste(grad, (0, 0), mask)

    d = ImageDraw.Draw(img)
    W = (255, 255, 255, 255)
    stem = int(SIZE * 0.035)
    head = int(SIZE * 0.088)
    x1, x2 = int(SIZE * 0.34), int(SIZE * 0.63)
    y_top, y_bot = int(SIZE * 0.27), int(SIZE * 0.68)
    d.rectangle([x1 - stem // 2, y_top, x1 + stem // 2, y_bot], fill=W)
    d.rectangle([x2 - stem // 2, y_top - int(SIZE * 0.03),
                 x2 + stem // 2, y_bot - int(SIZE * 0.06)], fill=W)
    d.ellipse([x1 - head * 1.5, y_bot - head, x1 + head * 0.6, y_bot + head], fill=W)
    d.ellipse([x2 - head * 1.5, y_bot - int(SIZE * 0.06) - head,
               x2 + head * 0.6, y_bot - int(SIZE * 0.06) + head], fill=W)
    d.polygon([(x1 - stem // 2, y_top), (x2 + stem // 2, y_top - int(SIZE * 0.03)),
               (x2 + stem // 2, y_top + int(SIZE * 0.075)),
               (x1 - stem // 2, y_top + int(SIZE * 0.105))], fill=W)
    return img


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    png = OUT / "icon_1024.png"
    draw().save(png)
    iconset = OUT / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    for sz in (16, 32, 64, 128, 256, 512):
        for scale, suffix in ((1, ""), (2, "@2x")):
            subprocess.run(["sips", "-z", str(sz * scale), str(sz * scale), str(png),
                            "--out", str(iconset / f"icon_{sz}x{sz}{suffix}.png")],
                           capture_output=True)
    subprocess.run(["cp", str(png), str(iconset / "icon_512x512@2x.png")])
    r = subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT / "AppIcon.icns")])
    subprocess.run(["rm", "-rf", str(iconset)])
    sys.exit(r.returncode)


if __name__ == "__main__":
    main()
