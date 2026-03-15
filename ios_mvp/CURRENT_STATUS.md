# Current Status

Last updated: 2026-03-16

## Scope

This document summarizes what has been implemented so far for the iOS real-time detection MVP in this repository.

The current goal is:

- Run an iPhone camera preview
- Load an ExecuTorch model on-device
- Detect `person` and `ball`
- Draw bounding boxes in real time

## Current Direction

- Model family: `YOLO11`
- Current exported weight: `YOLO11s`
- Runtime: `ExecuTorch` on iOS
- App type: SwiftUI app wrapping a UIKit camera/detection view controller

Important note:

- The current `YOLO11s` file is a COCO-pretrained detector, not a custom soccer-only model.
- `person` uses COCO class `0`
- `sports ball` uses COCO class `32`
- In the app UI, class `32` is remapped and shown as `ball`

## What Has Been Added

### 1. YOLO11 -> ExecuTorch export flow

Added files:

- `ios_mvp/export_yolo11_executorch.py`
- `ios_mvp/EXPORT_YOLO11_TO_EXECUTORCH_IOS.md`
- `ios_mvp/requirements-yolo11.txt`

What this does:

- Loads a YOLO11 `.pt` model
- Exports it to ExecuTorch format
- Produces a `.pte` bundle for the iOS app

Generated artifacts:

- `ios_mvp/build/detector.pte`
- `ios_mvp/build/metadata.yaml`
- `yolo11s_executorch_model/`

Current model files in the repo:

- `yolo11n.pt`
- `yolo11s.pt`

## 2. iOS app scaffold

Template-level files added under `ios_mvp/RealtimeDetectionMVP/`:

- `RealtimeDetectionMVPApp.swift`
- `DetectionViewControllerRepresentable.swift`

Actual Xcode app files added under `RealtimeDetectionMVP/RealtimeDetectionMVP/`:

- `CameraService.swift`
- `DetectionPostProcessor.swift`
- `DetectionViewController.swift`
- `DetectionViewControllerRepresentable.swift`
- `ExecuTorchRunner.swift`
- `FramePreprocessor.swift`
- `Models.swift`
- `OverlayView.swift`
- `RealtimeDetectionMVPApp.swift`
- `SimpleTracker.swift`
- `build/detector.pte`
- `build/metadata.yaml`

## 3. Xcode project setup

Actual Xcode project:

- `RealtimeDetectionMVP/RealtimeDetectionMVP.xcodeproj`

Project settings already reflected:

- Camera usage description added
- iPhone portrait + landscape orientations enabled
- `-Wl,-all_load` added to linker flags
- ExecuTorch Swift Package added from:
  - `https://github.com/pytorch/executorch.git`
  - branch: `swiftpm-1.1.0`

Products added to the target:

- `executorch`
- `backend_xnnpack`
- `kernels_optimized`

Reference setup doc:

- `ios_mvp/XCODE_SETUP.md`

## Runtime Pipeline

The current runtime flow is:

1. Camera frames are captured with `AVFoundation`
2. Frames are resized and converted to RGB float tensor data
3. The tensor is passed into `detector.pte`
4. Raw YOLO11 output is parsed
5. `person` and `sports ball` are filtered
6. Boxes are normalized and passed through NMS
7. Detections are fed into a lightweight tracker
8. Bounding boxes and labels are drawn on top of the preview

Relevant files:

- `RealtimeDetectionMVP/RealtimeDetectionMVP/CameraService.swift`
- `RealtimeDetectionMVP/RealtimeDetectionMVP/FramePreprocessor.swift`
- `RealtimeDetectionMVP/RealtimeDetectionMVP/ExecuTorchRunner.swift`
- `RealtimeDetectionMVP/RealtimeDetectionMVP/DetectionPostProcessor.swift`
- `RealtimeDetectionMVP/RealtimeDetectionMVP/SimpleTracker.swift`
- `RealtimeDetectionMVP/RealtimeDetectionMVP/OverlayView.swift`
- `RealtimeDetectionMVP/RealtimeDetectionMVP/DetectionViewController.swift`

## Important Fixes Already Applied

### Raw YOLO11 output parsing

The first iOS MVP code expected a flat `N x 6` tensor:

- `[x1, y1, x2, y2, score, classId]`

But the exported YOLO11 ExecuTorch model returns raw detection head output:

- shape similar to `1 x 84 x 8400`

This was fixed by updating the postprocessor to:

- read raw class channels
- extract only COCO class `0` and `32`
- convert `cx, cy, w, h` into normalized `xyxy`
- apply confidence filtering and NMS

File:

- `RealtimeDetectionMVP/RealtimeDetectionMVP/DetectionPostProcessor.swift`

### Model input size alignment

The preprocessor originally used `320 x 320`.

The current exported `YOLO11s` model expects `640 x 640`.

This was fixed in:

- `RealtimeDetectionMVP/RealtimeDetectionMVP/DetectionViewController.swift`

### Swift `min` / `max` ambiguity fix

`Models.swift` had Swift build errors due to `min` / `max` resolution.
This was fixed by using `Swift.min` and `Swift.max`.

File:

- `RealtimeDetectionMVP/RealtimeDetectionMVP/Models.swift`

### Landscape orientation support

The camera output was originally forced to portrait only.

This was updated so that:

- preview orientation follows interface orientation
- actual video output orientation also follows interface orientation
- view transitions update the capture orientation when rotating the phone

Files:

- `RealtimeDetectionMVP/RealtimeDetectionMVP/CameraService.swift`
- `RealtimeDetectionMVP/RealtimeDetectionMVP/DetectionViewController.swift`

## Current Behavior On Device

What is already working:

- App launches on iPhone
- Camera preview opens
- ExecuTorch package is integrated
- `detector.pte` is bundled in the app
- Detection code path is wired end-to-end
- Portrait and landscape camera handling are implemented

What may still vary during testing:

- `person` should be easier to detect than `ball`
- `ball` detection may be weak because the current model is generic COCO-pretrained `YOLO11s`
- Detection quality depends on distance, lighting, and object size

## Known Limitations

- This is not yet a soccer-specialized model
- No custom `person + ball` training has been applied yet
- The current `ball` class depends on COCO `sports ball`
- No field calibration, homography, mini-map, or event analysis is implemented yet
- No highlight generation or LLM feedback pipeline is connected yet
- No dedicated debugging overlay for detection counts is shown yet

## Recommended Next Steps

### Short-term

- Rebuild and test again on a real iPhone after the latest orientation and postprocessing updates
- Verify that `person` boxes appear reliably in both portrait and landscape
- If needed, add temporary debug logs for:
  - raw output size
  - detection count before NMS
  - detection count after NMS

### Medium-term

- Replace COCO-pretrained `YOLO11s` with a custom fine-tuned `person + ball` model
- Keep class order as:
  - `0 = person`
  - `1 = ball`
- Re-export the custom model to `.pte`
- Retest on-device

### Long-term

- Add soccer-specific tracking improvements
- Add field coordinate mapping
- Add event extraction
- Add heatmaps and analytics
- Add coaching / summary layer

## Rebuild / Run Notes

In Xcode:

1. Select the real iPhone as the run target
2. `Product > Clean Build Folder`
3. Build and run again
4. Allow camera permission on the device if prompted

Model export command used for YOLO11:

```bash
source .venv/bin/activate
python ios_mvp/export_yolo11_executorch.py \
  --weights /path/to/yolo11s.pt \
  --imgsz 640 \
  --bundle-dir ios_mvp/build \
  --bundle-name detector.pte
```

## Main Files To Check First

If something breaks again, check these first:

- `RealtimeDetectionMVP/RealtimeDetectionMVP/DetectionViewController.swift`
- `RealtimeDetectionMVP/RealtimeDetectionMVP/DetectionPostProcessor.swift`
- `RealtimeDetectionMVP/RealtimeDetectionMVP/CameraService.swift`
- `RealtimeDetectionMVP/RealtimeDetectionMVP/ExecuTorchRunner.swift`
- `RealtimeDetectionMVP/RealtimeDetectionMVP/build/detector.pte`

