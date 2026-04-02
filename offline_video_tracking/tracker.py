from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from typing import Sequence

import numpy as np

from utils import Detection, TrackResult, bbox_center, box_iou, cxcywh_to_xyxy, xyxy_to_cxcywh

try:
    from scipy.optimize import linear_sum_assignment
except ImportError:
    linear_sum_assignment = None


def solve_assignment(cost_matrix: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Use Hungarian matching when available and fall back to a greedy matcher otherwise."""
    if cost_matrix.size == 0:
        return np.array([], dtype=int), np.array([], dtype=int)

    if linear_sum_assignment is not None:
        row_indices, col_indices = linear_sum_assignment(cost_matrix)
        return np.asarray(row_indices, dtype=int), np.asarray(col_indices, dtype=int)

    flat_indices = np.argsort(cost_matrix, axis=None)
    used_rows: set[int] = set()
    used_cols: set[int] = set()
    row_matches: list[int] = []
    col_matches: list[int] = []

    for flat_index in flat_indices:
        row_idx, col_idx = np.unravel_index(flat_index, cost_matrix.shape)
        if row_idx in used_rows or col_idx in used_cols:
            continue
        used_rows.add(row_idx)
        used_cols.add(col_idx)
        row_matches.append(int(row_idx))
        col_matches.append(int(col_idx))

    return np.asarray(row_matches, dtype=int), np.asarray(col_matches, dtype=int)


class KalmanBoxFilter:
    """Constant-velocity Kalman filter for a bounding box in cx, cy, w, h form."""

    def __init__(
        self,
        initial_box: tuple[float, float, float, float],
        process_noise: float = 1.0,
        measurement_noise: float = 10.0,
    ) -> None:
        self.state = np.zeros((8, 1), dtype=np.float32)
        self.state[:4, 0] = np.asarray(xyxy_to_cxcywh(initial_box), dtype=np.float32)

        self.transition = np.eye(8, dtype=np.float32)
        for index in range(4):
            self.transition[index, index + 4] = 1.0

        self.measurement = np.zeros((4, 8), dtype=np.float32)
        self.measurement[0, 0] = 1.0
        self.measurement[1, 1] = 1.0
        self.measurement[2, 2] = 1.0
        self.measurement[3, 3] = 1.0

        self.covariance = np.eye(8, dtype=np.float32) * 10.0
        self.covariance[4:, 4:] *= 10.0

        self.process_noise = np.eye(8, dtype=np.float32)
        self.process_noise[:4, :4] *= process_noise
        self.process_noise[4:, 4:] *= process_noise * 10.0

        self.measurement_noise = np.eye(4, dtype=np.float32) * measurement_noise

    def predict(self) -> tuple[float, float, float, float]:
        self.state = self.transition @ self.state
        self.covariance = (
            self.transition @ self.covariance @ self.transition.T + self.process_noise
        )
        return self.current_box()

    def update(
        self,
        measured_box: tuple[float, float, float, float],
    ) -> tuple[float, float, float, float]:
        measurement = np.asarray(xyxy_to_cxcywh(measured_box), dtype=np.float32).reshape(4, 1)
        innovation = measurement - self.measurement @ self.state
        innovation_covariance = (
            self.measurement @ self.covariance @ self.measurement.T + self.measurement_noise
        )
        kalman_gain = self.covariance @ self.measurement.T @ np.linalg.inv(innovation_covariance)
        self.state = self.state + kalman_gain @ innovation
        identity = np.eye(8, dtype=np.float32)
        self.covariance = (identity - kalman_gain @ self.measurement) @ self.covariance
        return self.current_box()

    def current_box(self) -> tuple[float, float, float, float]:
        cx, cy, width, height = self.state[:4, 0]
        width = max(2.0, float(width))
        height = max(2.0, float(height))
        return cxcywh_to_xyxy((float(cx), float(cy), width, height))


@dataclass
class TrackState:
    track_id: int
    class_id: int
    label: str
    kalman: KalmanBoxFilter
    bbox: tuple[float, float, float, float]
    confidence: float
    hits: int
    age: int
    missed: int
    trail: deque[tuple[int, int]]

    def predict(self) -> tuple[float, float, float, float]:
        self.age += 1
        self.missed += 1
        self.bbox = self.kalman.predict()
        return self.bbox

    def update(self, detection: Detection) -> None:
        self.bbox = self.kalman.update(detection.bbox)
        self.confidence = detection.conf
        self.hits += 1
        self.missed = 0
        center_x, center_y = bbox_center(self.bbox)
        self.trail.append((int(round(center_x)), int(round(center_y))))

    def to_result(self) -> TrackResult:
        center_x, center_y = bbox_center(self.bbox)
        return TrackResult(
            track_id=self.track_id,
            class_id=self.class_id,
            label=self.label,
            bbox=self.bbox,
            center=(center_x, center_y),
            conf=self.confidence,
            trail=list(self.trail),
        )


class MultiObjectTracker:
    """Simple class-aware multi-object tracker using Kalman prediction and IoU assignment."""

    def __init__(
        self,
        match_iou_threshold: float = 0.25,
        max_missed: int = 20,
        min_hits: int = 1,
        max_trail_length: int = 20,
    ) -> None:
        self.match_iou_threshold = match_iou_threshold
        self.max_missed = max_missed
        self.min_hits = min_hits
        self.max_trail_length = max_trail_length
        self.tracks: list[TrackState] = []
        self.next_track_id = 1

    def update(self, detections: Sequence[Detection]) -> list[TrackResult]:
        if not self.tracks:
            for detection in detections:
                self._start_track(detection)
            return self._collect_results()

        for track in self.tracks:
            track.predict()

        matches: list[tuple[int, int]] = []
        unmatched_track_indices = set(range(len(self.tracks)))
        unmatched_detection_indices = set(range(len(detections)))

        class_ids = sorted({track.class_id for track in self.tracks} | {det.class_id for det in detections})
        for class_id in class_ids:
            track_indices = [index for index, track in enumerate(self.tracks) if track.class_id == class_id]
            detection_indices = [
                index for index, detection in enumerate(detections) if detection.class_id == class_id
            ]
            class_matches, class_unmatched_tracks, class_unmatched_detections = self._associate_class(
                track_indices,
                detection_indices,
                detections,
            )
            matches.extend(class_matches)
            unmatched_track_indices.update(class_unmatched_tracks)
            unmatched_detection_indices.update(class_unmatched_detections)
            for track_index, detection_index in class_matches:
                unmatched_track_indices.discard(track_index)
                unmatched_detection_indices.discard(detection_index)

        for track_index, detection_index in matches:
            self.tracks[track_index].update(detections[detection_index])

        for detection_index in sorted(unmatched_detection_indices):
            self._start_track(detections[detection_index])

        self.tracks = [track for track in self.tracks if track.missed <= self.max_missed]
        return self._collect_results()

    def _associate_class(
        self,
        track_indices: Sequence[int],
        detection_indices: Sequence[int],
        detections: Sequence[Detection],
    ) -> tuple[list[tuple[int, int]], list[int], list[int]]:
        if not track_indices:
            return [], [], list(detection_indices)

        if not detection_indices:
            return [], list(track_indices), []

        iou_matrix = np.zeros((len(track_indices), len(detection_indices)), dtype=np.float32)
        for local_track_index, track_index in enumerate(track_indices):
            for local_detection_index, detection_index in enumerate(detection_indices):
                iou_matrix[local_track_index, local_detection_index] = box_iou(
                    self.tracks[track_index].bbox,
                    detections[detection_index].bbox,
                )

        cost_matrix = 1.0 - iou_matrix
        matched_tracks, matched_detections = solve_assignment(cost_matrix)

        matches: list[tuple[int, int]] = []
        unmatched_tracks = set(track_indices)
        unmatched_detections = set(detection_indices)

        for local_track_index, local_detection_index in zip(
            matched_tracks.tolist(),
            matched_detections.tolist(),
        ):
            if iou_matrix[local_track_index, local_detection_index] < self.match_iou_threshold:
                continue
            track_index = track_indices[local_track_index]
            detection_index = detection_indices[local_detection_index]
            matches.append((track_index, detection_index))
            unmatched_tracks.discard(track_index)
            unmatched_detections.discard(detection_index)

        return matches, sorted(unmatched_tracks), sorted(unmatched_detections)

    def _start_track(self, detection: Detection) -> None:
        kalman = KalmanBoxFilter(detection.bbox)
        center_x, center_y = bbox_center(detection.bbox)
        new_track = TrackState(
            track_id=self.next_track_id,
            class_id=detection.class_id,
            label=detection.label,
            kalman=kalman,
            bbox=detection.bbox,
            confidence=detection.conf,
            hits=1,
            age=1,
            missed=0,
            trail=deque(
                [(int(round(center_x)), int(round(center_y)))],
                maxlen=self.max_trail_length,
            ),
        )
        self.tracks.append(new_track)
        self.next_track_id += 1

    def _collect_results(self) -> list[TrackResult]:
        results: list[TrackResult] = []
        for track in self.tracks:
            if track.hits >= self.min_hits and track.missed == 0:
                results.append(track.to_result())
        return results
