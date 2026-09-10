#!/usr/bin/env bash
# Mascii — Phase 7: prepend intro clip(s) to the finished master WITHOUT
# re-encoding the master. Stream-copy concat keeps the master's
# video+audio byte-identical (its score can't drift); only the NEW small
# segments get encoded, and they must match the master's codec profile.
#
# Master profile (from stitch.sh): h264_videotoolbox -b:v 10000k yuv420p,
# 1920x1080 24fps, aac 192k.
#
# Usage:
#   ./intro_stitch.sh intro_1.mp4 [intro_2.mp4 ...]
#
# For a talking-head 4:3 clip, encode it first to the master profile:
#   ffmpeg -y -i talkinghead.mov \
#     -vf "scale=1440:1080:flags=lanczos,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=24" \
#     -c:v h264_videotoolbox -b:v 10000k -pix_fmt yuv420p -c:a aac -b:a 192k \
#     intro_encoded.mp4
#
# For an ASCII transition clip, use render_intro_ascii.py (it already emits
# the master profile).
#
# Output: metropolis_ascii_full_v2.mp4
set -euo pipefail
cd "$(dirname "$0")"

FFMPEG=/opt/homebrew/bin/ffmpeg
FFPROBE=/opt/homebrew/bin/ffprobe

MASTER="${MASTER:-metropolis_ascii_full.mp4}"
OUT="${OUT:-metropolis_ascii_full_v2.mp4}"

if [ $# -lt 1 ]; then
  echo "usage: ./intro_stitch.sh intro_1.mp4 [intro_2.mp4 ...]"
  echo "   (MASTER=metropolis_ascii_full.mp4 OUT=... to override defaults)"
  exit 1
fi

INTROS=("$@")

echo "== intro stitch: ${#INTROS[@]} intro(s) + $MASTER =="

# 1) verify SPS/PPS byte-identical across master + every intro
#    (required for a clean -c copy concat; VideoToolbox on the same machine
#    with the same settings produces matching SPS/PPS).
echo "-- verifying SPS/PPS match --"
REF=""
for f in "$MASTER" "${INTROS[@]}"; do
  "$FFMPEG" -v error -y -t 0.2 -i "$f" -map 0:v:0 -an -c copy -f h264 /tmp/mascii_sps.h264
  sig=$(xxd -l 48 /tmp/mascii_sps.h264 | head -4 | tr -d ' \n')
  if [ -z "$REF" ]; then
    REF="$sig"
    echo "   $f: $sig"
  else
    if [ "$sig" != "$REF" ]; then
      echo "ERROR: $f SPS/PPS differs from $MASTER — re-encode it with the master profile"
      exit 1
    fi
    echo "   $f: matches"
  fi
done

# 2) stream-copy concat: intro(s) + master
echo "-- stream-copy concat (12GB copies in ~1 min) --"
: > concat_final.txt
for f in "${INTROS[@]}"; do echo "file '$f'" >> concat_final.txt; done
echo "file '$MASTER'" >> concat_final.txt

"$FFMPEG" -y -v error -f concat -safe 0 -i concat_final.txt -c copy "$OUT"

# 3) verify duration = sum of parts
echo "-- verifying duration --"
total=0
for f in "${INTROS[@]}"; do
  d=$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$f")
  total=$(echo "$total + $d" | bc -l)
done
md=$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$MASTER")
expected=$(echo "$total + $md" | bc -l)
actual=$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$OUT")
echo "   expected $expected s, got $actual s"

# 4) audio junction check (volumedetect around each junction)
echo "-- audio junction checks (mean_volume at each cut) --"
acc=0
for f in "${INTROS[@]}"; do
  d=$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$f")
  acc=$(echo "$acc + $d" | bc -l)
  "$FFMPEG" -hide_banner -ss "$(echo "$acc - 3" | bc -l)" -t 6 -i "$OUT" \
    -vn -af volumedetect -f null - 2>&1 | grep -E "mean_volume|Junction" | sed "s/^/   @${acc}s /" || true
done
rm -f /tmp/mascii_sps.h264 concat_final.txt
echo "== done: $OUT =="
