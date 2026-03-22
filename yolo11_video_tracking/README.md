# YOLO11 Video Tracking

This folder contains a standalone video tracking script built with `YOLO11m` and Ultralytics tracking.

## What it does

- Reads an input video file or webcam stream
- Runs object detection with `yolo11m.pt`
- Keeps object IDs across frames with `ByteTrack`
- Saves:
  - an annotated output video
  - a `tracks.csv` file with frame-by-frame tracking data

## Install

```bash
pip install -r yolo11_video_tracking/requirements.txt
```

If `yolo11m.pt` is not already on disk, Ultralytics may download it automatically on first run.

## Run

Track all detected classes:

```bash
python yolo11_video_tracking/track_video.py --source path/to/input.mp4
```

Track only `person` and `sports ball` from the COCO class set:

```bash
python yolo11_video_tracking/track_video.py --source path/to/input.mp4 --classes 0,32
```

Show a live preview while saving the result:

```bash
python yolo11_video_tracking/track_video.py --source path/to/input.mp4 --show
```

Use a local weight file instead of the default model name:

```bash
python yolo11_video_tracking/track_video.py --source path/to/input.mp4 --model weights/yolo11m.pt
```

## Output

Outputs are saved under:

```text
runs/yolo11_tracking/
```

Each run creates a timestamped subfolder with:

- `tracked.mp4` or `tracked.avi`
- `tracks.csv`

## Notes

- Default tracker: `bytetrack.yaml`
- Press `q` to stop when `--show` is enabled
- Add `--device cpu` if you want to force CPU inference
