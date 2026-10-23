#!/usr/bin/env python3
"""生成滚轮符号与特效贴图（纯程序绘制，无外部素材）。

    python3 tools/gen_symbols.py

输出：
  assets/symbols/<id>.png  符号（256x256，透明背景）
  assets/fx/*.png          粒子贴图（火花、星光、金币）
  icon.png                 项目图标

这些只是默认素材。换成自己的美术不需要这个脚本：在 Godot 里打开 symbols/*.tres，
把 Texture 换成你的图片即可（运动模糊由着色器实时生成）。
依赖：Pillow、numpy。
"""
from __future__ import annotations

import math
import os

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SYM_DIR = os.path.join(ROOT, "assets", "symbols")
FX_DIR = os.path.join(ROOT, "assets", "fx")

S = 1024  # 工作画布（4 倍超采样）
OUT = 256  # 输出尺寸

OUTLINE = (28, 12, 6)

FONT_CANDIDATES = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
    "/Library/Fonts/Arial Bold.ttf",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "C:/Windows/Fonts/arialbd.ttf",
]


# ---------------------------------------------------------------- 基础工具

def new_mask() -> Image.Image:
    return Image.new("L", (S, S), 0)


def new_canvas() -> Image.Image:
    return Image.new("RGBA", (S, S), (0, 0, 0, 0))


def _ramp(img: Image.Image, lo: int, hi: int) -> Image.Image:
    lut = [0 if v <= lo else 255 if v >= hi else int((v - lo) * 255 / (hi - lo)) for v in range(256)]
    return img.point(lut)


def dilate(m: Image.Image, r: float) -> Image.Image:
    """近似圆形膨胀：高斯模糊后取阈值（比 MaxFilter 快得多）。"""
    if r <= 0:
        return m.copy()
    return _ramp(m.filter(ImageFilter.GaussianBlur(r / 1.3)), 10, 38)


def erode(m: Image.Image, r: float) -> Image.Image:
    return ImageChops.invert(dilate(ImageChops.invert(m), r))


def union(*masks: Image.Image) -> Image.Image:
    out = masks[0]
    for m in masks[1:]:
        out = ImageChops.lighter(out, m)
    return out


def _interp(stops, t):
    pos = [p for p, _ in stops]
    return np.stack([np.interp(t, pos, [c[i] for _, c in stops]) for i in range(3)], axis=-1)


def vgrad(stops, y0=0, y1=S) -> Image.Image:
    t = np.clip((np.arange(S) - y0) / max(1, y1 - y0), 0, 1)
    col = _interp(stops, t)
    arr = np.broadcast_to(col[:, None, :], (S, S, 3))
    return Image.fromarray(np.ascontiguousarray(arr).astype(np.uint8), "RGB")


def hgrad(stops, x0=0, x1=S) -> Image.Image:
    t = np.clip((np.arange(S) - x0) / max(1, x1 - x0), 0, 1)
    col = _interp(stops, t)
    arr = np.broadcast_to(col[None, :, :], (S, S, 3))
    return Image.fromarray(np.ascontiguousarray(arr).astype(np.uint8), "RGB")


def rgrad(stops, cx, cy, r) -> Image.Image:
    yy, xx = np.mgrid[0:S, 0:S]
    t = np.clip(np.hypot(xx - cx, yy - cy) / r, 0, 1)
    return Image.fromarray(_interp(stops, t).astype(np.uint8), "RGB")


def paint(canvas: Image.Image, fill, m: Image.Image, opacity: float = 1.0) -> None:
    """用 fill（颜色或 RGB 图）按蒙版 m 叠到 canvas 上。"""
    img = Image.new("RGB", (S, S), fill) if isinstance(fill, tuple) else fill
    layer = img.convert("RGBA")
    a = m if opacity >= 1.0 else m.point(lambda v: int(v * opacity))
    layer.putalpha(a)
    canvas.alpha_composite(layer)


def shadow(canvas: Image.Image, m: Image.Image, blur=16, dy=20, opacity=0.5) -> None:
    sh = ImageChops.offset(m.filter(ImageFilter.GaussianBlur(blur)), 0, dy)
    paint(canvas, (0, 0, 0), sh, opacity)


def gloss(canvas: Image.Image, m: Image.Image, strength=0.4, inset=28, reach=0.5) -> None:
    """上半部的高光，让符号有"糖果"质感。"""
    bb = m.getbbox()
    if not bb:
        return
    y0, y1 = bb[1], bb[3]
    t = np.clip(1.0 - (np.arange(S) - y0) / max(1.0, (y1 - y0) * reach), 0, 1) ** 1.6
    grad = Image.fromarray((np.broadcast_to(t[:, None], (S, S)) * 255).astype(np.uint8), "L")
    paint(canvas, (255, 255, 255), ImageChops.multiply(erode(m, inset), grad), strength)


def ellipse_mask(cx, cy, rx, ry, angle_deg=0.0) -> Image.Image:
    m = new_mask()
    a = math.radians(angle_deg)
    pts = []
    for i in range(96):
        t = i / 96 * math.tau
        x, y = rx * math.cos(t), ry * math.sin(t)
        pts.append((cx + x * math.cos(a) - y * math.sin(a), cy + x * math.sin(a) + y * math.cos(a)))
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m


def circle_mask(cx, cy, r) -> Image.Image:
    m = new_mask()
    ImageDraw.Draw(m).ellipse((cx - r, cy - r, cx + r, cy + r), fill=255)
    return m


def bezier(p0, p1, p2, steps=40):
    pts = []
    for i in range(steps + 1):
        t = i / steps
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1]
        pts.append((x, y))
    return pts


def thick_line(points, width) -> Image.Image:
    m = new_mask()
    d = ImageDraw.Draw(m)
    d.line(points, fill=255, width=width, joint="curve")
    r = width / 2
    for x, y in (points[0], points[-1]):
        d.ellipse((x - r, y - r, x + r, y + r), fill=255)
    return m


def load_font(size: int) -> ImageFont.ImageFont:
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default(size=size)


def standard(m: Image.Image, fill, rings, gloss_strength=0.4) -> Image.Image:
    """常规符号：投影 + 多层描边 + 填充 + 高光。rings: [(半径, 颜色)]，半径大的在外。"""
    c = new_canvas()
    outer = max(r for r, _ in rings)
    shadow(c, dilate(m, outer))
    for r, col in sorted(rings, reverse=True):
        paint(c, col, dilate(m, r))
    paint(c, fill, m)
    if gloss_strength:
        gloss(c, m, gloss_strength)
    return c


# ---------------------------------------------------------------- 符号

def sym_seven() -> Image.Image:
    m = new_mask()
    ImageDraw.Draw(m).polygon(
        [(250, 215), (790, 215), (790, 340), (585, 830), (415, 830), (612, 345), (250, 345)], fill=255
    )
    m = _ramp(m.filter(ImageFilter.GaussianBlur(6)), 90, 165)  # 稍微圆角
    bb = m.getbbox()
    fill = vgrad([(0, (255, 150, 125)), (0.35, (242, 32, 36)), (1, (128, 0, 12))], bb[1], bb[3])
    return standard(m, fill, [(16, (255, 214, 80)), (34, OUTLINE)], 0.45)


def sym_bar() -> Image.Image:
    m = new_mask()
    box = (140, 345, 884, 679)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=64, fill=255)
    fill = vgrad([(0, (86, 86, 98)), (0.5, (24, 24, 30)), (1, (0, 0, 0))], box[1], box[3])
    c = standard(m, fill, [(16, (255, 214, 80)), (34, OUTLINE)], 0)
    ring = ImageChops.subtract(erode(m, 22), erode(m, 30))
    paint(c, (210, 165, 55), ring)

    font = load_font(250)
    tm = new_mask()
    td = ImageDraw.Draw(tm)
    tb = td.textbbox((0, 0), "BAR", font=font)
    w, h = tb[2] - tb[0], tb[3] - tb[1]
    x, y = 512 - w / 2 - tb[0], 512 - h / 2 - tb[1]
    td.text((x, y), "BAR", font=font, fill=255)
    paint(c, (0, 0, 0), dilate(tm, 10))
    gold = vgrad([(0, (255, 252, 210)), (0.5, (255, 206, 60)), (1, (196, 118, 0))], y + tb[1], y + tb[3])
    paint(c, gold, tm)
    gloss(c, m, 0.22)
    return c


def star_points(cx, cy, outer, inner, n=5, rot=-90.0):
    pts = []
    for k in range(2 * n):
        a = math.radians(rot + k * 180.0 / n)
        r = outer if k % 2 == 0 else inner
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def sym_star() -> Image.Image:
    m = new_mask()
    ImageDraw.Draw(m).polygon(star_points(512, 545, 420, 182), fill=255)
    m = _ramp(m.filter(ImageFilter.GaussianBlur(12)), 100, 160)  # 圆角
    bb = m.getbbox()
    fill = vgrad([(0, (200, 244, 255)), (0.45, (40, 150, 255)), (1, (8, 46, 168))], bb[1], bb[3])
    return standard(m, fill, [(16, (255, 255, 255)), (34, (5, 14, 48))], 0.45)


def sym_bell() -> Image.Image:
    m = new_mask()
    d = ImageDraw.Draw(m)
    top, bottom = 330, 700
    left, right = [], []
    for i in range(101):
        t = i / 100
        y = top + (bottom - top) * t
        w = 165 + 40 * t + 160 * t**2.6  # 圆顶下方先收后外扩，形成喇叭口
        left.append((512 - w, y))
        right.append((512 + w, y))
    d.polygon(left + right[::-1], fill=255)
    d.ellipse((512 - 165, top - 135, 512 + 165, top + 135), fill=255)
    d.rounded_rectangle((512 - 390, 680, 512 + 390, 752), radius=36, fill=255)
    d.ellipse((512 - 42, 152, 512 + 42, 236), fill=255)
    d.ellipse((512 - 64, 718, 512 + 64, 846), fill=255)
    bb = m.getbbox()
    fill = hgrad(
        [(0, (150, 80, 0)), (0.28, (255, 242, 165)), (0.55, (246, 186, 30)), (1, (138, 72, 0))], bb[0], bb[2]
    )
    c = standard(m, fill, [(14, (255, 250, 215)), (32, OUTLINE)], 0.3)
    band = new_mask()
    ImageDraw.Draw(band).rectangle((0, 636, S, 664), fill=255)
    paint(c, (165, 96, 0), ImageChops.multiply(band, erode(m, 6)), 0.8)
    return c


def sym_cherry() -> Image.Image:
    c = new_canvas()
    cherries = [(338, 690, 168), (684, 712, 160)]
    apex = (552, 222)
    stems = new_mask()
    for i, (cx, cy, r) in enumerate(cherries):
        p0 = (cx, cy - r + 30)
        ctrl = ((p0[0] + apex[0]) / 2 + (-95 if i == 0 else 75), (p0[1] + apex[1]) / 2)
        stems = union(stems, thick_line(bezier(p0, ctrl, apex), 34))
    leaf = ellipse_mask(690, 250, 150, 62, -28)
    balls = [circle_mask(cx, cy, r) for cx, cy, r in cherries]
    whole = union(stems, leaf, *balls)
    shadow(c, dilate(whole, 30))
    paint(c, OUTLINE, dilate(whole, 28))
    paint(c, vgrad([(0, (120, 210, 70)), (1, (36, 112, 22))], 200, 560), stems)
    paint(c, vgrad([(0, (150, 235, 90)), (1, (40, 140, 30))], 190, 310), leaf)
    vein = thick_line([(565, 290), (815, 205)], 10)
    paint(c, (40, 120, 30), ImageChops.multiply(vein, erode(leaf, 14)))
    for (cx, cy, r), bm in zip(cherries, balls):
        paint(c, OUTLINE, dilate(bm, 12))
        paint(c, rgrad([(0, (255, 160, 160)), (0.38, (236, 24, 46)), (1, (116, 0, 16))], cx - r * 0.35, cy - r * 0.4, r * 1.55), bm)
        hl = ellipse_mask(cx - r * 0.38, cy - r * 0.42, r * 0.28, r * 0.17, -35).filter(ImageFilter.GaussianBlur(6))
        paint(c, (255, 255, 255), hl, 0.85)
    return c


def sym_melon() -> Image.Image:
    c = new_canvas()
    cx, cy, R = 512, 318, 410

    def half(r):
        m = new_mask()
        ImageDraw.Draw(m).pieslice((cx - r, cy - r, cx + r, cy + r), 0, 180, fill=255)
        return m

    rind, light, flesh = half(R), half(R - 36), half(R - 64)
    shadow(c, dilate(rind, 30))
    paint(c, OUTLINE, dilate(rind, 28))
    paint(c, vgrad([(0, (70, 170, 55)), (1, (14, 78, 18))], cy, cy + R), rind)
    paint(c, (205, 242, 150), light)
    paint(c, rgrad([(0, (255, 130, 118)), (0.6, (236, 40, 52)), (1, (192, 18, 36))], cx, cy, R - 64), flesh)
    seeds = new_mask()
    for ang, rad in [(38, 255), (68, 290), (112, 290), (142, 255), (54, 165), (90, 215), (126, 165), (90, 110)]:
        a = math.radians(ang)
        x, y = cx + rad * math.cos(a), cy + rad * math.sin(a)
        seeds = union(seeds, ellipse_mask(x, y, 17, 30, ang - 90))
    paint(c, (30, 12, 10), seeds)
    strip = new_mask()
    ImageDraw.Draw(strip).rectangle((0, cy, S, cy + 22), fill=255)
    paint(c, (255, 255, 255), ImageChops.multiply(strip, erode(flesh, 4)), 0.35)
    return c


def sym_grape() -> Image.Image:
    c = new_canvas()
    r, dx = 74, 140
    grapes = []
    for n, y in [(4, 398), (3, 512), (2, 626), (1, 738)]:
        x0 = 512 - (n - 1) * dx / 2
        grapes += [(x0 + i * dx, y) for i in range(n)]
    stem = thick_line([(512, 340), (548, 210)], 30)
    leaf = ellipse_mask(660, 262, 132, 56, -22)
    balls = [circle_mask(x, y, r) for x, y in grapes]
    whole = union(stem, leaf, *balls)
    shadow(c, dilate(whole, 30))
    paint(c, OUTLINE, dilate(whole, 28))
    paint(c, (120, 72, 30), stem)
    paint(c, vgrad([(0, (150, 235, 90)), (1, (40, 140, 30))], 200, 320), leaf)
    for (x, y), bm in zip(grapes, balls):
        paint(c, OUTLINE, dilate(bm, 10))
        paint(c, rgrad([(0, (226, 170, 255)), (0.4, (150, 60, 220)), (1, (62, 10, 110))], x - r * 0.35, y - r * 0.4, r * 1.6), bm)
        hl = circle_mask(x - r * 0.36, y - r * 0.38, r * 0.2).filter(ImageFilter.GaussianBlur(4))
        paint(c, (255, 255, 255), hl, 0.8)
    return c


SYMBOLS = {
    "seven": sym_seven,
    "bar": sym_bar,
    "star": sym_star,
    "bell": sym_bell,
    "melon": sym_melon,
    "grape": sym_grape,
    "cherry": sym_cherry,
}


# ---------------------------------------------------------------- 输出

def downsample(img: Image.Image, size: int) -> Image.Image:
    # 预乘 alpha 再缩放，避免透明边缘发黑
    return img.convert("RGBa").resize((size, size), Image.LANCZOS).convert("RGBA")


def alpha_image(alpha: np.ndarray, rgb=(255, 255, 255)) -> Image.Image:
    h, w = alpha.shape
    arr = np.zeros((h, w, 4), np.uint8)
    arr[..., 0], arr[..., 1], arr[..., 2] = rgb
    arr[..., 3] = (np.clip(alpha, 0, 1) * 255 + 0.5).astype(np.uint8)
    return Image.fromarray(arr, "RGBA")


def fx_spark() -> Image.Image:
    w, h = 16, 64
    yy, xx = np.mgrid[0:h, 0:w]
    dx = (xx - (w - 1) / 2) / (w / 2)
    dy = (yy - (h - 1) / 2) / (h / 2)
    a = np.exp(-(dx**2) * 6) * np.clip(1 - np.abs(dy), 0, 1) ** 1.5
    return alpha_image(a)


def fx_star() -> Image.Image:
    n = 64
    yy, xx = np.mgrid[0:n, 0:n]
    x = np.abs(xx - (n - 1) / 2) / (n / 2)
    y = np.abs(yy - (n - 1) / 2) / (n / 2)
    cross = np.maximum(np.exp(-x * 26) * np.clip(1 - y, 0, 1) ** 2, np.exp(-y * 26) * np.clip(1 - x, 0, 1) ** 2)
    core = np.exp(-(x**2 + y**2) * 30)
    return alpha_image(np.clip(cross + core, 0, 1))


def fx_coin() -> Image.Image:
    c = new_canvas()
    rim = circle_mask(512, 512, 440)
    face = circle_mask(512, 512, 360)
    paint(c, (90, 50, 0), dilate(rim, 20))
    paint(c, hgrad([(0, (190, 110, 0)), (0.35, (255, 236, 140)), (0.7, (240, 170, 20)), (1, (160, 90, 0))]), rim)
    paint(c, hgrad([(0, (255, 240, 150)), (0.5, (230, 160, 20)), (1, (255, 215, 90))]), face)
    star = new_mask()
    ImageDraw.Draw(star).polygon(star_points(512, 530, 250, 105), fill=255)
    paint(c, (255, 250, 210), star, 0.9)
    gloss(c, rim, 0.35, inset=40)
    return downsample(c, 64)


def make_icon(seven: Image.Image) -> Image.Image:
    c = new_canvas()
    bg = new_mask()
    ImageDraw.Draw(bg).rounded_rectangle((40, 40, S - 40, S - 40), radius=180, fill=255)
    paint(c, vgrad([(0, (40, 34, 70)), (1, (12, 10, 24))]), bg)
    c.alpha_composite(seven)
    return downsample(c, 128)


def main() -> None:
    os.makedirs(SYM_DIR, exist_ok=True)
    os.makedirs(FX_DIR, exist_ok=True)
    big_seven = None
    for name, fn in SYMBOLS.items():
        img = fn()
        if name == "seven":
            big_seven = img
        downsample(img, OUT).save(os.path.join(SYM_DIR, f"{name}.png"))
        print("symbol", name)
    fx_spark().save(os.path.join(FX_DIR, "spark.png"))
    fx_star().save(os.path.join(FX_DIR, "star.png"))
    fx_coin().save(os.path.join(FX_DIR, "coin.png"))
    make_icon(big_seven).save(os.path.join(ROOT, "icon.png"))
    print("fx + icon done")


if __name__ == "__main__":
    main()
