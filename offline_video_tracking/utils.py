from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np


TRACKING_CSV_HEADER = [
    "frame_idx",
    "track_id",
    "class_id",
    "label",
    "x1",
    "y1",
    "x2",
    "y2",
    "cx",
    "cy",
    "conf",
]


@dataclass(frozen=True)
class Detection:
    bbox: tuple[float, float, float, float]
    conf: float
    class_id: int
    label: str


@dataclass(frozen=True)
class TrackResult:
    track_id: int
    class_id: int
    label: str
    bbox: tuple[float, float, float, float]
    center: tuple[float, float]
    conf: float
    trail: list[tuple[int, int]]


def clip_box(
    box: tuple[float, float, float, float],
    frame_width: int,
    frame_height: int,
) -> tuple[float, float, float, float]:
    x1, y1, x2, y2 = box
    x1 = max(0.0, min(x1, frame_width - 1.0))
    y1 = max(0.0, min(y1, frame_height - 1.0))
    x2 = max(0.0, min(x2, frame_width - 1.0))
    y2 = max(0.0, min(y2, frame_height - 1.0))
    if x2 < x1:
        x1, x2 = x2, x1
    if y2 < y1:
        y1, y2 = y2, y1
    return x1, y1, x2, y2


def bbox_center(box: tuple[float, float, float, float]) -> tuple[float, float]:
    x1, y1, x2, y2 = box
    return (x1 + x2) / 2.0, (y1 + y2) / 2.0


def xyxy_to_cxcywh(box: tuple[float, float, float, float]) -> tuple[float, float, float, float]:
    x1, y1, x2, y2 = box
    width = max(2.0, x2 - x1)
    height = max(2.0, y2 - y1)
    center_x = x1 + width / 2.0
    center_y = y1 + height / 2.0
    return center_x, center_y, width, height


def cxcywh_to_xyxy(box: tuple[float, float, float, float]) -> tuple[float, float, float, float]:
    center_x, center_y, width, height = box
    half_width = width / 2.0
    half_height = height / 2.0
    return (
        center_x - half_width,
        center_y - half_height,
        center_x + half_width,
        center_y + half_height,
    )


def box_iou(
    box_a: tuple[float, float, float, float],
    box_b: tuple[float, float, float, float],
) -> float:
    ax1, ay1, ax2, ay2 = box_a
    bx1, by1, bx2, by2 = box_b

    inter_x1 = max(ax1, bx1)
    inter_y1 = max(ay1, by1)
    inter_x2 = min(ax2, bx2)
    inter_y2 = min(ay2, by2)

    inter_width = max(0.0, inter_x2 - inter_x1)
    inter_height = max(0.0, inter_y2 - inter_y1)
    intersection = inter_width * inter_height

    area_a = max(0.0, ax2 - ax1) * max(0.0, ay2 - ay1)
    area_b = max(0.0, bx2 - bx1) * max(0.0, by2 - by1)
    union = area_a + area_b - intersection

    if union <= 0.0:
        return 0.0
    return float(intersection / union)


def make_video_writer(
    output_path: str | Path,
    fps: float,
    frame_size: tuple[int, int],
) -> cv2.VideoWriter:
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    writer = cv2.VideoWriter(
        str(output_path),
        cv2.VideoWriter_fourcc(*"mp4v"),
        fps,
        frame_size,
    )
    if writer.isOpened():
        return writer

    raise RuntimeError(
        f"Could not open a video writer for {output_path}. "
        "Try a different output path or codec support in OpenCV."
    )


def class_color(class_id: int) -> tuple[int, int, int]:
    if class_id == 0:
        return 0, 220, 80
    if class_id == 32:
        return 0, 140, 255
    return 255, 200, 0


def draw_track_visuals(
    frame: np.ndarray,
    tracks: list[TrackResult],
    frame_idx: int,
    trail_length: int = 20,
) -> None:
    counts_by_label: dict[str, int] = {}
    for track in tracks:
        x1, y1, x2, y2 = track.bbox
        center_x, center_y = track.center
        color = class_color(track.class_id)
        counts_by_label[track.label] = counts_by_label.get(track.label, 0) + 1

        x1_i, y1_i, x2_i, y2_i = map(lambda value: int(round(value)), (x1, y1, x2, y2))
        center_point = (int(round(center_x)), int(round(center_y)))

        cv2.rectangle(frame, (x1_i, y1_i), (x2_i, y2_i), color, 2)
        cv2.circle(frame, center_point, 4, color, -1)

        label = f"{track.label} #{track.track_id} | {track.conf:.2f}"
        label_origin_y = max(20, y1_i - 10)
        cv2.putText(
            frame,
            label,
            (x1_i, label_origin_y),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.6,
            color,
            2,
            cv2.LINE_AA,
        )

        if trail_length > 1 and len(track.trail) > 1:
            trail = track.trail[-trail_length:]
            for point_a, point_b in zip(trail[:-1], trail[1:]):
                cv2.line(frame, point_a, point_b, color, 2)

    header_parts = [f"frame={frame_idx}", f"tracks={len(tracks)}"]
    for label, count in sorted(counts_by_label.items()):
        header_parts.append(f"{label}={count}")
    header = "  ".join(header_parts)
    cv2.putText(
        frame,
        header,
        (20, 30),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.8,
        (255, 255, 255),
        2,
        cv2.LINE_AA,
    )


def track_result_to_csv_row(frame_idx: int, track: TrackResult) -> list[float | int | str]:
    x1, y1, x2, y2 = track.bbox
    center_x, center_y = track.center
    return [
        frame_idx,
        track.track_id,
        track.class_id,
        track.label,
        round(x1, 2),
        round(y1, 2),
        round(x2, 2),
        round(y2, 2),
        round(center_x, 2),
        round(center_y, 2),
        round(track.conf, 5),
    ]
