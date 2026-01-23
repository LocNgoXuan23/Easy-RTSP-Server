# RTSP Server

A Docker-based RTSP streaming server that publishes multiple video files as looping RTSP streams. Stream your local videos over RTSP protocol with minimal setup.

## Features

- 🚀 **Simple Setup**: Start streaming with just 3 files
- 📹 **Multiple Streams**: Stream multiple videos simultaneously
- 🔄 **Auto-looping**: Videos automatically loop when finished
- 🐳 **Docker-based**: Isolated environment with MediaMTX and FFmpeg
- ⚙️ **Configurable**: Adjust FPS and resolution per your needs

## Prerequisites

- **Docker** and **Docker Compose** installed
- **RTSP client** (e.g., VLC Media Player) for viewing streams

## Quick Start

### 1. Configure Video Paths

Edit `video_paths.txt` and add your video file paths (one per line):

```txt
./videos/video1.mp4
./videos/video2.mp4
./videos/video3.mp4
```

> **Note**: Use relative paths from the project root directory.

### 2. Start RTSP Streams

Run the start script:

```bash
./start_rtsp_streams.sh
```

The script will:
- Preprocess videos for optimal streaming
- Start MediaMTX RTSP server
- Publish all videos as RTSP streams

### 3. Access Your Streams

Open the RTSP URLs in VLC or any RTSP client:

```
rtsp://127.0.0.1:8554/cam0
rtsp://127.0.0.1:8554/cam1
rtsp://127.0.0.1:8554/cam2
```

> **Note**: Replace `127.0.0.1` with your server's IP address if accessing remotely.

### 4. Stop Streams

When done, stop all streams:

```bash
./stop_rtsp_streams.sh
```

## File Reference

### `video_paths.txt`

List of video file paths to stream, one per line. Supports comments (lines starting with `#`):

```txt
# My video collection
./videos/car.mp4
./videos/pedestrian.mp4
./videos/faceid7.mp4
```

**Supported formats**: `.mp4`, `.mkv`, `.mov`, `.avi`, `.ts`

### `start_rtsp_streams.sh`

Main script to start RTSP streaming. Automatically handles:
- Video preprocessing (H.264 encoding with optimal settings)
- Container orchestration
- Stream publishing

**Usage**:
```bash
# Use video_paths.txt (default)
./start_rtsp_streams.sh

# Or specify videos directly
./start_rtsp_streams.sh ./videos/video1.mp4 ./videos/video2.mp4

# With custom FPS and resolution
./start_rtsp_streams.sh --fps 30 --resolution 1280x720
```

**Default settings**:
- FPS: `25`
- Resolution: `1920x1080`

### `stop_rtsp_streams.sh`

Stops all running RTSP streams and containers.

**Usage**:
```bash
./stop_rtsp_streams.sh
```

## How It Works

1. **Preprocessing**: Videos are transcoded to H.264 baseline profile with dense keyframes for seamless looping
2. **Streaming**: Each video is published to a unique RTSP path (`cam0`, `cam1`, `cam2`, etc.)
3. **Looping**: When a video ends, FFmpeg automatically restarts it

## Troubleshooting

| Issue | Solution |
|-------|----------|
| **Script permission denied** | Run `chmod +x start_rtsp_streams.sh stop_rtsp_streams.sh` |
| **Video file not found** | Verify paths in `video_paths.txt` are correct and relative to project root |
| **Cannot connect to stream** | Check containers are running: `docker compose ps` |
| **Stream is choppy** | Ensure videos are properly encoded. The script handles preprocessing automatically |
| **Port already in use** | Stop existing containers: `./stop_rtsp_streams.sh` |

## Architecture

- **MediaMTX**: RTSP server handling client connections
- **FFmpeg**: Video preprocessing and stream publishing
- **Docker Compose**: Container orchestration

## License

This project is provided as-is. Use at your own discretion.

## Author

**locviettri@gmail.com**

---

**Easy RTSP Server** - Made with ❤️ for easy RTSP streaming
