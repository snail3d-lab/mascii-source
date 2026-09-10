#!/usr/bin/env python3
"""Mascii — short-clip ASCII renderer for 4:3 talking-head / transition clips.

Renders a SHORT source clip (<~60s, already 4:3) directly to 1920x1080 24fps
ASCII h264 via h264_videotoolbox. NO crop — the source is already 4:3 and
gets scaled to the 1440px centered film region, matching the main
renderer's framing so it concatenates cleanly.

Uses the exact same bitmap-atlas + adaptive-EMA-technique as renderer.py so
the look is identical.

Usage:
  python3 render_intro_ascii.py <source_clip.mov|mp4> <output.mp4>
"""
import os
import subprocess
import sys
import time

import numpy as np
from PIL import Image, ImageDraw, ImageFont

FPS = 24
VW, VH = 1920, 1080
REGION_W = 1440
FONT_SIZE = 14

PAL = " .:-=+*#%@"
N = len(PAL)
PALCOL = np.array([
    (0, 0, 0), (14, 14, 15), (30, 30, 32), (50, 50, 54),
    (75, 75, 80), (104, 104, 110), (137, 137, 144), (170, 170, 178),
    (200, 200, 208), (224, 224, 230), (242, 242, 246), (255, 255, 255),
], dtype=np.uint8)


def font_path():
    for p in ["/System/Library/Fonts/Menlo.ttc",
              "/System/Library/Fonts/Monaco.ttf",
              "/System/Library/Fonts/Courier.ttc"]:
        if os.path.exists(p):
            return p
    raise SystemExit("no monospace font found")


def build():
    fp = font_path()
    font = ImageFont.truetype(fp, FONT_SIZE)
    asc, desc = font.getmetrics()
    ch = asc + desc
    cw = font.getbbox("M")[2]
    rows = VH // ch
    cols = REGION_W // cw
    ox = (VW - cols * cw) // 2
    oy = (VH - rows * ch) // 2

    bm = {}
    for c in PAL:
        img = Image.new("L", (cw, ch), 0)
        if c != " ":
            ImageDraw.Draw(img).text((0, 0), c, fill=255, font=font)
        bm[c] = np.array(img, dtype=np.float32) / 255.0
    atlas = np.concatenate([bm[c].ravel() for c in PAL])

    ypx = np.arange(VH, dtype=np.int32)
    xpx = np.arange(VW, dtype=np.int32)
    row = (ypx - oy) // ch
    pyl = ypx - oy - row * ch
    col = (xpx - ox) // cw
    pxl = xpx - ox - col * cw
    ok_y = (row >= 0) & (row < rows) & (pyl >= 0) & (pyl < ch)
    ok_x = (col >= 0) & (col < cols) & (pxl >= 0) & (pxl < cw)
    O2 = np.where(ok_y[:, None] & ok_x[None, :], pyl[:, None] * cw + pxl[None, :], 0).astype(np.int32)

    yy, xx = np.mgrid[0:VH, 0:VW].astype(np.float32)
    d = np.sqrt(((xx - VW / 2) / (VW / 2)) ** 2 + ((yy - VH / 2) / (VH / 2)) ** 2)
    vig = np.clip(1.0 - 0.22 * (d / 1.42) ** 2.4, 0, 1)
    scan = np.ones(VH, dtype=np.float32)
    scan[1::2] = 0.94

    return dict(ch=ch, cw=cw, rows=rows, cols=cols, ox=ox, oy=oy,
                atlas=atlas, O2=O2, vig=vig, scan=scan,
                hcells=ch * cw, pal=PALCOL,
                box=(oy, oy + rows * ch, ox, ox + cols * cw))


G = None
_lo = None
_hi = None


def render_frame(lum, rng, fl):
    global _lo, _hi
    g = G
    f = lum.astype(np.float32) / 255.0
    lo, hi = np.percentile(f, [1.5, 98.5])
    _lo = lo if _lo is None else 0.9 * _lo + 0.1 * float(lo)
    _hi = hi if _hi is None else 0.9 * _hi + 0.1 * float(hi)
    if _hi - _lo < 0.04:
        _hi = _lo + 0.04
    v = np.clip((f - _lo) / (_hi - _lo), 0, 1) ** 0.92
    cidx = np.clip((v * N).astype(np.int32), 0, N - 1)
    col_up = np.repeat(np.repeat(cidx, g["cw"], axis=1), g["ch"], axis=0)
    I2 = np.zeros((g["rows"] * g["ch"], g["cols"] * g["cw"]), dtype=np.int32)
    I2[:col_up.shape[0], :col_up.shape[1]] = col_up * g["hcells"] + \
        g["O2"][g["oy"]:g["oy"] + col_up.shape[0], g["ox"]:g["ox"] + col_up.shape[1]]
    canvas = g["atlas"][I2][:, :, None] * g["pal"][col_up.ravel()].reshape(col_up.shape + (3,))
    canvas = np.clip(canvas * fl, 0, 255)
    full = np.zeros((VH, VW, 3), dtype=np.float32)
    full[g["box"][0]:min(g["box"][1], VH), g["box"][2]:min(g["box"][3], VW)] = \
        canvas[:min(g["box"][1], VH) - g["box"][0], :min(g["box"][3], VW) - g["box"][2]]
    full *= g["vig"][:, :, None]
    full *= g["scan"][:, None, None]
    n = rng.standard_normal((VH // 2, VW // 2)).astype(np.float32) * 2.4
    full += np.repeat(np.repeat(n, 2, axis=0), 2, axis=1)[:VH, :VW, None]
    return np.clip(full, 0, 255).astype(np.uint8)


def main():
    global G, _lo, _hi
    src = sys.argv[1]
    out = sys.argv[2]
    G = build()
    _lo = _hi = None
    fw, fh = G["cols"], G["rows"]
    log = print

    # source is already 4:3; scale to the 1440px film region (no crop)
    srcp = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-i", src,
         "-vf", f"scale={fw}:{fh}:flags=area",
         "-pix_fmt", "gray", "-f", "rawvideo", "-"],
        stdout=subprocess.PIPE)

    # Encode video to a lossless-ish temp, then mux the source's own audio.
    video_tmp = out + ".video.tmp.mp4"
    enc = subprocess.Popen(
        ["ffmpeg", "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
         "-s", f"{VW}x{VH}", "-r", str(FPS), "-i", "pipe:0",
         "-c:v", "h264_videotoolbox", "-b:v", "10000k", "-pix_fmt", "yuv420p",
         video_tmp],
        stdin=subprocess.PIPE, stderr=subprocess.PIPE)

    rng = np.random.default_rng(7)
    fl = 1.0
    fs = fw * fh
    i = 0
    t0 = time.time()
    while True:
        raw = srcp.stdout.read(fs)
        if len(raw) < fs:
            break
        frame = np.frombuffer(raw, dtype=np.uint8).reshape(fh, fw)
        fl = 0.92 * fl + 0.08 * (1.0 + float(rng.standard_normal()) * 0.018)
        canvas = render_frame(frame, rng, fl)
        enc.stdin.write(canvas.tobytes())
        i += 1
        if i % 500 == 0:
            el = time.time() - t0
            log(f"[intro] {i} frames {1000*el/i:.0f}ms/f")

    srcp.stdout.close(); srcp.wait()
    enc.stdin.close()
    err = enc.stderr.read().decode()
    enc.wait()
    if enc.returncode != 0:
        log("encode error:", err)
        sys.exit(1)
    log(f"[intro] rendered {i} frames in {(time.time()-t0):.1f}s -> {video_tmp}")

    # Mux the source's own audio (its native codec) onto the ASCII video.
    subprocess.run(
        ["ffmpeg", "-y", "-v", "error", "-i", video_tmp, "-i", src,
         "-map", "0:v:0", "-map", "1:a:0",
         "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-shortest", out],
        check=True)
    os.remove(video_tmp)
    log(f"[intro] final -> {out}")


if __name__ == "__main__":
    main()
