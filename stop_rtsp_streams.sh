#!/usr/bin/env bash
set -euo pipefail

# Script để stop tất cả RTSP streams
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "[INFO] Stopping all RTSP streams..."
docker compose down

echo "[INFO] All RTSP streams have been stopped."

