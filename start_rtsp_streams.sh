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

# Clean videos_raw and videos_clean directories
echo "[INFO] Cleaning videos_raw and videos_clean directories..."
rm -f videos_raw/cam*.mp4 videos_raw/cam*.mkv videos_raw/cam*.mov videos_raw/cam*.avi videos_raw/cam*.ts
# Use docker to clean videos_clean (files may be owned by root) - clean all video files
docker run --rm -v "$SCRIPT_DIR/videos_clean:/videos_clean" --entrypoint /bin/sh lscr.io/linuxserver/ffmpeg:latest -c "rm -f /videos_clean/*.mp4 /videos_clean/*.mkv /videos_clean/*.mov /videos_clean/*.avi /videos_clean/*.ts" 2>/dev/null || true

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

# Preprocess videos with resolution
echo ""
echo "[INFO] Preprocessing videos with FPS=$FPS and Resolution=$RESOLUTION..."
for i in "${!VIDEOS[@]}"; do
  video="${VIDEOS[$i]}"
  ext="${video##*.}"
  cam_name="cam${i}.${ext}"
  input_file="videos_raw/$cam_name"
  output_file="videos_clean/cam${i}.mp4"
  
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

