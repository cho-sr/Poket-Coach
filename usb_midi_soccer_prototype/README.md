# iPhone USB MIDI 서보 프로토타입

## 간단한 아키텍처 요약
- iPhone 앱 파이프라인: 카메라 -> YOLO26n 사람 검출 -> 사용자가 선수 1명을 탭으로 선택 -> 이전 중심점에 가장 가까운 대상으로 재추적 -> 데드존 컨트롤러 -> 유선 USB MIDI Control Change 출력
- 전송 방식: 유선 USB-C만 사용합니다. 보드는 반드시 USB MIDI 장치로 인식되어야 합니다. BLE, Wi-Fi, USB serial은 사용하지 않습니다.
- 보드 동작: Teensy 4.1이 CC 메시지를 받아 `LEFT` 또는 `RIGHT` 명령마다 서보를 작은 각도로 한 번씩 움직이고, 각도를 제한하며, `STOP` 또는 타임아웃 시 현재 위치를 유지합니다.
- 모터 동작: step-and-hold 방식만 사용합니다. 서보를 연속 회전 모터처럼 계속 돌리지 않습니다.

## 전체 시스템 설계 개요
1. iPhone이 카메라 프레임을 받아 기기 내에서 YOLO26n 사람 검출을 수행합니다.
2. 사용자는 검출된 선수 중 한 명을 한 번 탭해서 목표 대상을 고정합니다.
3. 이후 프레임에서는 이전 목표 중심점과 가장 가까운 검출 결과를 같은 선수로 선택합니다.
4. 앱은 목표 bbox 중심의 `x` 좌표를 계산합니다.
5. 화면 가로 중심을 기준으로 세로 데드존 밴드를 둡니다.
6. 목표 중심이 데드존 안에 있으면 `STOP`을 한 번 보내거나 아무것도 보내지 않습니다.
7. 목표 중심이 데드존의 왼쪽 또는 오른쪽 밖에 3프레임 연속으로 위치하면 `LEFT` 또는 `RIGHT`를 전송합니다.
8. 앱은 MIDI 전송을 약 150ms 간격으로 제한하여, 매 프레임마다 명령이 쏟아지지 않고 서보가 이산적인 단계로 움직이도록 합니다.
9. Teensy는 명령 1개당 작은 각도 스텝 1번만 적용하고, 다음 명령이 올 때까지 현재 위치를 유지합니다.

## Teensy 4.1을 우선 추천하는 이유
- Teensyduino에서 USB MIDI를 포함한 네이티브 USB 디바이스 지원이 비교적 간단합니다.
- `usbMIDI`가 이 프로토타입 용도에 잘 맞고 안정적입니다.
- 나중에 센서, 상태 LED, 2축 제어를 추가하더라도 여유가 있습니다.
- Arduino Leonardo/Micro도 ATmega32U4 기반이라 USB MIDI 에뮬레이션이 가능하지만, 첫 프로토타입은 Teensy 4.1 쪽이 더 깔끔합니다.

## Swift 기준 iPhone 앱 구조
앱은 아래 5개 구성요소로 나누는 것이 좋습니다.

1. `CameraService`
- `AVCaptureSession`으로 카메라 프레임을 받아 검출기에 전달합니다.

2. `PersonDetector`
- YOLO26n 추론 래퍼입니다.
- 출력은 정규화된 bbox와 confidence를 담은 `[PersonObservation]`입니다.
- 이 저장소에서는 기존 camera/inference 분리를 유지하고, 정규화된 사람 bbox를 반환하는 검출기 래퍼로 YOLO26n을 연결하는 방식이 가장 깔끔합니다.

3. `TargetSelectionController`
- 첫 탭 선택을 처리합니다.
- 이후 프레임에서는 이전 목표 중심점과 가장 가까운 검출 결과를 계속 선택합니다.

4. `DeadzoneCommandController`
- 목표 중심 `x`를 `STOP`, `LEFT`, `RIGHT`로 변환합니다.
- 3프레임 디바운스를 적용합니다.
- 100~200ms MIDI 전송 제한을 적용합니다.

5. `USBMIDIServoOutput`
- 유선 USB로 연결된 CoreMIDI 목적지를 탐색합니다.
- Teensy의 MIDI 목적지에 연결합니다.
- 방향용 CC 20, 스텝 강도용 CC 21을 전송합니다.

권장 시작값:

| 상수 | 권장 시작값 |
| --- | --- |
| `deadzoneWidthRatio` | `0.22` |
| `consecutiveFramesToCommit` | `3` |
| `sendInterval` | `0.15` 초 |
| `stepStrength` | `24` |
| `lostTargetStopFrames` | `6` |

### 앱 측 프레임 루프
```swift
let persons = detectorOutput
let target = targetSelection.resolveTrackedTarget(in: persons)
let result = try trackingCoordinator.processFrame(persons: persons, midi: midiOutput)
overlay.draw(persons: persons, selected: result.selectedTarget, deadzone: result.deadzoneRange)
```

### 탭 선택 흐름
```swift
let selected = trackingCoordinator.handleUserTap(
    normalizedPoint: tapPoint,
    persons: currentPersons
)
```

참고:
- 검출기, 오버레이, 제어 로직이 같은 기준을 쓰도록 좌표는 정규화된 값을 사용하는 것이 좋습니다.
- 보정 대상은 가로 방향뿐이므로 데드존은 세로 밴드 형태로 유지합니다.
- 명령을 매 프레임 전송하지 마세요. 전송 제한은 선택 사항이 아니라 설계의 핵심입니다.

## Arduino/Teensy C++ 기준 보드 펌웨어 구조
펌웨어도 가능한 한 단순하게 유지합니다.

1. USB MIDI 수신부
- Teensy는 USB 타입을 `MIDI`로 설정해 컴파일합니다.
- 펌웨어는 채널 1의 Control Change 메시지를 수신합니다.

2. 명령 파서
- `CC 20`은 방향 명령입니다.
- `CC 21`은 마지막 스텝 강도를 저장합니다.

3. 서보 제어기
- `LEFT`이면 각도를 감소시킵니다.
- `RIGHT`이면 각도를 증가시킵니다.
- `STOP`이면 현재 각도를 유지합니다.
- 예를 들어 `40...140`도처럼 안전 범위로 제한합니다.

4. 안전 레이어
- 일정 시간 유효한 명령이 없으면 현재 위치를 유지합니다.
- 잘못된 데이터가 와도 서보 각도는 항상 범위 안으로 제한합니다.
- 실제 부하를 연결하기 전에는 보드 LED로 MIDI 수신 여부를 먼저 확인할 수 있게 합니다.

권장 초기 매핑:

| 입력 | 의미 |
| --- | --- |
| `CC 20 value 0` | `STOP` |
| `CC 20 value 1` | `LEFT` |
| `CC 20 value 2` | `RIGHT` |
| `CC 21 value 0...127` | 스텝 강도 |

참고 스케치는 아래에 있습니다.
- `teensy/teensy_usb_midi_servo.ino`

## MIDI 프로토콜 요약
프로토콜은 의도적으로 아주 작고 단순하게 유지합니다.

| 메시지 | 값 | 의미 |
| --- | --- | --- |
| `CC 20` | `0` | `STOP` |
| `CC 20` | `1` | `LEFT` |
| `CC 20` | `2` | `RIGHT` |
| `CC 21` | `0...127` | 스텝 강도 |

프로토콜 규칙:
- 특별한 이유가 없으면 채널 1을 사용합니다.
- 이동 명령을 보낼 때는 `CC 20`보다 먼저 `CC 21`을 보냅니다.
- `STOP`은 상태가 바뀔 때 한 번만 보내면 되고, 매 프레임 보낼 필요는 없습니다.
- 보드는 패킷 일부를 놓치더라도 안전해야 합니다. 실제 이동은 `LEFT` 또는 `RIGHT` 명령이 왔을 때만 수행합니다.

## 데드존 제어 로직
이미지 좌표는 `x = 0.0 ... 1.0`의 정규화 값으로 처리합니다.

예를 들어 `deadzoneWidthRatio = 0.22`라면:
- 왼쪽 경계 = `0.5 - 0.11 = 0.39`
- 오른쪽 경계 = `0.5 + 0.11 = 0.61`

판정 규칙:
- `x < 0.39` -> 목표 방향은 `LEFT`
- `0.39 <= x <= 0.61` -> 목표 방향은 `STOP`
- `x > 0.61` -> 목표 방향은 `RIGHT`

디바운스와 히스테리시스:
- 새 `LEFT` 또는 `RIGHT` 방향으로 바꾸기 전에, 데드존 밖 프레임이 3번 연속 나와야 합니다.
- 이미 한 방향으로 움직이고 있다면, 같은 방향 명령은 설정된 전송 간격에 맞춰서만 다시 보냅니다.
- 목표가 다시 데드존 안으로 들어오면 `STOP`을 한 번 보내고 정지 상태를 유지합니다.

이 방식의 장점:
- 중심 근처에서 발생하는 떨림을 줄일 수 있습니다.
- 매 프레임 서보 명령을 보내지 않게 됩니다.
- 계속 헌팅하는 동작 대신, step-and-hold 형태의 제어가 됩니다.

## 안전성과 안정성 로직
- 프로토타입 전원 메모: iPhone 전원만 사용하는 방식은 테스트 모드로만 생각해야 합니다.
- SG90 같은 작은 마이크로 서보도 순간 전류 피크로 USB 전원을 흔들 수 있습니다.
- iPhone이 보드를 끊거나, 앱이 MIDI 목적지를 잃거나, 부하가 걸렸을 때 서보가 불안정하게 떨리면 즉시 서보 전원을 외부 5V로 분리하는 것이 좋습니다.
- 외부 5V 전원과 Teensy GND는 반드시 공통 접지로 묶어야 합니다.
- 외부 전원으로 바꿀 때도 신호선 연결 위치는 바꾸지 않습니다.

### 나중에 외부 서보 전원으로 바꿀 위치
초기 프로토타입 배선:
- servo signal -> Teensy PWM 핀
- servo GND -> Teensy GND
- servo +5 V -> 초기 테스트에서만 보드/iPhone이 공급하는 5V

나중에 안정화한 배선:
- servo signal -> 동일한 Teensy PWM 핀
- servo GND -> 외부 5V 전원 GND
- Teensy GND -> 같은 외부 전원 GND
- servo +5 V -> 외부 안정화 5V 전원

즉, 실제로 바뀌는 것은 서보 전원 공급원뿐이고, 신호 배선은 그대로 유지됩니다.

## 실제 서보 부하를 연결하기 전에 먼저 테스트할 것
1. Teensy를 iPhone에 연결하고, 앱에서 USB MIDI 목적지로 인식되는지 확인합니다.
2. 서보를 연결하지 않은 상태에서 수동으로 `STOP`, `LEFT`, `RIGHT` CC 메시지를 보내고 Teensy LED가 반응하는지 확인합니다.
3. 그 다음 SG90을 서보혼을 빼거나 기계적 부하가 없는 상태로 연결합니다.
4. 메시지 1개가 작은 각도 스텝 1번에 대응하는지, `STOP`이 현재 위치를 잘 유지하는지 확인합니다.
5. 그 다음에만 실제 팬 기구나 카메라 부하를 연결합니다.
6. USB 연결이 리셋되거나 서보가 떨리면, 서보 전원을 외부 5V로 옮기고 공통 GND를 유지합니다.

## 최소 코드 스켈레톤
- Swift coordinator 및 CoreMIDI helper:
  - `swift/SoccerUSBMIDIPrototype.swift`
- Teensy 펌웨어:
  - `teensy/teensy_usb_midi_servo.ino`

## 단계별 구현 체크리스트
1. iPhone 앱이 기기 내에서 정규화된 사람 검출 결과를 출력하도록 YOLO26n을 export하거나 래핑합니다.
2. 탭으로 대상을 선택하는 UI를 추가하고, 선택된 목표 중심점을 저장합니다.
3. 각 프레임마다 이전 목표 중심점과 가장 가까운 사람 검출 결과를 선택합니다.
4. 세로 중심 데드존 밴드를 추가하고, 오버레이가 실제 제어 경계와 일치하는지 확인합니다.
5. 3프레임 방향 디바운스를 추가합니다.
6. 약 150ms의 MIDI 전송 제한을 추가합니다.
7. CoreMIDI 목적지 탐색을 구현하고 Teensy USB MIDI 엔드포인트에 연결합니다.
8. 각 이동 업데이트마다 `CC 21`과 `CC 20`을 전송합니다.
9. Teensy 스케치를 USB 타입 `MIDI`로 설정해 업로드합니다.
10. 먼저 LED만으로, 또는 부하 없는 서보로 명령 처리를 테스트합니다.
11. SG90을 연결하고 `LEFT`, `RIGHT`가 제한된 각도 스텝으로 동작하는지 확인합니다.
12. 전원 불안정이 보이면, 서보 전원선만 외부 안정화 5V로 옮기고 공통 GND를 유지합니다.
