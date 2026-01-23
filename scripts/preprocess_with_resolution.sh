#!/usr/bin/env bash
set -euo pipefail

# Script để preprocess video với FPS và resolution cụ thể
# Usage: preprocess_with_resolution.sh <input_file> <output_file> [fps] [resolution]

INPUT_FILE="${1}"
OUTPUT_FILE="${2}"
FPS="${3:-25}"
RESOLUTION="${4:-1920x1080}"

GOP_SEC="${GOP_SEC:-0.5}"
CRF="${CRF:-23}"
PRESET="${PRESET:-veryfast}"

# Parse resolution (format: 1920x1080)
IFS='x' read -r WIDTH HEIGHT <<< "$RESOLUTION"

# Tính GOP theo frames
GOP_FRAMES="$(awk -v fps="$FPS" -v sec="$GOP_SEC" 'BEGIN{g=fps*sec; if(g<1) g=1; printf "%d", (g+0.5)}')"
if [ "$GOP_FRAMES" -lt 1 ]; then GOP_FRAMES=1; fi

echo "[INFO] Processing: $INPUT_FILE -> $OUTPUT_FILE"
echo "[INFO] FPS=$FPS, Resolution=${WIDTH}x${HEIGHT}"
echo "[INFO] GOP_SEC=$GOP_SEC => GOP_FRAMES=$GOP_FRAMES"
echo "[INFO] CRF=$CRF PRESET=$PRESET"

ffmpeg -y -hide_banner -loglevel warning \
  -fflags +genpts \
  -i "$INPUT_FILE" \
  -an -sn -dn \
  -vf "fps=${FPS},scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease,pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2,format=yuv420p" \
  -c:v libx264 -preset "$PRESET" -tune zerolatency \
  -profile:v baseline -level 4.1 \
  -crf "$CRF" \
  -g "$GOP_FRAMES" -keyint_min "$GOP_FRAMES" -sc_threshold 0 \
  -bf 0 \
  -x264-params "repeat-headers=1:open-gop=0" \
  -force_key_frames "expr:gte(t,n_forced*${GOP_SEC})" \
  -movflags +faststart \
  "$OUTPUT_FILE"

echo "[INFO] Done processing: $OUTPUT_FILE"

