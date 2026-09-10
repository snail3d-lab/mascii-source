#!/usr/bin/env python3
"""Mascii — feature-film -> ASCII video renderer (bitmap-atlas, vectorized).

Proven on Metropolis (1927) at ~70ms/frame single-core. Each output pixel
maps to its character-cell glyph via a precomputed index table, so a frame
is a handful of numpy gathers, not a per-cell python loop.

Config (env vars, with defaults tuned for a 4:3 film in a 16:9 container):
  ASCII_SRC      source movie path (default: ./metropolis_raw.mp4)
  ASCII_OUTDIR   segment output dir (default: ./out)
  ASCII_CROP     ffmpeg crop filter for the film region (default: crop=640:480:107:0)
  ASCII_LABEL    corner stamp text (default: empty = no stamp)
  ASCII_TOTAL    full-film duration in seconds (drives the resume loop below)

Usage (single segment):
  python3 renderer.py <start_sec> <dur_sec> <seg_idx>
Writes: $ASCII_OUTDIR/seg_<idx>.mp4  (+ err_<idx>.log for ffmpeg stderr)

Usage (resume driver for the whole film):
  ASCII_TOTAL=8997.5 python3 renderer.py
Runs seg_00, seg_01, ... at 900s each, skipping any that already exist.
"""
import os
import subprocess
import sys
import time

import numpy as np
from PIL import Image, ImageDraw, ImageFont

FPS = 24
VW, VH = 1920, 1080
REGION_W = 1440             # 4:3 film region centered in 16:9
FONT_SIZE = 14
SEG_DUR = 900               # 15-min segments for the full-film driver
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.environ.get("ASCII_SRC", os.path.join(HERE, "metropolis_raw.mp4"))
OUTDIR = os.environ.get("ASCII_OUTDIR", os.path.join(HERE, "out"))
SRC_CROP = os.environ.get("ASCII_CROP", "crop=640:480:107:0")
LABEL = os.environ.get("ASCII_LABEL", "")

# Neutral 12-step gray ramp, slight cool tint in mids (true to B&W originals)
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


def log(*a):
    print(*a, flush=True)


def build():
    fp = font_path()
    font = ImageFont.truetype(fp, FONT_SIZE)
    asc, desc = font.getmetrics()
    ch = asc + desc                      # cell height: getmetrics(), NOT textbbox()
    cw = font.getbbox("M")[2]            # cell width
    rows = VH // ch
    cols = REGION_W // cw
    ox = (VW - cols * cw) // 2
    oy = (VH - rows * ch) // 2

    # Bitmap atlas: every palette char pre-rendered to float32
    bm = {}
    for c in PAL:
        img = Image.new("L", (cw, ch), 0)
        if c != " ":
            ImageDraw.Draw(img).text((0, 0), c, fill=255, font=font)
        bm[c] = np.array(img, dtype=np.float32) / 255.0
    atlas = np.concatenate([bm[c].ravel() for c in PAL])  # (N*ch*cw,)

    # Per-pixel offset-within-cell table for the whole output canvas
    ypx = np.arange(VH, dtype=np.int32)
    xpx = np.arange(VW, dtype=np.int32)
    row = (ypx - oy) // ch
    pyl = ypx - oy - row * ch
    col = (xpx - ox) // cw
    pxl = xpx - ox - col * cw
    ok_y = (row >= 0) & (row < rows) & (pyl >= 0) & (pyl < ch)
    ok_x = (col >= 0) & (col < cols) & (pxl >= 0) & (pxl < cw)
    O2 = np.where(ok_y[:, None] & ok_x[None, :], pyl[:, None] * cw + pxl[None, :], 0).astype(np.int32)

    # Vignette: subtle, 22% dimming at the canvas corners
    yy, xx = np.mgrid[0:VH, 0:VW].astype(np.float32)
    d = np.sqrt(((xx - VW / 2) / (VW / 2)) ** 2 + ((yy - VH / 2) / (VH / 2)) ** 2)
    vig = np.clip(1.0 - 0.22 * (d / 1.42) ** 2.4, 0, 1)

    # Scanlines: every 2nd row slightly dimmer
    scan = np.ones(VH, dtype=np.float32)
    scan[1::2] = 0.94

    # Optional corner archive stamp
    if LABEL:
        label_img = Image.new("L", (int(VW), int(VH)), 0)
        lf = ImageFont.truetype(fp, 18)
        bbox = ImageDraw.Draw(label_img).textbbox((0, 0), LABEL, font=lf)
        lw = bbox[2] - bbox[0]
        ImageDraw.Draw(label_img).text((VW - lw - 30 - bbox[0], 24 - bbox[1]), LABEL, fill=255, font=lf)
        lbl = (np.array(label_img, dtype=np.float32) / 255.0)[:, :, None] * np.array((120, 120, 124), dtype=np.float32)
        lbl = np.where(lbl.max(axis=2, keepdims=True) > 0, lbl, 0).astype(np.float32)
    else:
        lbl = None

    return dict(font=font, ch=ch, cw=cw, rows=rows, cols=cols, ox=ox, oy=oy,
                atlas=atlas, O2=O2, vig=vig, scan=scan, lbl=lbl,
                hcells=ch * cw, pal=PALCOL,
                box=(oy, oy + rows * ch, ox, ox + cols * cw))


G = None
_lo = None
_hi = None


def render_frame(lum, rng, fl):
    """lum: (rows, cols) uint8 gray. Returns (VH, VW, 3) uint8 canvas."""
    global _lo, _hi
    g = G
    f = lum.astype(np.float32) / 255.0

    # Adaptive tonemap with EMA so levels don't pump between shots
    lo, hi = np.percentile(f, [1.5, 98.5])
    _lo = lo if _lo is None else 0.9 * _lo + 0.1 * float(lo)
    _hi = hi if _hi is None else 0.9 * _hi + 0.1 * float(hi)
    if _hi - _lo < 0.04:
        _hi = _lo + 0.04
    v = np.clip((f - _lo) / (_hi - _lo), 0, 1) ** 0.92

    cidx = np.clip((v * N).astype(np.int32), 0, N - 1)
    # NOTE: PALCOL is 2-D (N,3); a 2-D fancy index adds an axis, so ravel+reshape.
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

    # Film grain: half-res gaussian noise, upsampled
    n = rng.standard_normal((VH // 2, VW // 2)).astype(np.float32) * 2.4
    full += np.repeat(np.repeat(n, 2, axis=0), 2, axis=1)[:VH, :VW, None]

    if g["lbl"] is not None:
        full = np.maximum(full, g["lbl"])
    return np.clip(full, 0, 255).astype(np.uint8)


def render_segment(start, dur, seg):
    global G, _lo, _hi
    os.makedirs(OUTDIR, exist_ok=True)
    G = build()
    _lo = _hi = None
    log(f"[seg {seg:02d}] grid {G['cols']}x{G['rows']} cw={G['cw']} ch={G['ch']} -> {start}s for {dur}s")

    n = int(dur * FPS)
    fw, fh = G["cols"], G["rows"]
    src = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-ss", f"{start}", "-i", SRC,
         "-vf", f"{SRC_CROP},scale={fw}:{fh}:flags=area",
         "-pix_fmt", "gray", "-f", "rawvideo", "-"],
        stdout=subprocess.PIPE)

    out = os.path.join(OUTDIR, f"seg_{seg:02d}.mp4")
    enc = subprocess.Popen(
        ["ffmpeg", "-y", "-v", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
         "-s", f"{VW}x{VH}", "-r", str(FPS), "-i", "pipe:0",
         "-c:v", "libx264", "-preset", "fast", "-crf", "22",
         "-pix_fmt", "yuv420p", out],
        stdin=subprocess.PIPE, stderr=open(f"{OUTDIR}/err_{seg:02d}.log", "w"))

    rng = np.random.default_rng(9000 + seg)
    fl = 1.0
    t0 = time.time()
    fs = fw * fh
    for i in range(n):
        raw = src.stdout.read(fs)
        if len(raw) < fs:
            log(f"[seg {seg:02d}] short read at frame {i}, stopping")
            break
        frame = np.frombuffer(raw, dtype=np.uint8).reshape(fh, fw)
        fl = 0.92 * fl + 0.08 * (1.0 + float(rng.standard_normal()) * 0.018)
        canvas = render_frame(frame, rng, fl)
        enc.stdin.write(canvas.tobytes())
        if i % 2000 == 0:
            el = time.time() - t0
            eta = el / max(1, i + 1) * (n - i - 1)
            log(f"[seg {seg:02d}] {i}/{n} ({100*i/n:.1f}%) {1000*el/max(1,i+1):.0f}ms/f eta {eta/60:.1f}m")

    src.stdout.close(); src.wait()
    enc.stdin.close(); enc.wait()
    log(f"[seg {seg:02d}] done in {(time.time()-t0)/60:.1f}m -> {out}")


def main():
    if len(sys.argv) == 4:
        # single segment: renderer.py <start_sec> <dur_sec> <seg_idx>
        render_segment(float(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3]))
        return

    # resume driver: run the whole film in SEG_DUR-second segments
    total = float(os.environ.get("ASCII_TOTAL", "8997.5"))
    i = 0
    start = 0.0
    log(f"resume driver: total={total}s, segment={SEG_DUR}s")
    while start < total - 1:
        out = os.path.join(OUTDIR, f"seg_{i:02d}.mp4")
        if os.path.exists(out) and os.path.getsize(out) > 1_000_000:
            log(f"[seg {i:02d}] exists, skipping")
        else:
            render_segment(start, SEG_DUR, i)
        i += 1
        start += SEG_DUR
    log("ALL SEGMENTS DONE")


if __name__ == "__main__":
    main()
