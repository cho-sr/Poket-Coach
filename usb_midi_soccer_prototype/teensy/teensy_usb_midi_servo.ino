#include <Arduino.h>
#include <Servo.h>

namespace {
constexpr int kServoPin = 9;
constexpr int kStatusLedPin = LED_BUILTIN;

constexpr int kStartAngle = 90;
constexpr int kMinAngle = 40;
constexpr int kMaxAngle = 140;

constexpr uint8_t kMidiChannel = 1;
constexpr uint8_t kCommandCC = 20;
constexpr uint8_t kStrengthCC = 21;

constexpr uint8_t kStopValue = 0;
constexpr uint8_t kLeftValue = 1;
constexpr uint8_t kRightValue = 2;

constexpr uint32_t kCommandTimeoutMs = 700;
constexpr int kMinStepDegrees = 1;
constexpr int kMaxStepDegrees = 6;

constexpr int kServoMinPulseUs = 544;
constexpr int kServoMaxPulseUs = 2400;
}  // namespace

Servo panServo;

int currentAngle = kStartAngle;
uint8_t latestStrength = 24;
uint32_t lastValidCommandMs = 0;

void writeServoAngle() {
  currentAngle = constrain(currentAngle, kMinAngle, kMaxAngle);
  panServo.write(currentAngle);
}

int strengthToStepDegrees(uint8_t strength) {
  return map(strength, 0, 127, kMinStepDegrees, kMaxStepDegrees);
}

void setStatusLed(bool enabled) {
  digitalWrite(kStatusLedPin, enabled ? HIGH : LOW);
}

void handleDirectionCommand(uint8_t directionValue) {
  lastValidCommandMs = millis();

  switch (directionValue) {
    case kLeftValue:
      currentAngle -= strengthToStepDegrees(latestStrength);
      writeServoAngle();
      setStatusLed(true);
      break;

    case kRightValue:
      currentAngle += strengthToStepDegrees(latestStrength);
      writeServoAngle();
      setStatusLed(true);
      break;

    case kStopValue:
    default:
      // STOP means hold the current angle. We do not sweep or continuously drive.
      setStatusLed(false);
      break;
  }
}

void handleControlChange(byte channel, byte control, byte value) {
  if (channel != kMidiChannel) {
    return;
  }

  if (control == kStrengthCC) {
    latestStrength = value;
    return;
  }

  if (control == kCommandCC) {
    handleDirectionCommand(value);
  }
}

void setup() {
  pinMode(kStatusLedPin, OUTPUT);
  setStatusLed(false);

  // For Teensy 4.1, set Tools -> USB Type -> MIDI before uploading.
  panServo.attach(kServoPin, kServoMinPulseUs, kServoMaxPulseUs);
  writeServoAngle();
  lastValidCommandMs = millis();
}

void loop() {
  while (usbMIDI.read()) {
    if (usbMIDI.getType() == usbMIDI.ControlChange) {
      handleControlChange(
        usbMIDI.getChannel(),
        usbMIDI.getData1(),
        usbMIDI.getData2()
      );
    }
  }

  // Safety timeout: if the iPhone stops sending valid commands, just hold position.
  if (millis() - lastValidCommandMs > kCommandTimeoutMs) {
    setStatusLed(false);
  }
}

/*
 Wiring for prototype testing only:
 - servo signal -> Teensy pin 9
 - servo GND -> Teensy GND
 - servo +5V -> board/iPhone power only for very light testing

 Recommended stable wiring later:
 - servo signal -> same Teensy pin 9
 - servo GND -> external 5V supply ground
 - Teensy GND -> same external ground
 - servo +5V -> external regulated 5V supply

 This sketch moves only when a LEFT or RIGHT MIDI CC command arrives.
 That keeps the motion discrete and avoids continuous rotation behavior.
 */
