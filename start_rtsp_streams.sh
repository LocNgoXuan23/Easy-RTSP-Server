#!/usr/bin/env bash
set -euo pipefail

# Script để start RTSP streams từ danh sách video paths
# Usage: ./start_rtsp_streams.sh [<video1> <video2> ...] [--fps FPS] [--resolution WIDTHxHEIGHT]
#        Nếu không có arguments, sẽ đọc từ video_paths.txt

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Default values (hardcoded)
FPS="25"
RESOLUTION="1920x1080"
VIDEO_PATHS_FILE="${VIDEO_PATHS_FILE:-video_paths.txt}"

# Parse arguments
VIDEOS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --fps)
      FPS="$2"
      shift 2
      ;;
    --resolution)
      RESOLUTION="$2"
      shift 2
      ;;
    *)
      VIDEOS+=("$1")
      shift
      ;;
  esac
done

# If no videos provided as arguments, read from video_paths.txt
if [ ${#VIDEOS[@]} -eq 0 ]; then
  if [ ! -f "$VIDEO_PATHS_FILE" ]; then
    echo "[ERROR] No video files provided and $VIDEO_PATHS_FILE not found!"
    echo "Usage: $0 [<video1> <video2> ...] [--fps FPS] [--resolution WIDTHxHEIGHT]"
    echo "       Or create $VIDEO_PATHS_FILE with video paths (one per line)"
    echo "Example: $0 ./videos/test.mp4 ./videos/car.mp4 --fps 25 --resolution 1920x1080"
    exit 1
  fi
  
  echo "[INFO] Reading video paths from $VIDEO_PATHS_FILE..."
  # Read video paths from file, ignoring comments and empty lines
  while IFS= read -r line || [ -n "$line" ]; do
    # Remove leading/trailing whitespace
    line=$(echo "$line" | xargs)
    # Skip empty lines and comments
    if [ -n "$line" ] && [[ ! "$line" =~ ^[[:space:]]*# ]]; then
      VIDEOS+=("$line")
    fi
  done < "$VIDEO_PATHS_FILE"
  
  if [ ${#VIDEOS[@]} -eq 0 ]; then
    echo "[ERROR] No valid video paths found in $VIDEO_PATHS_FILE!"
    exit 1
  fi
fi

# ==========================================
# Helper Functions for Cache Management
# ==========================================

# Calculate MD5 hash of a file
calculate_file_hash() {
  local file_path="$1"
  if [ ! -f "$file_path" ]; then
    echo ""
    return
  fi
  
  # Try md5sum first, fallback to sha256sum
  if command -v md5sum >/dev/null 2>&1; then
    md5sum "$file_path" 2>/dev/null | cut -d' ' -f1 || echo ""
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file_path" 2>/dev/null | cut -d' ' -f1 | cut -c1-32 || echo ""
  else
    echo ""
  fi
}

# Load metadata from JSON file
load_metadata() {
  local meta_file="$1"
  if [ ! -f "$meta_file" ]; then
    echo ""
    return
  fi
  
  # Use jq to parse JSON, return as JSON string if valid
  if command -v jq >/dev/null 2>&1; then
    jq -c '.' "$meta_file" 2>/dev/null || echo ""
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import json, sys; json.load(open('$meta_file'))" 2>/dev/null && cat "$meta_file" || echo ""
  else
    echo ""
  fi
}

# Save metadata to JSON file
save_metadata() {
  local meta_file="$1"
  local input_hash="$2"
  local input_path="$3"
  local fps="$4"
  local resolution="$5"
  local gop_sec="$6"
  local crf="$7"
  local preset="$8"
  
  local created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
  
  # Create JSON using jq or python3
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg input_hash "$input_hash" \
      --arg input_path "$input_path" \
      --argjson fps "$fps" \
      --arg resolution "$resolution" \
      --argjson gop_sec "$gop_sec" \
      --argjson crf "$crf" \
      --arg preset "$preset" \
      --arg created_at "$created_at" \
      --arg version "1.0" \
      '{
        input_hash: $input_hash,
        input_path: $input_path,
        fps: $fps,
        resolution: $resolution,
        gop_sec: $gop_sec,
        crf: $crf,
        preset: $preset,
        created_at: $created_at,
        version: $version
      }' > "$meta_file" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 << EOF > "$meta_file" 2>/dev/null
import json
import sys

data = {
    "input_hash": "$input_hash",
    "input_path": "$input_path",
    "fps": $fps,
    "resolution": "$resolution",
    "gop_sec": $gop_sec,
    "crf": $crf,
    "preset": "$preset",
    "created_at": "$created_at",
    "version": "1.0"
}

print(json.dumps(data, indent=2))
EOF
  else
    # Fallback: manual JSON creation (simple but works)
    cat > "$meta_file" << EOF
{
  "input_hash": "$input_hash",
  "input_path": "$input_path",
  "fps": $fps,
  "resolution": "$resolution",
  "gop_sec": $gop_sec,
  "crf": $crf,
  "preset": "$preset",
  "created_at": "$created_at",
  "version": "1.0"
}
EOF
  fi
}

# Check if preprocessing should be skipped (cache hit)
should_skip_preprocess() {
  local input_file="$1"
  local output_file="$2"
  local meta_file="$3"
  local expected_fps="$4"
  local expected_resolution="$5"
  local expected_gop_sec="$6"
  local expected_crf="$7"
  local expected_preset="$8"
  
  # Check if output file exists
  if [ ! -f "$output_file" ]; then
    return 1  # Need to preprocess
  fi
  
  # Check if metadata file exists
  if [ ! -f "$meta_file" ]; then
    return 1  # Need to preprocess (no metadata)
  fi
  
  # Load metadata
  local metadata_json=$(load_metadata "$meta_file")
  if [ -z "$metadata_json" ]; then
    return 1  # Need to preprocess (corrupt metadata)
  fi
  
  # Parse metadata using jq
  if command -v jq >/dev/null 2>&1; then
    local stored_hash=$(echo "$metadata_json" | jq -r '.input_hash // empty' 2>/dev/null)
    local stored_fps=$(echo "$metadata_json" | jq -r '.fps // empty' 2>/dev/null)
    local stored_resolution=$(echo "$metadata_json" | jq -r '.resolution // empty' 2>/dev/null)
    local stored_gop_sec=$(echo "$metadata_json" | jq -r '.gop_sec // empty' 2>/dev/null)
    local stored_crf=$(echo "$metadata_json" | jq -r '.crf // empty' 2>/dev/null)
    local stored_preset=$(echo "$metadata_json" | jq -r '.preset // empty' 2>/dev/null)
  elif command -v python3 >/dev/null 2>&1; then
    local stored_hash=$(python3 -c "import json, sys; print(json.load(open('$meta_file')).get('input_hash', ''))" 2>/dev/null || echo "")
    local stored_fps=$(python3 -c "import json, sys; print(json.load(open('$meta_file')).get('fps', ''))" 2>/dev/null || echo "")
    local stored_resolution=$(python3 -c "import json, sys; print(json.load(open('$meta_file')).get('resolution', ''))" 2>/dev/null || echo "")
    local stored_gop_sec=$(python3 -c "import json, sys; print(json.load(open('$meta_file')).get('gop_sec', ''))" 2>/dev/null || echo "")
    local stored_crf=$(python3 -c "import json, sys; print(json.load(open('$meta_file')).get('crf', ''))" 2>/dev/null || echo "")
    local stored_preset=$(python3 -c "import json, sys; print(json.load(open('$meta_file')).get('preset', ''))" 2>/dev/null || echo "")
  else
    # Fallback: basic grep parsing (not perfect but works)
    local stored_hash=$(grep -o '"input_hash": "[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4 || echo "")
    local stored_fps=$(grep -o '"fps": [0-9]*' "$meta_file" 2>/dev/null | grep -o '[0-9]*' || echo "")
    local stored_resolution=$(grep -o '"resolution": "[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4 || echo "")
    local stored_gop_sec=$(grep -o '"gop_sec": [0-9.]*' "$meta_file" 2>/dev/null | grep -o '[0-9.]*' || echo "")
    local stored_crf=$(grep -o '"crf": [0-9]*' "$meta_file" 2>/dev/null | grep -o '[0-9]*' || echo "")
    local stored_preset=$(grep -o '"preset": "[^"]*"' "$meta_file" 2>/dev/null | cut -d'"' -f4 || echo "")
  fi
  
  # Check if any field is empty (parsing failed)
  if [ -z "$stored_hash" ] || [ -z "$stored_fps" ] || [ -z "$stored_resolution" ]; then
    return 1  # Need to preprocess (parsing failed)
  fi
  
  # Calculate current input file hash
  local current_hash=$(calculate_file_hash "$input_file")
  if [ -z "$current_hash" ]; then
    return 1  # Need to preprocess (hash calculation failed)
  fi
  
  # Compare hash
  if [ "$current_hash" != "$stored_hash" ]; then
    return 1  # Need to preprocess (input file changed)
  fi
  
  # Compare config values (handle float comparison for gop_sec)
  if [ "$stored_fps" != "$expected_fps" ] || \
     [ "$stored_resolution" != "$expected_resolution" ] || \
     [ "$stored_crf" != "$expected_crf" ] || \
     [ "$stored_preset" != "$expected_preset" ]; then
    return 1  # Need to preprocess (config changed)
  fi
  
  # Compare gop_sec (float comparison using awk)
  local gop_match=$(awk -v stored="$stored_gop_sec" -v expected="$expected_gop_sec" \
    'BEGIN {
      diff = (stored - expected) < 0 ? -(stored - expected) : (stored - expected);
      if (diff < 0.0001) print "match"; else print "nomatch";
    }' 2>/dev/null || echo "nomatch")
  if [ "$gop_match" != "match" ]; then
    return 1  # Need to preprocess (gop_sec changed)
  fi
  
  # All checks passed - cache hit!
  return 0
}

# Clean unused output files (selective clean)
clean_unused_outputs() {
  local videos_list=("$@")
  local max_index=$(( ${#videos_list[@]} - 1 ))
  
  echo "[INFO] Cleaning unused output files..."
  
  # Find all cam*.mp4 files in videos_clean
  shopt -s nullglob
  local existing_files=(videos_clean/cam*.mp4)
  shopt -u nullglob
  
  local cleaned_count=0
  for output_file in "${existing_files[@]}"; do
    # Extract cam index from filename (cam0.mp4 -> 0)
    local basename_file=$(basename "$output_file")
    local cam_index=$(echo "$basename_file" | grep -o 'cam[0-9]*' | grep -o '[0-9]*' || echo "")
    
    # Check if cam_index is valid number
    if [ -z "$cam_index" ] || ! [[ "$cam_index" =~ ^[0-9]+$ ]]; then
      continue
    fi
    
    # Check if this index is still in use
    if [ "$cam_index" -gt "$max_index" ]; then
      # This cam index is not in current videos list - remove it
      echo "[INFO] Removing unused output: $output_file"
      docker run --rm -v "$SCRIPT_DIR/videos_clean:/videos_clean" --entrypoint /bin/sh lscr.io/linuxserver/ffmpeg:latest -c "rm -f /videos_clean/$basename_file /videos_clean/$basename_file.meta" 2>/dev/null || rm -f "$output_file" "${output_file}.meta"
      cleaned_count=$((cleaned_count + 1))
    fi
  done
  
  if [ $cleaned_count -eq 0 ]; then
    echo "[INFO] No unused output files to clean"
  else
    echo "[INFO] Cleaned $cleaned_count unused output file(s)"
  fi
}

echo "=========================================="
echo "RTSP Stream Setup"
echo "=========================================="
echo "[INFO] FPS: $FPS"
echo "[INFO] Resolution: $RESOLUTION"
echo "[INFO] Number of videos: ${#VIDEOS[@]}"
echo ""

# Stop existing containers if running
echo "[INFO] Stopping existing containers..."
docker compose down >/dev/null 2>&1 || true

# Create directories
mkdir -p videos_raw videos_clean

# Clean videos_raw directory (always clean raw files)
echo "[INFO] Cleaning videos_raw directory..."
rm -f videos_raw/cam*.mp4 videos_raw/cam*.mkv videos_raw/cam*.mov videos_raw/cam*.avi videos_raw/cam*.ts

# Clean unused output files in videos_clean (selective clean - preserve cache)
clean_unused_outputs "${VIDEOS[@]}"

# Copy videos to videos_raw with cam0, cam1, ... naming
echo "[INFO] Copying videos to videos_raw..."
for i in "${!VIDEOS[@]}"; do
  video="${VIDEOS[$i]}"
  if [ ! -f "$video" ]; then
    echo "[ERROR] Video file not found: $video"
    exit 1
  fi
  
  # Get file extension
  ext="${video##*.}"
  cam_name="cam${i}.${ext}"
  cp "$video" "videos_raw/$cam_name"
  echo "[INFO] Copied: $video -> videos_raw/$cam_name"
done

# Preprocess videos with resolution (with cache support)
echo ""
echo "[INFO] Preprocessing videos with FPS=$FPS and Resolution=$RESOLUTION..."
for i in "${!VIDEOS[@]}"; do
  video="${VIDEOS[$i]}"
  ext="${video##*.}"
  cam_name="cam${i}.${ext}"
  input_file="videos_raw/$cam_name"
  output_file="videos_clean/cam${i}.mp4"
  meta_file="videos_clean/cam${i}.mp4.meta"
  
  # Get absolute path of original video
  original_video_path=$(cd "$(dirname "$video")" && pwd)/$(basename "$video")
  
  # Get config values
  current_fps="$FPS"
  current_resolution="$RESOLUTION"
  current_gop_sec="${GOP_SEC:-0.5}"
  current_crf="${CRF:-23}"
  current_preset="${PRESET:-veryfast}"
  
  # Check cache
  if should_skip_preprocess "$input_file" "$output_file" "$meta_file" \
                            "$current_fps" "$current_resolution" \
                            "$current_gop_sec" "$current_crf" "$current_preset"; then
    echo "[INFO] Skipping preprocessing for cam${i} (cache valid)"
    echo "       Using cached: $output_file"
    continue
  fi
  
  echo "[INFO] Preprocessing: $cam_name -> cam${i}.mp4"
  
  docker run --rm \
    -v "$SCRIPT_DIR/videos_raw:/videos_raw:ro" \
    -v "$SCRIPT_DIR/videos_clean:/videos_clean" \
    -v "$SCRIPT_DIR/scripts:/scripts:ro" \
    -e FPS="$FPS" \
    -e RESOLUTION="$RESOLUTION" \
    -e GOP_SEC="${GOP_SEC:-0.5}" \
    -e CRF="${CRF:-23}" \
    -e PRESET="${PRESET:-veryfast}" \
    --entrypoint /bin/bash \
    lscr.io/linuxserver/ffmpeg:latest \
    /scripts/preprocess_with_resolution.sh \
    "/videos_raw/$cam_name" "/videos_clean/cam${i}.mp4" "$FPS" "$RESOLUTION"
  
  # Save metadata after successful preprocessing
  if [ -f "$output_file" ]; then
    input_hash=$(calculate_file_hash "$input_file")
    if [ -n "$input_hash" ]; then
      save_metadata "$meta_file" "$input_hash" "$original_video_path" \
                    "$current_fps" "$current_resolution" \
                    "$current_gop_sec" "$current_crf" "$current_preset"
      echo "[INFO] Saved metadata for cam${i}"
    else
      echo "[WARNING] Failed to calculate hash for cam${i}, metadata not saved"
    fi
  else
    echo "[WARNING] Output file not found after preprocessing cam${i}"
  fi
done

echo ""
echo "[INFO] Preprocessing completed!"

# Start mediamtx and streamer
echo ""
echo "[INFO] Starting MediaMTX and Streamer containers..."
docker compose up -d mediamtx streamer

# Function to check if container is running
check_container_running() {
  local container_name=$1
  local max_attempts=10
  local attempt=0
  
  while [ $attempt -lt $max_attempts ]; do
    local status=$(docker inspect "$container_name" --format='{{.State.Status}}' 2>/dev/null || echo "not_found")
    
    if [ "$status" = "running" ]; then
      return 0
    elif [ "$status" = "exited" ]; then
      local exit_code=$(docker inspect "$container_name" --format='{{.State.ExitCode}}' 2>/dev/null || echo "unknown")
      echo "[ERROR] Container $container_name exited with code: $exit_code"
      docker logs "$container_name" --tail 20 2>&1 | sed 's/^/[LOG] /'
      return 1
    fi
    
    attempt=$((attempt + 1))
    sleep 1
  done
  
  echo "[ERROR] Container $container_name failed to start after ${max_attempts} seconds"
  docker logs "$container_name" --tail 20 2>&1 | sed 's/^/[LOG] /'
  return 1
}

# Check if containers are running with retry logic
echo "[INFO] Waiting for containers to start..."
if ! check_container_running "mediamtx"; then
  echo "[ERROR] MediaMTX container failed to start!"
  exit 1
fi

if ! check_container_running "fake_cams_streamer"; then
  echo "[ERROR] Streamer container failed to start!"
  exit 1
fi

# Wait a bit more for streams to be published
sleep 2

echo ""
echo "=========================================="
echo "RTSP Streams are ready!"
echo "=========================================="
echo ""
echo "RTSP URLs:"
for i in "${!VIDEOS[@]}"; do
  video="${VIDEOS[$i]}"
  video_name="$(basename "$video")"
  rtsp_url="rtsp://127.0.0.1:8554/cam${i}"
  echo "  [$i] $video_name -> $rtsp_url"
done
echo ""
echo "You can now open these URLs in VLC or any RTSP client."
echo ""
echo "To stop all streams, run: ./stop_rtsp_streams.sh"
echo ""

