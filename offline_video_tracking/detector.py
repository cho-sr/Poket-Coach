from __future__ import annotations

import os
from pathlib import Path

import numpy as np

from utils import Detection, clip_box


PROJECT_ROOT = Path(__file__).resolve().parent
YOLO_CONFIG_DIR = PROJECT_ROOT / ".ultralytics"
os.environ.setdefault("YOLO_CONFIG_DIR", str(YOLO_CONFIG_DIR))


class YOLOSportsDetector:
    """Thin YOLO wrapper that returns person and sports-ball detections for one frame."""

    def __init__(
        self,
        model_path: str,
        conf_threshold: float = 0.35,
        iou_threshold: float = 0.45,
        imgsz: int = 960,
        device: str = "",
        class_ids: list[int] | None = None,
    ) -> None:
        try:
            from ultralytics import YOLO
        except ImportError as exc:
            raise ImportError(
                "Ultralytics is not installed. Run `pip install -r requirements.txt` first."
            ) from exc

        self.model = YOLO(model_path)
        self.conf_threshold = conf_threshold
        self.iou_threshold = iou_threshold
        self.imgsz = imgsz
        self.device = device.strip()
        self.class_ids = class_ids if class_ids is not None else [0, 32]
        self.class_names = self.model.names

    def detect(self, frame: np.ndarray) -> list[Detection]:
        """Run YOLO on one frame and keep the selected COCO classes."""
        predict_kwargs = {
            "source": frame,
            "classes": self.class_ids,
            "conf": self.conf_threshold,
            "iou": self.iou_threshold,
            "imgsz": self.imgsz,
            "verbose": False,
        }
        if self.device:
            predict_kwargs["device"] = self.device

        results = self.model.predict(**predict_kwargs)
        if not results:
            return []

        boxes = results[0].boxes
        if boxes is None or len(boxes) == 0:
            return []

        xyxy = boxes.xyxy.cpu().numpy()
        confs = boxes.conf.cpu().numpy() if boxes.conf is not None else np.ones(len(xyxy))
        class_ids = boxes.cls.int().cpu().tolist() if boxes.cls is not None else [-1] * len(xyxy)

        frame_height, frame_width = frame.shape[:2]
        detections: list[Detection] = []
        for box, conf, class_id in zip(xyxy, confs, class_ids):
            clipped_box = clip_box(
                tuple(float(value) for value in box.tolist()),
                frame_width,
                frame_height,
            )
            label = str(self.class_names.get(class_id, class_id))
            if class_id == 32:
                label = "ball"
            detections.append(
                Detection(
                    bbox=clipped_box,
                    conf=float(conf),
                    class_id=int(class_id),
                    label=label,
                )
            )

        return detections
