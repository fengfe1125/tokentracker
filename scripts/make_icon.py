#!/usr/bin/env python3
"""生成 TokenTracker 应用图标（纯 Python，无第三方依赖）。

输出 assets/icon_1024.png（1024×1024 RGBA）。
设计：暖橙渐变圆角方块 · 顶部玻璃高光 · 白色上升柱状图徽标。
"""
import os
import struct
import sys
import zlib

S = 1024          # 画布尺寸
SS = 3            # 边缘超采样倍数（抗锯齿）
RADIUS = 226      # 圆角半径
BARS = ((0.30, 0.36), (0.44, 0.56), (0.58, 0.80))  # (中心x比例, 高度比例)

PNGDIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets")


def lerp(a, b, t):
    return a + (b - a) * t


def color_at(x, y):
    """主体：左上亮橙 → 右下深橙的渐变。"""
    t = (x / S) * 0.55 + (y / S) * 0.45
    r = lerp(0xE6, 0xB9, t)
    g = lerp(0x93, 0x55, t)
    b = lerp(0x70, 0x3F, t)
    return r, g, b


def rounded_rect_sdf(px, py):
    """圆角矩形有符号距离（px,py 中心像素坐标）。"""
    qx = abs(px - S / 2) - (S / 2 - RADIUS)
    qy = abs(py - S / 2) - (S / 2 - RADIUS)
    ox, oy = max(qx, 0.0), max(qy, 0.0)
    return min(max(qx, qy), 0.0) + (ox * ox + oy * oy) ** 0.5 - RADIUS


def bar_alpha(px, py):
    """白色柱体（圆头胶囊）alpha。"""
    a = 0.0
    for cx, h in BARS:
        bx = cx * S
        bw = 0.115 * S
        top = S / 2 + (h - 0.5) * S * 0.62        # 基于中点向上下延伸
        bottom = S / 2 + 0.5 * S * 0.62 * 0.4
        # 胶囊：上下圆头 + 矩形
        if abs(px - bx) <= bw / 2:
            if top <= py <= bottom:
                a = 1.0
            elif abs(py - top) <= bw / 2 and abs(px - bx) <= bw / 2:
                a = 1.0
        # 圆头部分按距离淡化（粗糙版，配合超采样已足够）
    return a


def glass_alpha(px, py):
    """顶部高光：椭圆白晕。"""
    dx = (px - 0.5 * S) / (0.82 * S)
    dy = (py - 0.30 * S) / (0.34 * S)
    d = dx * dx + dy * dy
    if d >= 1:
        return 0.0
    return 0.30 * (1 - d)


def render():
    os.makedirs(PNGDIR, exist_ok=True)
    rows = []
    for y in range(S):
        row = bytearray()
        for x in range(S):
            # 边缘超采样
            hits = 0
            rr = gg = bb = aa = 0.0
            for sy in range(SS):
                for sx in range(SS):
                    px = x + (sx + 0.5) / SS
                    py = y + (sy + 0.5) / SS
                    d = rounded_rect_sdf(px, py)
                    cov = 1.0 if d <= -0.5 else (0.0 if d >= 0.5 else 0.5 - d)
                    if cov <= 0:
                        continue
                    hits += 1
                    cr, cg, cb = color_at(px, py)
                    bar = bar_alpha(px, py) * 0.93
                    gl = glass_alpha(px, py)
                    alpha = cov
                    # 主体
                    r, g, b = cr, cg, cb
                    # 白色柱体覆盖
                    if bar > 0:
                        r = lerp(r, 255, bar)
                        g = lerp(g, 255, bar)
                        b = lerp(b, 255, bar)
                    # 高光
                    if gl > 0:
                        r = lerp(r, 255, gl)
                        g = lerp(g, 255, gl)
                        b = lerp(b, 255, gl)
                    rr += r; gg += g; bb += b; aa += alpha
            if hits:
                row += bytes((int(rr / hits), int(gg / hits), int(bb / hits), int(aa / hits * 255)))
            else:
                row += b"\x00\x00\x00\x00"
        rows.append(bytes(row))
    # 编码 PNG
    raw = b"".join(b"\x00" + r for r in rows)
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    path = os.path.join(PNGDIR, "icon_1024.png")
    with open(path, "wb") as f:
        f.write(png)
    print("icon written:", path, len(png), "bytes")


if __name__ == "__main__":
    render()