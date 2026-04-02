# Offline Video Tracking Prototype

This folder contains the offline first-stage human and ball tracking prototype for prerecorded sports video.

## Pipeline Summary

The pipeline runs frame by frame:

1. `main.py` opens a local video file such as `input.mp4`.
2. `detector.py` runs a YOLO-based detector and keeps the configured COCO classes. The default is `0,32` for `person` and `sports ball`.
3. `tracker.py` keeps stable IDs across frames with a lightweight Kalman + Hungarian tracker and only matches objects within the same class.
4. `utils.py` draws bounding boxes, class labels, track IDs, center points, and short trajectory trails.
5. The pipeline saves:
   - `output_tracked.mp4`
   - `tracking_results.csv`

This baseline supports both players and the ball in the same pipeline, but ball quality still depends heavily on the model.

## Files

- `main.py`
- `detector.py`
- `tracker.py`
- `utils.py`
- `requirements.txt`
- `run_soccer_data_1.sh`

## Install

If you use the existing `study` conda environment, the required packages are already present.

If you want to install separately:

```bash
pip install -r offline_video_tracking/requirements.txt
```

The default model lookup prefers `yolo26n.pt` from the current working directory or the repository root.

## Run

General run command from the repository root:

```bash
python offline_video_tracking/main.py \
  --input-video input.mp4 \
  --output-video offline_video_tracking/output_tracked.mp4 \
  --output-csv offline_video_tracking/tracking_results.csv \
  --model-path yolo26n.pt \
  --conf-threshold 0.25 \
  --detector-iou-threshold 0.45 \
  --match-iou-threshold 0.25 \
  --trail-length 20 \
  --class-ids 0,32
```

Sample run for the local soccer video:

```bash
bash offline_video_tracking/run_soccer_data_1.sh
```

Preview while saving:

```bash
bash offline_video_tracking/run_soccer_data_1.sh --show
```

## CSV Format

`tracking_results.csv` contains:

- `frame_idx`
- `track_id`
- `class_id`
- `label`
- `x1`
- `y1`
- `x2`
- `y2`
- `cx`
- `cy`
- `conf`

## Common Failure Cases

- Occlusion: one player blocks another and IDs can still switch after long overlap.
- Motion blur: fast movement lowers detector confidence, especially for the ball.
- Missed detections: the soccer ball is very small, so generic COCO models often miss it entirely.
- Camera shake: boxes can jump, making ball tracks especially unstable.

## Why This Baseline

This prototype uses a practical class-aware tracker so people and ball detections do not get matched to each other. It is still lightweight enough to debug and extend, but honest limitation: if the detector does not see the ball, the tracker cannot recover it.

## Later Extension Path

To extend this to real-time camera tracking later:

- replace file input with a live camera source
- keep the same detector and tracker interfaces
- add threaded capture or buffering if needed
- add target-selection logic if only one player should drive control
- add a separate motor-control module that maps tracked center positions to pan and tilt commands
- apply smoothing, deadband, and rate limits before sending commands to motors
