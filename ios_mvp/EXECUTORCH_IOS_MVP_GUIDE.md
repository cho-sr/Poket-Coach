# ExecuTorch iOS 실시간 객체 탐지/트래킹 MVP 가이드

## 가정

- 목표 디바이스는 `iPhone 17` 계열이며, 앱 배포 타깃은 `iOS 18+`로 잡아도 무방하다고 가정한다.
- 탐지 모델은 `320x320` 고정 입력을 사용한다.
- MVP 출력 포맷은 후처리를 단순화하기 위해 `N x 6` 형태의 flat tensor를 가정한다.
  - 각 row: `[x1, y1, x2, y2, score, classId]`
  - 좌표는 `0.0 ~ 1.0` normalized 좌표
- 추적기는 MVP 단계에서 `상수 속도 + IoU matching` 기반으로 구현하고, 축구 분석 단계에서 `ByteTrack / SORT / ReID` 계열로 교체한다.

## 1. 전체 시스템 아키텍처

### Camera input

- `AVFoundation`의 `AVCaptureSession`이 카메라 입력을 받는다.
- `AVCaptureVideoDataOutput`으로 `CVPixelBuffer`를 실시간 전달받는다.
- 프리뷰는 `AVCaptureVideoPreviewLayer`로 그리고, 오버레이는 별도 `OverlayView`가 담당한다.

### Frame preprocessing

- 카메라 프레임은 추론 입력 크기(예: `320x320`)로 리사이즈한다.
- BGRA 픽셀을 RGB float tensor로 변환한다.
- 입력 텐서는 `NCHW` 형태 `[1, 3, H, W]`로 맞춘다.

### ExecuTorch inference

- 추론 엔진은 반드시 `ExecuTorch`를 사용한다.
- iOS 쪽에서는 `ExecuTorch` Swift 바인딩으로 `.pte` 모델을 로드한다.
- 실제 연산은 ExecuTorch가 로드된 backend에 따라 `Core ML` 또는 `MPS`로 위임된다.

### Detection post-processing

- 모델 raw output을 score threshold로 필터링한다.
- 필요하면 NMS를 적용한다.
- 모델 출력 좌표를 normalized box로 유지하고, 렌더링 직전에 화면 좌표로 바꾼다.

### Tracking

- 모든 프레임에서 탐지를 돌리지 않는다.
- 권장 구조:
  - `detection frame`: ExecuTorch detector 실행
  - `non-detection frame`: tracker만 실행
- MVP tracker는 `IoU matching + 간단한 velocity propagation`으로 ID를 유지한다.
- 추후 축구 분석에서는 `ByteTrack` 또는 `SORT + Kalman`으로 교체한다.

### Overlay rendering

- 탐지/추적 결과는 `OverlayView`가 box, class label, tracking ID를 그린다.
- 프리뷰 레이어와 같은 좌표계로 맞추기 위해 metadata rect 변환을 사용한다.

### Threading / async inference

- `sessionQueue`: AVCapture 세션 구성
- `cameraOutputQueue`: 카메라 프레임 수신 및 lightweight tracker 갱신
- `inferenceQueue`: 전처리 + ExecuTorch 추론 + 후처리
- `main thread`: UI 갱신만 담당

### Performance optimization

- detection interval(`N프레임마다 1회`) 적용
- inference busy 중에는 새 detection 요청을 막고 tracker만 진행
- 입력 해상도 축소
- `alwaysDiscardsLateVideoFrames = true`
- Release runtime 사용
- Core ML backend + FP16 우선 검토

## 2. backend 선택

### Core ML backend를 우선 선택해야 하는 이유

- ExecuTorch 공식 iOS backend 문서에서 Apple 하드웨어 가속 경로로 `Core ML Backend`를 `recommended for iOS`로 분류한다.
- Core ML backend는 CPU/GPU/ANE를 사용할 수 있어 모바일 실시간 추론에서 가장 유리하다.
- `compute_precision`을 `FLOAT16`으로 둘 수 있고, ANE는 FP16 경로와 궁합이 좋다.
- `minimum_deployment_target`, `compute_unit`, `compiled model` 등을 조정해 실제 배포 환경에 맞춘 최적화를 넣기 쉽다.

### MPS backend를 고려할 때

- MPS backend는 Apple GPU를 직접 활용하는 좋은 대안이다.
- 장점:
  - Core ML lowering이 까다로운 모델일 때 우회 경로가 될 수 있다.
  - iOS 최소 요구사항이 더 낮다(`iOS 15.4+`).
- 단점:
  - 주 가속 경로가 GPU라서, ANE 활용 측면에서는 Core ML 쪽이 더 유리하다.
  - iOS 실시간 모바일 앱 관점에서는 전력/지연시간 균형에서 Core ML이 먼저 검토할 선택지다.

### 최종 권장안

- `1순위: ExecuTorch + Core ML backend`
- `2순위 fallback: ExecuTorch + MPS backend`
- 실무 권장:
  - 먼저 Core ML lowering이 잘 되는 detector를 고른다.
  - unsupported op 때문에 graph break가 많거나 성능이 흔들리면 MPS로 비교 측정한다.

## 3. 모델 배포 파이프라인

### PyTorch 모델 준비

- `model.eval()` 상태에서 export한다.
- 입력 shape를 단순하게 유지한다.
  - MVP는 `1x3x320x320` 고정 shape 권장
- 초기에 dynamic shape를 과하게 넣지 않는다.
- 축구 프로젝트로 커질 때만 enumerated shapes를 검토한다.

### ExecuTorch export / lowering 흐름

1. `torch.export.export`
2. `to_edge_transform_and_lower`
3. `to_executorch`
4. `.pte` 저장

Core ML 타깃일 때는 `CoreMLPartitioner`와 compile spec를 사용한다.

### iOS 앱에 넣는 아티팩트

- 모델 본체: `detector.pte`
- 선택 사항:
  - program / weights 분리 시 `detector.ptd`
- 앱 런타임:
  - `executorch`
  - `backend_coreml` 또는 `backend_mps`
  - 필요한 kernel 라이브러리

### Swift에서 로드

- `Bundle.main.path(forResource: "detector", ofType: "pte")`
- `Module(filePath:)`
- `try module.load("forward")`
- 입력을 `Tensor<Float>`로 만들고 `forward` 호출

## 4. MVP 개발 순서

1. `AVFoundation` 카메라 프리뷰
2. `AVCaptureVideoDataOutput`으로 프레임 수신
3. `FramePreprocessor` 구현
4. `ExecuTorchRunner`로 `.pte` 로딩
5. 단일 프레임 추론
6. `DetectionPostProcessor`로 결과 해석
7. `OverlayView`로 bounding box 표시
8. `SimpleTracker` 연결
9. detection interval 적용
10. Core ML backend 튜닝

## 5. 폴더 / 파일 구조 설계

```text
ios_mvp/
  EXECUTORCH_IOS_MVP_GUIDE.md
  export_coreml_detector.py
  RealtimeDetectionMVP/
    Models.swift
    CameraService.swift
    FramePreprocessor.swift
    ExecuTorchRunner.swift
    DetectionPostProcessor.swift
    SimpleTracker.swift
    OverlayView.swift
    DetectionViewController.swift
```

- `Models.swift`: Detection / Track 공용 모델
- `CameraService.swift`: AVFoundation 캡처
- `FramePreprocessor.swift`: 리사이즈 + tensor 변환
- `ExecuTorchRunner.swift`: `.pte` 로딩 및 추론 호출
- `DetectionPostProcessor.swift`: threshold/NMS/좌표 정리
- `SimpleTracker.swift`: tracking ID 유지
- `OverlayView.swift`: 박스/라벨/ID 렌더링
- `DetectionViewController.swift`: 전체 흐름 orchestration

## 6. 샘플 코드

- Swift MVP 뼈대는 `RealtimeDetectionMVP/` 폴더에 분리해 두었다.
- 실제 프로젝트에서는 여기에 Xcode target, app entry, Info.plist 권한 설정(`NSCameraUsageDescription`)을 추가하면 된다.

## 7. 성능 최적화 핵심

- 입력 해상도는 초반부터 `320x320` 또는 `384x384` 정도로 제한
- `detectionInterval = 2~5`부터 시작
- inference 중에는 새 detection을 밀어 넣지 말고 tracker만 갱신
- UI 갱신은 메인 스레드, 추론은 백그라운드
- Core ML backend의 `FLOAT16` 우선
- graph break가 있으면 `lower_full_graph=True`로 검증해서 완전 위임 가능 여부 확인
- dynamic shape 대신 고정 shape 또는 enumerated shape 검토
- 첫 실행 로딩 시간을 줄이려면 Core ML compiled model 옵션 검토

## 8. 축구 프로젝트 확장 방향

### 선수 탐지

- `person` detector를 soccer-domain 데이터로 재학습
- 카메라 고정형이면 field-specific augmentation을 많이 준다

### 공 탐지

- 공은 매우 작아서 별도 head 또는 별도 detector가 유리하다
- 실무에서는 `player detector`와 `ball detector`를 분리하는 편이 안정적이다

### 특정 사용자 추적

- `selected track ID`를 고정 추적 대상으로 지정
- 필요하면 crop 기반 ReID embedding을 추가한다

### 이동 경로 저장

- `trackID -> [timestamp, centerPoint]` 누적 저장
- 나중에 히트맵, 이동 거리, 속도 계산 가능

### 이벤트 추정

- possession, pass, shot 같은 이벤트는 detector/tracker 위에 올라가는 2차 로직으로 구현
- 공-선수 거리, 속도 변화, 방향 전환, field zone 정보를 feature로 사용

## 참고

- Core ML backend가 우선 권장되는 이유는 공식 iOS backend 문서에서 직접 `recommended for iOS`로 분류하기 때문이다.
- 다만 최종 선택은 반드시 실제 디바이스에서 `평균 latency`, `P95 latency`, `thermal throttling`, `battery drain`, `ID stability`를 함께 측정해서 결정해야 한다.
