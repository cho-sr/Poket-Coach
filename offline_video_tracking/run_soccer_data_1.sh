#!/usr/bin/env bash
set -euo pipefail

# Run the offline player + ball tracking pipeline on the local soccer sample video.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON_BIN="/Users/joseoglae/miniforge3/envs/study/bin/python"

cd "$REPO_ROOT"

"$PYTHON_BIN" "$SCRIPT_DIR/main.py" \
  --input-video "$REPO_ROOT/soccer_data_1.mp4" \
  --output-video "$SCRIPT_DIR/soccer_data_1_tracked.mp4" \
  --output-csv "$SCRIPT_DIR/soccer_data_1_tracking_results.csv" \
  --model-path "$REPO_ROOT/yolo26n.pt" \
  --conf-threshold 0.25 \
  --detector-iou-threshold 0.45 \
  --match-iou-threshold 0.25 \
  --trail-length 20 \
  "$@"
