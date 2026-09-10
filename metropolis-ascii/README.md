# Mascii — Metropolis ASCII pipeline (desktop source)

Source + pipeline for the Mascii ASCII movie renderer. The delivered video is
`~/Desktop/asciimetropolis.mp4` (12 GB, 9071.7 s) — do not keep it in this
repo.

## What's here

| File | Purpose |
|---|---|
| `metropolis_raw.mp4` | Re-downloadable 841 MB archive.org source (854x480 h264, 24fps, 8997.5 s, Huppertz score) |
| `intro_talkinghead_60s.mov` | 60.4 s 640x480 talking-head intro (original audio) |
| `intro_snap_13s.mov` | 13.8 s 640x480 finger-snap clip (original audio) |
| `renderer.py` | Full-film bitmap-atlas ASCII renderer (15-min resumable segments) |
| `render_intro_ascii.py` | Short-clip ASCII renderer (no crop, 4:3 source → 1080p 24fps) |
| `stitch.sh` | Segments → `metropolis_ascii_full.mp4` (+ original audio, brightness lift) |
| `intro_stitch.sh` | Phase 7: stream-copy intro(s) + master → `_v2.mp4` (master never re-encoded) |

## Re-render from scratch

```bash
PY=/Users/youruser/.hermes/hermes-agent/venv/bin/python   # system python3 numpy is BROKEN
FF=/opt/homebrew/bin/ffmpeg

# 1) 10 x 15-min segments (resumable; run 2 in parallel if you like):
ASCII_TOTAL=8997.5 $PY renderer.py > full_render.log 2>&1   # in a background terminal

# 2) stitch + audio + brightness lift (~17 min):
./stitch.sh            # -> metropolis_ascii_full.mp4 (~11 GB)

# 3) intro version (v2): encode clips to the master profile, then:
$PY render_intro_ascii.py intro_snap_13s.mov snap_ascii.mp4
$FF -y -i intro_talkinghead_60s.mov \
  -vf "scale=1440:1080:flags=lanczos,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=24" \
  -c:v h264_videotoolbox -b:v 10000k -pix_fmt yuv420p -c:a aac -b:a 192k \
  talkinghead_encoded.mp4
./intro_stitch.sh talkinghead_encoded.mp4 snap_ascii.mp4   # -> metropolis_ascii_full_v2.mp4
```

## Source (re-download if needed)

```
curl -L -o metropolis_raw.mp4 "https://archive.org/download/metropolis-1927-bdrip-1080p-x-265-dts-hd-ma-5.1-d-0ct-0r-lew-sev/Metropolis%201927%20BDrip%201080p%20x265%20DTS-HD%20MA%205.1%20D0ct0rLew%5BSEV%5D.mp4"
```

Item: `metropolis-1927-bdrip-1080p-x-265-dts-hd-ma-5.1-d-0ct-0r-lew-sev`
(PD mark license, full uncut).

## Proven settings

- Grid: Menlo 14px → 8x17 px cells → 180 x 63 over a 1440 px centered region
- Palette ` .:-=+*#%@`, neutral 12-step gray ramp, crop `640:480:107:0`
- Effects: vignette 0.22 / scanlines 0.94 / grain ±2.4 / flicker EMA
- User-approved look: neutral gray (NOT amber), +15% at stitch
  (`eq=gamma=0.85:brightness=0.03`), original audio untouched
