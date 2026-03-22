from __future__ import annotations

import argparse
import csv
import os
import sys
import time
from datetime import datetime
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
YOLO_CONFIG_DIR = PROJECT_ROOT / ".ultralytics"
os.environ.setdefault("YOLO_CONFIG_DIR", str(YOLO_CONFIG_DIR))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Track objects in a video with YOLO11m and save an annotated video plus CSV logs."
    )
    parser.add_argument(
        "--source",
        required=True,
        help="Input video path or webcam index such as 0.",
    )
    parser.add_argument(
        "--model",
        default="yolo11m.pt",
        help="YOLO11 weight name or local .pt path.",
    )
    parser.add_argument(
        "--tracker",
        default="bytetrack.yaml",
        help="Ultralytics tracker config. Example: bytetrack.yaml or botsort.yaml.",
    )
    parser.add_argument(
        "--output-dir",
        default="runs/yolo11_tracking",
        help="Directory where output videos and CSV files are saved.",
    )
    parser.add_argument(
        "--conf",
        type=float,
        default=0.35,
        help="Confidence threshold.",
    )
    parser.add_argument(
        "--iou",
        type=float,
        default=0.5,
        help="IoU threshold used during tracking.",
    )
    parser.add_argument(
        "--imgsz",
        type=int,
        default=960,
        help="Inference image size.",
    )
    parser.add_argument(
        "--classes",
        default="",
        help="Optional comma-separated class IDs to keep. Example: 0,32 for person and sports ball.",
    )
    parser.add_argument(
        "--device",
        default="",
        help="Optional device override. Example: cpu, 0, 0,1.",
    )
    parser.add_argument(
        "--line-width",
        type=int,
        default=2,
        help="Bounding box line width in the output video.",
    )
    parser.add_argument(
        "--fps",
        type=float,
        default=0.0,
        help="Fallback FPS when the source metadata is missing.",
    )
    parser.add_argument(
        "--show",
        action="store_true",
        help="Show a preview window while tracking.",
    )
    return parser.parse_args()


def parse_class_ids(raw_value: str) -> list[int] | None:
    if not raw_value.strip():
        return None

    class_ids = []
    for token in raw_value.split(","):
        token = token.strip()
        if not token:
            continue
        class_ids.append(int(token))
    return class_ids or None


def resolve_source(source: str) -> str | int:
    if Path(source).exists():
        return source
    if source.isdigit():
        return int(source)
    return source


def make_run_dir(output_dir: str, source: str) -> Path:
    source_name = Path(source).stem if Path(source).suffix else str(source).replace(":", "_")
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = Path(output_dir) / f"{source_name}_{timestamp}"
    run_dir.mkdir(parents=True, exist_ok=True)
    return run_dir


def open_writer(run_dir: Path, fps: float, width: int, height: int):
    primary_path = run_dir / "tracked.mp4"
    writer = cv2.VideoWriter(
        str(primary_path),
        cv2.VideoWriter_fourcc(*"mp4v"),
        fps,
        (width, height),
    )
    if writer.isOpened():
        return writer, primary_path

    fallback_path = run_dir / "tracked.avi"
    writer = cv2.VideoWriter(
        str(fallback_path),
        cv2.VideoWriter_fourcc(*"XVID"),
        fps,
        (width, height),
    )
    if writer.isOpened():
        return writer, fallback_path

    raise RuntimeError("Could not open a video writer for the output file.")


def put_status_text(frame, frame_index: int, fps_value: float) -> None:
    text = f"frame={frame_index}  fps={fps_value:.1f}"
    cv2.putText(
        frame,
        text,
        (20, 40),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.9,
        (0, 255, 0),
        2,
        cv2.LINE_AA,
    )


def track_rows(result, frame_index: int) -> list[list[object]]:
    boxes = result.boxes
    if boxes is None or len(boxes) == 0:
        return []

    xyxy = boxes.xyxy.cpu().tolist()
    confs = boxes.conf.cpu().tolist() if boxes.conf is not None else [0.0] * len(xyxy)
    class_ids = boxes.cls.int().cpu().tolist() if boxes.cls is not None else [-1] * len(xyxy)
    track_ids = boxes.id.int().cpu().tolist() if boxes.id is not None else [-1] * len(xyxy)

    rows: list[list[object]] = []
    for index, (x1, y1, x2, y2) in enumerate(xyxy):
        class_id = class_ids[index]
        track_id = track_ids[index]
        confidence = confs[index]
        label = result.names.get(class_id, str(class_id))
        center_x = (x1 + x2) / 2.0
        center_y = (y1 + y2) / 2.0
        rows.append(
            [
                frame_index,
                track_id,
                class_id,
                label,
                round(confidence, 5),
                round(x1, 2),
                round(y1, 2),
                round(x2, 2),
                round(y2, 2),
                round(center_x, 2),
                round(center_y, 2),
            ]
        )
    return rows


def run_tracking(args: argparse.Namespace) -> int:
    source = resolve_source(args.source)
    class_ids = parse_class_ids(args.classes)
    run_dir = make_run_dir(args.output_dir, str(args.source))
    csv_path = run_dir / "tracks.csv"

    try:
        model = YOLO(args.model)
    except Exception as exc:
        print(f"Failed to load model '{args.model}': {exc}", file=sys.stderr)
        print(
            "If the weights are not already on disk, place yolo11m.pt locally or allow Ultralytics to download it.",
            file=sys.stderr,
        )
        return 1

    capture = cv2.VideoCapture(source)
    if not capture.isOpened():
        print(f"Could not open source: {args.source}", file=sys.stderr)
        return 1

    ok, frame = capture.read()
    if not ok:
        capture.release()
        print(f"Could not read the first frame from: {args.source}", file=sys.stderr)
        return 1

    input_fps = capture.get(cv2.CAP_PROP_FPS)
    fps = input_fps if input_fps and input_fps > 1e-3 else args.fps
    if fps <= 0:
        fps = 30.0

    height, width = frame.shape[:2]
    writer, video_path = open_writer(run_dir, fps, width, height)

    inference_kwargs = {
        "persist": True,
        "tracker": args.tracker,
        "conf": args.conf,
        "iou": args.iou,
        "imgsz": args.imgsz,
        "verbose": False,
    }
    if class_ids is not None:
        inference_kwargs["classes"] = class_ids
    if args.device:
        inference_kwargs["device"] = args.device

    total_frames = 0
    start_time = time.perf_counter()

    with csv_path.open("w", newline="", encoding="utf-8") as csv_file:
        csv_writer = csv.writer(csv_file)
        csv_writer.writerow(
            [
                "frame",
                "track_id",
                "class_id",
                "label",
                "confidence",
                "x1",
                "y1",
                "x2",
                "y2",
                "center_x",
                "center_y",
            ]
        )

        while ok:
            total_frames += 1
            result = model.track(frame, **inference_kwargs)[0]
            annotated = result.plot(conf=True, labels=True, line_width=args.line_width)

            elapsed = max(time.perf_counter() - start_time, 1e-6)
            avg_fps = total_frames / elapsed
            put_status_text(annotated, total_frames, avg_fps)

            writer.write(annotated)

            for row in track_rows(result, total_frames):
                csv_writer.writerow(row)

            if args.show:
                cv2.imshow("YOLO11 Tracking", annotated)
                if cv2.waitKey(1) & 0xFF == ord("q"):
                    break

            if total_frames % 30 == 0:
                print(f"Processed {total_frames} frames | avg_fps={avg_fps:.2f}")

            ok, frame = capture.read()

    capture.release()
    writer.release()
    if args.show:
        cv2.destroyAllWindows()

    elapsed = max(time.perf_counter() - start_time, 1e-6)
    print(f"Finished tracking {total_frames} frames in {elapsed:.2f} seconds.")
    print(f"Annotated video: {video_path}")
    print(f"CSV log:        {csv_path}")
    print(f"Run directory:  {run_dir}")
    return 0


def main() -> int:
    try:
        args = parse_args()
    except KeyboardInterrupt:
        print("Tracking interrupted by user.", file=sys.stderr)
        return 130

    try:
        global cv2, YOLO
        import cv2
        from ultralytics import YOLO
    except ImportError as exc:
        print(f"Missing dependency: {exc}", file=sys.stderr)
        print(
            "Install dependencies with: pip install -r yolo11_video_tracking/requirements.txt",
            file=sys.stderr,
        )
        return 1

    try:
        return run_tracking(args)
    except ValueError as exc:
        print(f"Invalid argument: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Tracking interrupted by user.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
