# iPhone USB MIDI Servo Prototype

## Concise Architecture Summary
- iPhone app pipeline: camera -> YOLO26n person detection -> user taps one player -> nearest-center target reacquisition -> deadzone controller -> wired USB MIDI Control Change output.
- Transport: wired USB-C only. The board must enumerate as a USB MIDI device. No BLE, Wi-Fi, or USB serial.
- Board behavior: Teensy 4.1 receives CC messages, converts each `LEFT` or `RIGHT` command into one small servo step, clamps the angle, and holds position on `STOP` or timeout.
- Motor behavior: step-and-hold only. The servo is never driven as a continuously rotating motor.

## Full System Design Overview
1. The iPhone captures camera frames and runs YOLO26n person detection on-device.
2. The user taps one detected player once to lock the target.
3. On later frames, the app picks the detected person whose center is closest to the previous target center.
4. The app computes the target bbox center `x`.
5. A vertical deadzone band is placed around the horizontal screen center.
6. If the target center stays inside the deadzone, the app sends one `STOP` or sends nothing.
7. If the center exits the deadzone on the left or right for 3 consecutive frames, the app sends `LEFT` or `RIGHT`.
8. The app rate-limits MIDI transmission to roughly every 150 ms so the servo moves in discrete steps instead of being spammed every frame.
9. The Teensy applies one small angle step per command and then holds position until the next command.

## Why Teensy 4.1 Is Preferred
- Native USB device support is straightforward in Teensyduino, including USB MIDI mode.
- `usbMIDI` is reliable and low-friction for this exact prototype.
- It gives more headroom than Leonardo or Micro if you later add sensors, status LEDs, or a second axis.
- Arduino Leonardo and Micro can still be used as fallback options because the ATmega32U4 can emulate USB MIDI, but Teensy 4.1 is the cleaner first prototype choice.

## iPhone App Architecture In Swift
Keep the app in five small pieces:

1. `CameraService`
- Uses `AVCaptureSession` and feeds frames into the detector.

2. `PersonDetector`
- Wraps YOLO26n inference.
- Output is `[PersonObservation]` where each observation contains a normalized bbox and confidence.
- In this repo, the cleanest path is to keep the existing camera/inference split and plug YOLO26n into a detector wrapper that returns normalized person boxes.

3. `TargetSelectionController`
- Handles the first tap selection.
- For later frames, keeps choosing the detection whose center is closest to the previous target center.

4. `DeadzoneCommandController`
- Converts target center `x` into `STOP`, `LEFT`, or `RIGHT`.
- Applies the 3-frame debounce requirement.
- Applies the 100 to 200 ms MIDI rate limit.

5. `USBMIDIServoOutput`
- Discovers CoreMIDI destinations over wired USB.
- Connects to the Teensy MIDI destination.
- Sends CC 20 for direction and CC 21 for step strength.

Suggested app-side tunables:

| Constant | Suggested start |
| --- | --- |
| `deadzoneWidthRatio` | `0.22` |
| `consecutiveFramesToCommit` | `3` |
| `sendInterval` | `0.15` seconds |
| `stepStrength` | `24` |
| `lostTargetStopFrames` | `6` |

### App-Side Frame Loop
```swift
let persons = detectorOutput
let target = targetSelection.resolveTrackedTarget(in: persons)
let result = try trackingCoordinator.processFrame(persons: persons, midi: midiOutput)
overlay.draw(persons: persons, selected: result.selectedTarget, deadzone: result.deadzoneRange)
```

### Tap Selection Flow
```swift
let selected = trackingCoordinator.handleUserTap(
    normalizedPoint: tapPoint,
    persons: currentPersons
)
```

Notes:
- Use normalized coordinates so the detector, overlay, and control logic all agree.
- Keep the deadzone as a vertical center band because only horizontal correction matters.
- Do not send commands every frame. The rate limiter is part of the design, not an optimization afterthought.

## Board Firmware Architecture In Arduino/Teensy C++
Keep the firmware equally small:

1. USB MIDI receiver
- Teensy is compiled with USB type set to `MIDI`.
- Firmware listens for Control Change messages on channel 1.

2. Command parser
- `CC 20` maps to direction.
- `CC 21` stores the last step strength.

3. Servo controller
- `LEFT` decrements the angle.
- `RIGHT` increments the angle.
- `STOP` keeps the current angle.
- Clamp to a safe range such as `40...140` degrees.

4. Safety layer
- If no valid command is received for a timeout window, hold position.
- Keep the servo angle in bounds even if bad data arrives.
- Blink or latch the onboard LED during testing so MIDI can be verified before connecting a real load.

Recommended first-pass mapping:

| Input | Meaning |
| --- | --- |
| `CC 20 value 0` | `STOP` |
| `CC 20 value 1` | `LEFT` |
| `CC 20 value 2` | `RIGHT` |
| `CC 21 value 0...127` | step strength |

The reference sketch is in:
- `teensy/teensy_usb_midi_servo.ino`

## MIDI Protocol Summary
Use a deliberately tiny protocol:

| Message | Value | Meaning |
| --- | --- | --- |
| `CC 20` | `0` | `STOP` |
| `CC 20` | `1` | `LEFT` |
| `CC 20` | `2` | `RIGHT` |
| `CC 21` | `0...127` | step strength |

Protocol rules:
- Use channel 1 unless you have a reason to change it.
- Send `CC 21` before `CC 20` when issuing a move command.
- `STOP` can be sent once on state transition, not every frame.
- The board should remain safe if it misses a packet, because it only moves on explicit `LEFT` or `RIGHT` commands.

## Deadzone Control Logic
Treat the image as normalized `x = 0.0 ... 1.0`.

Example with `deadzoneWidthRatio = 0.22`:
- left edge = `0.5 - 0.11 = 0.39`
- right edge = `0.5 + 0.11 = 0.61`

Decision rule:
- `x < 0.39` -> desired direction is `LEFT`
- `0.39 <= x <= 0.61` -> desired direction is `STOP`
- `x > 0.61` -> desired direction is `RIGHT`

Debounce and hysteresis:
- Require 3 consecutive out-of-deadzone frames before committing a new `LEFT` or `RIGHT`.
- Once already moving in one direction, keep sending the same direction only at the configured interval.
- If the target re-enters the deadzone, send one `STOP` and hold.

Why this helps:
- It prevents jitter near the center.
- It avoids commanding the servo on every frame.
- It produces controlled step-and-hold motion instead of constant hunting.

## Safety And Stability Logic
- Prototype power note: iPhone-only power is test mode only.
- Small micro servos such as SG90 can create current spikes that disturb USB power.
- If the iPhone disconnects the board, the app loses the MIDI destination, or the servo twitches under load, move the servo to external 5 V power immediately.
- Keep common ground between the external 5 V supply and Teensy ground.
- Do not change the signal wire location when you switch to external servo power.

### Where To Later Swap To External Servo Power
Prototype wiring:
- servo signal -> Teensy PWM pin
- servo GND -> Teensy GND
- servo +5 V -> board/iPhone-supplied 5 V only for initial testing

Later stable wiring:
- servo signal -> same Teensy PWM pin
- servo GND -> external 5 V supply ground
- Teensy GND -> same external ground
- servo +5 V -> external regulated 5 V supply

That means the only real swap is the servo power source. Signal routing stays the same.

## What To Test First Before Connecting The Real Servo Load
1. Plug the Teensy into the iPhone and confirm it appears as a USB MIDI destination in the app.
2. Send manual `STOP`, `LEFT`, and `RIGHT` CC messages and verify the Teensy LED reacts even with no servo attached.
3. Connect the SG90 with the servo horn removed or with no mechanical load.
4. Verify one message equals one small step and that `STOP` holds position.
5. Only after that, connect the real pan linkage or camera load.
6. If the USB link resets or the servo chatters, move to external 5 V servo power and keep common ground.

## Minimal Code Skeletons
- Swift coordinator and CoreMIDI helper:
  - `swift/SoccerUSBMIDIPrototype.swift`
- Teensy firmware:
  - `teensy/teensy_usb_midi_servo.ino`

## Step-By-Step Implementation Checklist
1. Export or wrap YOLO26n so the iPhone app outputs normalized person detections on-device.
2. Add tap-to-select UI and store the selected target center.
3. On each frame, choose the person detection whose center is nearest to the previous target center.
4. Add the vertical center deadzone band and verify the visual overlay matches the control boundaries.
5. Add the 3-frame direction debounce.
6. Add MIDI rate limiting at about 150 ms.
7. Implement CoreMIDI destination discovery and connect to the Teensy USB MIDI endpoint.
8. Send `CC 21` plus `CC 20` for each motion update.
9. Flash the Teensy sketch with USB type set to `MIDI`.
10. Test command handling with LED only or with an unloaded servo.
11. Add the SG90 and verify `LEFT` and `RIGHT` map to bounded angle steps.
12. If power instability appears, move only the servo power rail to an external regulated 5 V source and keep common ground.
