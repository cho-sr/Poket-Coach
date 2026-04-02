from __future__ import annotations

import argparse
import csv
from pathlib import Path

import cv2

from detector import YOLOSportsDetector
from tracker import MultiObjectTracker
from utils import TRACKING_CSV_HEADER, draw_track_visuals, make_video_writer, track_result_to_csv_row


def default_model_path() -> str:
    """Prefer local YOLO weights from the working directory or repository root."""
    script_dir = Path(__file__).resolve().parent
    search_roots = [Path.cwd(), script_dir, script_dir.parent]
    candidate_names = ("yolo26n.pt", "yolo11s.pt", "yolo11n.pt")

    for root in search_roots:
        for candidate_name in candidate_names:
            candidate_path = root / candidate_name
            if candidate_path.exists():
                return str(candidate_path)
    return "yolo26n.pt"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Offline person and ball detection plus tracking for prerecorded sports video."
    )
    parser.add_argument(
        "--input-video",
        default="input.mp4",
        help="Path to the prerecorded input video.",
    )
    parser.add_argument(
        "--output-video",
        default="output_tracked.mp4",
        help="Path to the annotated output video.",
    )
    parser.add_argument(
        "--output-csv",
        default="tracking_results.csv",
        help="Path to the CSV file that stores frame-by-frame tracking results.",
    )
    parser.add_argument(
        "--model-path",
        default=default_model_path(),
        help="Path to a YOLO model weight file. Example: yolo26n.pt",
    )
    parser.add_argument(
        "--device",
        default="",
        help="Torch device override such as cpu, 0, or 0,1.",
    )
    parser.add_argument(
        "--imgsz",
        type=int,
        default=960,
        help="Inference image size passed to YOLO.",
    )
    parser.add_argument(
        "--conf-threshold",
        type=float,
        default=0.25,
        help="Minimum confidence score for detections. Lower values may help the ball class.",
    )
    parser.add_argument(
        "--detector-iou-threshold",
        type=float,
        default=0.45,
        help="IoU threshold used by YOLO's non-maximum suppression.",
    )
    parser.add_argument(
        "--match-iou-threshold",
        type=float,
        default=0.25,
        help="Minimum IoU required to match a detection to an existing track.",
    )
    parser.add_argument(
        "--max-missed",
        type=int,
        default=20,
        help="How many consecutive missed frames a track can survive internally.",
    )
    parser.add_argument(
        "--min-hits",
        type=int,
        default=1,
        help="How many matched detections are required before a track is exported.",
    )
    parser.add_argument(
        "--trail-length",
        type=int,
        default=20,
        help="How many recent center points to keep for each trajectory trail.",
    )
    parser.add_argument(
        "--class-ids",
        default="0,32",
        help="Comma-separated COCO class IDs to detect and track. Default: 0,32 for person and sports ball.",
    )
    parser.add_argument(
        "--fallback-fps",
        type=float,
        default=30.0,
        help="FPS used when the input file does not expose valid video metadata.",
    )
    parser.add_argument(
        "--show",
        action="store_true",
        help="Show a preview window while the offline video is being processed.",
    )
    return parser.parse_args()


def parse_class_ids(raw_value: str) -> list[int]:
    class_ids: list[int] = []
    for token in raw_value.split(","):
        token = token.strip()
        if token:
            class_ids.append(int(token))
    return class_ids or [0, 32]


def run_pipeline(args: argparse.Namespace) -> None:
    input_video = args.input_video
    output_video = args.output_video
    output_csv = args.output_csv

    class_ids = parse_class_ids(args.class_ids)

    detector = YOLOSportsDetector(
        model_path=args.model_path,
        conf_threshold=args.conf_threshold,
        iou_threshold=args.detector_iou_threshold,
        imgsz=args.imgsz,
        device=args.device,
        class_ids=class_ids,
    )
    tracker = MultiObjectTracker(
        match_iou_threshold=args.match_iou_threshold,
        max_missed=args.max_missed,
        min_hits=args.min_hits,
        max_trail_length=args.trail_length,
    )

    capture = cv2.VideoCapture(input_video)
    if not capture.isOpened():
        raise FileNotFoundError(f"Could not open input video: {input_video}")

    ok, first_frame = capture.read()
    if not ok:
        capture.release()
        raise RuntimeError(f"Could not read the first frame from: {input_video}")

    height, width = first_frame.shape[:2]
    input_fps = capture.get(cv2.CAP_PROP_FPS)
    fps = input_fps if input_fps and input_fps > 1e-3 else args.fallback_fps

    video_writer = make_video_writer(output_video, fps, (width, height))
    Path(output_csv).parent.mkdir(parents=True, exist_ok=True)

    frame_idx = 0
    frame = first_frame
    label_counts: dict[str, int] = {}

    try:
        with Path(output_csv).open("w", newline="", encoding="utf-8") as csv_file:
            csv_writer = csv.writer(csv_file)
            csv_writer.writerow(TRACKING_CSV_HEADER)

            while True:
                # Detect the configured classes on the current frame.
                detections = detector.detect(frame)
                tracks = tracker.update(detections)

                annotated_frame = frame.copy()
                draw_track_visuals(
                    annotated_frame,
                    tracks,
                    frame_idx=frame_idx,
                    trail_length=args.trail_length,
                )
                video_writer.write(annotated_frame)

                for track in tracks:
                    csv_writer.writerow(track_result_to_csv_row(frame_idx, track))
                    label_counts[track.label] = label_counts.get(track.label, 0) + 1

                if args.show:
                    cv2.imshow("Offline Sports Tracking", annotated_frame)
                    if cv2.waitKey(1) & 0xFF == ord("q"):
                        break

                frame_idx += 1
                ok, frame = capture.read()
                if not ok:
                    break
    finally:
        capture.release()
        video_writer.release()
        if args.show:
            cv2.destroyAllWindows()

    print(f"Processed {frame_idx} frames from {input_video}")
    print(f"Saved annotated video to {output_video}")
    print(f"Saved tracking CSV to {output_csv}")
    if label_counts:
        print(f"Tracked counts by label: {label_counts}")
    if 32 in class_ids and label_counts.get('ball', 0) == 0:
        print(
            "Warning: no ball tracks were produced. "
            "The current generic COCO weights may not detect the soccer ball reliably in this video."
        )


def main() -> None:
    args = parse_args()
    run_pipeline(args)


if __name__ == "__main__":
    main()
