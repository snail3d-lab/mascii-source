#!/usr/bin/env bash
# Mascii — stitch the full-movie ASCII segments + original audio.
#
# Run AFTER all segments exist in out/ (seg_00.mp4 .. seg_<TOTAL-1>.mp4).
#   1) extract original audio to WAV (drops any stray embedded data stream)
#   2) concat-list all segments
#   3) brightness-lift + stream-copy-free encode via h264_videotoolbox
#
# Output: metropolis_ascii_full.mp4
set -euo pipefail
cd "$(dirname "$0")"

FFMPEG=/opt/homebrew/bin/ffmpeg
FFPROBE=/opt/homebrew/bin/ffprobe

RAW="${RAW:-metropolis_raw.mp4}"
OUT="${OUT:-metropolis_ascii_full.mp4}"
# Total number of segments (default 10 for Metropolis = ~2h30m at 900s each).
TOTAL="${TOTAL:-10}"

echo "== Mascii full-movie stitch (TOTAL=$TOTAL) =="

# 1) verify every segment has a readable moov atom (crashed ones don't).
echo "-- verifying $TOTAL segments have moov atoms --"
for i in $(seq 0 $((TOTAL - 1))); do
  idx=$(printf '%02d' "$i")
  f="out/seg_$idx.mp4"
  if [ ! -f "$f" ]; then
    echo "MISSING $f"; exit 1
  fi
  "$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$f" >/dev/null \
    || { echo "UNREADABLE (no moov) $f — delete and re-render that segment"; exit 1; }
done
echo "   all $TOTAL segments readable."

# 2) extract original audio to WAV. -map 0:a:0 drops stray text data streams
#    (see SKILL.md pitfall #9). WAV cannot carry data streams.
echo "-- extracting audio -> audio.wav --"
"$FFMPEG" -y -v error -i "$RAW" -map 0:a:0 -vn -c:a pcm_s16le audio.wav

# 3) build the concat list.
echo "-- writing concat.txt --"
: > concat.txt
for i in $(seq 0 $((TOTAL - 1))); do
  idx=$(printf '%02d' "$i")
  echo "file 'out/seg_$idx.mp4'" >> concat.txt
done

# 4) brightness-lift + stitch + clean audio.
#    User-approved look: ~15% brighter (eq=gamma=0.85:brightness=0.03).
#    h264_videotoolbox is ~2.3x faster than libx264 veryfast on Apple Silicon.
echo "-- stitching (h264_videotbox, ~17 min for Metropolis) --"
"$FFMPEG" -y -f concat -safe 0 -i concat.txt -i audio.wav \
  -map 0:v:0 -map 1:a:0 \
  -vf "eq=gamma=0.85:brightness=0.03" \
  -c:v h264_videotoolbox -b:v 10000k -pix_fmt yuv420p \
  -c:a aac -b:a 192k -shortest "$OUT"

echo "== done: $OUT =="
"$FFPROBE" -v error -show_entries format=duration:stream=codec_name,codec_type \
  -of default=noprint_wrappers=1 "$OUT"
