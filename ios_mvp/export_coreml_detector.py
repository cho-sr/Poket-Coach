import coremltools as ct
import torch
from torch.export import export

from executorch.backends.apple.coreml.compiler import CoreMLBackend
from executorch.backends.apple.coreml.partition.coreml_partitioner import (
    CoreMLPartitioner,
)
from executorch.exir import to_edge_transform_and_lower


class DetectorWrapper(torch.nn.Module):
    """
    MVP export wrapper.

    In a real project, inject the trained detector here and
    normalize its output format to match the iOS postprocessor.
    """

    def __init__(self, detector: torch.nn.Module):
        super().__init__()
        self.detector = detector.eval()

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # TODO:
        # 1) Call the real detector forward pass.
        # 2) Convert the raw head output into N x 6 or 1 x N x 6.
        # 3) Keep the format aligned with the iOS postprocessor.
        return self.detector(x)


def export_to_coreml_pte(
    model: torch.nn.Module,
    output_path: str = "detector_coreml.pte",
    input_size: int = 320,
) -> None:
    model = model.eval()
    wrapped = DetectorWrapper(model)

    example_inputs = (torch.randn(1, 3, input_size, input_size),)
    exported_program = export(wrapped, example_inputs)

    compile_specs = CoreMLBackend.generate_compile_specs(
        compute_unit=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
    )

    partitioner = CoreMLPartitioner(
        compile_specs=compile_specs,
        # TODO:
        # Once export is stable, try True to validate full Core ML delegation.
        lower_full_graph=False,
    )

    executorch_program = to_edge_transform_and_lower(
        exported_program,
        partitioner=[partitioner],
    ).to_executorch()

    with open(output_path, "wb") as file:
        file.write(executorch_program.buffer)

    print(f"saved: {output_path}")


if __name__ == "__main__":
    # TODO:
    # Load the real detector here.
    # Example: model = YourDetector(...)
    dummy_model = torch.nn.Identity()
    export_to_coreml_pte(dummy_model)
