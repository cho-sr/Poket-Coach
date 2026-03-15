import argparse

import coremltools as ct
import torch
from torch.export import export

from executorch.backends.apple.coreml.compiler import CoreMLBackend
from executorch.backends.apple.coreml.partition.coreml_partitioner import (
    CoreMLPartitioner,
)
from executorch.exir import to_edge_transform_and_lower


def parse_class_ids(raw: str | None) -> list[int] | None:
    if raw is None:
        return None

    values = [item.strip() for item in raw.split(",") if item.strip()]
    if not values:
        return None

    return [int(item) for item in values]


def load_yolox_model(exp_file: str, checkpoint_path: str) -> torch.nn.Module:
    from yolox.exp import get_exp

    exp = get_exp(exp_file, None)
    model = exp.get_model()

    checkpoint = torch.load(checkpoint_path, map_location="cpu")
    state_dict = checkpoint["model"] if "model" in checkpoint else checkpoint
    model.load_state_dict(state_dict, strict=True)
    model.eval()

    if hasattr(model, "head") and hasattr(model.head, "decode_in_inference"):
        model.head.decode_in_inference = True

    return model


class YOLOXDetectorWrapper(torch.nn.Module):
    """
    Convert YOLOX predictions into the fixed Nx6 format used by the iOS MVP.

    Output rows are:
    [x1, y1, x2, y2, score, classId]

    Coordinates are normalized to 0...1 and class IDs can optionally be
    filtered/remapped so the iOS postprocessor can keep a simple label table.
    """

    def __init__(
        self,
        detector: torch.nn.Module,
        input_width: int,
        input_height: int,
        max_detections: int = 100,
        score_threshold: float = 0.05,
        selected_class_ids: list[int] | None = None,
    ):
        super().__init__()
        self.detector = detector.eval()
        self.input_width = float(input_width)
        self.input_height = float(input_height)
        self.max_detections = max_detections
        self.score_threshold = score_threshold
        self.has_selected_classes = bool(selected_class_ids)

        class_id_tensor = torch.tensor(selected_class_ids or [], dtype=torch.long)
        self.register_buffer("selected_class_ids", class_id_tensor, persistent=False)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        predictions = self.detector(x)

        if isinstance(predictions, (tuple, list)):
            predictions = predictions[0]

        if predictions.ndim == 2:
            predictions = predictions.unsqueeze(0)

        if predictions.ndim != 3:
            raise ValueError(f"Expected YOLOX output with 3 dims, got {predictions.shape}")

        predictions = predictions[0]
        boxes = predictions[:, :4]
        objectness = predictions[:, 4]
        class_probs = predictions[:, 5:]

        class_scores, class_ids = class_probs.max(dim=1)
        scores = objectness * class_scores

        center_x = boxes[:, 0]
        center_y = boxes[:, 1]
        width = boxes[:, 2]
        height = boxes[:, 3]

        x1 = ((center_x - (width * 0.5)) / self.input_width).clamp(0.0, 1.0)
        y1 = ((center_y - (height * 0.5)) / self.input_height).clamp(0.0, 1.0)
        x2 = ((center_x + (width * 0.5)) / self.input_width).clamp(0.0, 1.0)
        y2 = ((center_y + (height * 0.5)) / self.input_height).clamp(0.0, 1.0)

        remapped_class_ids = class_ids
        class_mask = torch.ones_like(scores, dtype=torch.bool)

        if self.has_selected_classes:
            matches = class_ids.unsqueeze(1) == self.selected_class_ids.unsqueeze(0)
            class_mask = matches.any(dim=1)
            remapped_class_ids = matches.to(torch.long).argmax(dim=1)

        score_mask = scores >= self.score_threshold
        keep_mask = class_mask & score_mask
        filtered_scores = torch.where(keep_mask, scores, torch.zeros_like(scores))
        topk_count = min(self.max_detections, filtered_scores.shape[0])

        top_scores, top_indices = filtered_scores.topk(
            topk_count,
            dim=0,
            largest=True,
            sorted=True,
        )

        detections = torch.stack(
            [
                x1.index_select(0, top_indices),
                y1.index_select(0, top_indices),
                x2.index_select(0, top_indices),
                y2.index_select(0, top_indices),
                top_scores,
                remapped_class_ids.index_select(0, top_indices).to(top_scores.dtype),
            ],
            dim=1,
        )

        return detections


def export_to_coreml_pte(
    model: torch.nn.Module,
    output_path: str = "detector_coreml.pte",
    input_width: int = 320,
    input_height: int = 320,
    max_detections: int = 100,
    score_threshold: float = 0.05,
    selected_class_ids: list[int] | None = None,
    lower_full_graph: bool = False,
) -> None:
    model = model.eval()
    wrapped = YOLOXDetectorWrapper(
        detector=model,
        input_width=input_width,
        input_height=input_height,
        max_detections=max_detections,
        score_threshold=score_threshold,
        selected_class_ids=selected_class_ids,
    )

    example_inputs = (torch.randn(1, 3, input_height, input_width),)
    exported_program = export(wrapped, example_inputs)

    compile_specs = CoreMLBackend.generate_compile_specs(
        compute_unit=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
    )

    partitioner = CoreMLPartitioner(
        compile_specs=compile_specs,
        lower_full_graph=lower_full_graph,
    )

    executorch_program = to_edge_transform_and_lower(
        exported_program,
        partitioner=[partitioner],
    ).to_executorch()

    with open(output_path, "wb") as file:
        file.write(executorch_program.buffer)

    print(f"saved: {output_path}")


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Export a YOLOX detector to ExecuTorch/Core ML.")
    parser.add_argument("--exp-file", required=True, help="YOLOX experiment file, for example exps/default/yolox_s.py")
    parser.add_argument("--ckpt", required=True, help="YOLOX checkpoint path")
    parser.add_argument("--output", default="detector_coreml.pte", help="Output .pte filename")
    parser.add_argument("--input-width", type=int, default=320, help="Model input width")
    parser.add_argument("--input-height", type=int, default=320, help="Model input height")
    parser.add_argument("--max-detections", type=int, default=100, help="Number of rows to keep in the exported Nx6 tensor")
    parser.add_argument(
        "--score-threshold",
        type=float,
        default=0.05,
        help="Prefilter score threshold before the iOS-side threshold/NMS pass",
    )
    parser.add_argument(
        "--selected-class-ids",
        default=None,
        help="Comma-separated YOLOX class IDs to keep and remap to 0..N-1. Example: 0,32 for COCO person + sports ball.",
    )
    parser.add_argument(
        "--lower-full-graph",
        action="store_true",
        help="Try full Core ML delegation once the graph is stable on device.",
    )
    return parser


if __name__ == "__main__":
    args = build_arg_parser().parse_args()
    selected_class_ids = parse_class_ids(args.selected_class_ids)

    model = load_yolox_model(args.exp_file, args.ckpt)
    export_to_coreml_pte(
        model=model,
        output_path=args.output,
        input_width=args.input_width,
        input_height=args.input_height,
        max_detections=args.max_detections,
        score_threshold=args.score_threshold,
        selected_class_ids=selected_class_ids,
        lower_full_graph=args.lower_full_graph,
    )
