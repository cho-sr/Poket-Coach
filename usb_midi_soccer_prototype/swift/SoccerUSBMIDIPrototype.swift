import CoreGraphics
import CoreMIDI
import Foundation

// Normalized person detection result from the iPhone detector.
struct PersonObservation {
    let rect: CGRect
    let confidence: Float

    var center: CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }
}

enum MotionDirection: UInt8 {
    case stop = 0
    case left = 1
    case right = 2
}

struct TrackingTuning {
    var deadzoneWidthRatio: CGFloat = 0.22
    var consecutiveFramesToCommit: Int = 3
    var sendInterval: TimeInterval = 0.15
    var stepStrength: UInt8 = 24
    var lostTargetStopFrames: Int = 6
    var midiChannel: UInt8 = 1
    var commandCC: UInt8 = 20
    var strengthCC: UInt8 = 21
}

struct ServoCommand {
    let direction: MotionDirection
    let strength: UInt8
}

struct MIDIDestinationDescriptor {
    let endpoint: MIDIEndpointRef
    let name: String
    let isOffline: Bool
}

struct FrameTrackingResult {
    let selectedTarget: PersonObservation?
    let deadzoneRange: ClosedRange<CGFloat>
    let commandSent: ServoCommand?
}

enum MIDIServoError: Error {
    case clientCreationFailed(OSStatus)
    case outputPortCreationFailed(OSStatus)
    case noDestinationConnected
    case packetListCreationFailed
    case sendFailed(OSStatus)
}

final class USBMIDIServoOutput {
    private let tuning: TrackingTuning
    private var client = MIDIClientRef()
    private var outputPort = MIDIPortRef()
    private var destination: MIDIEndpointRef?

    init(tuning: TrackingTuning = TrackingTuning()) throws {
        self.tuning = tuning

        let clientStatus = MIDIClientCreateWithBlock("SoccerUSBMIDIServoClient" as CFString, &client) { _ in
            // Keep notification handling simple for the prototype.
        }
        guard clientStatus == noErr else {
            throw MIDIServoError.clientCreationFailed(clientStatus)
        }

        let portStatus = MIDIOutputPortCreate(client, "SoccerUSBMIDIServoOutput" as CFString, &outputPort)
        guard portStatus == noErr else {
            throw MIDIServoError.outputPortCreationFailed(portStatus)
        }
    }

    deinit {
        if outputPort != 0 {
            MIDIPortDispose(outputPort)
        }
        if client != 0 {
            MIDIClientDispose(client)
        }
    }

    func availableDestinations() -> [MIDIDestinationDescriptor] {
        let count = MIDIGetNumberOfDestinations()
        guard count > 0 else { return [] }

        return (0..<count).compactMap { index in
            let endpoint = MIDIGetDestination(index)
            guard endpoint != 0 else { return nil }

            let name = Self.stringProperty(object: endpoint, property: kMIDIPropertyDisplayName) ?? "Unknown MIDI Device"
            let offline = (Self.intProperty(object: endpoint, property: kMIDIPropertyOffline) ?? 0) != 0
            return MIDIDestinationDescriptor(endpoint: endpoint, name: name, isOffline: offline)
        }
    }

    @discardableResult
    func connect(toFirstMatching nameFragment: String? = nil) -> MIDIDestinationDescriptor? {
        let destinations = availableDestinations().filter { !$0.isOffline }
        let descriptor: MIDIDestinationDescriptor?

        if let nameFragment, !nameFragment.isEmpty {
            descriptor = destinations.first { $0.name.localizedCaseInsensitiveContains(nameFragment) }
        } else {
            descriptor = destinations.first
        }

        destination = descriptor?.endpoint
        return descriptor
    }

    func send(direction: MotionDirection, strength: UInt8) throws {
        if direction == .stop {
            try sendControlChange(cc: tuning.commandCC, value: MotionDirection.stop.rawValue)
            return
        }

        try sendControlChange(cc: tuning.strengthCC, value: strength)
        try sendControlChange(cc: tuning.commandCC, value: direction.rawValue)
    }

    func sendStop() throws {
        try send(direction: .stop, strength: 0)
    }

    func sendControlChange(cc: UInt8, value: UInt8) throws {
        guard let destination else {
            throw MIDIServoError.noDestinationConnected
        }

        let statusByte = UInt8(0xB0 | ((tuning.midiChannel - 1) & 0x0F))
        let bytes = [statusByte, cc, value]

        var packetBuffer = [UInt8](repeating: 0, count: 256)
        let sendStatus: OSStatus = packetBuffer.withUnsafeMutableBytes { rawBuffer in
            guard let packetListPointer = rawBuffer.baseAddress?.assumingMemoryBound(to: MIDIPacketList.self) else {
                return MIDIServoError.packetListCreationFailed.osStatus
            }

            var packet = MIDIPacketListInit(packetListPointer)

            let addStatus = bytes.withUnsafeBufferPointer { buffer -> OSStatus in
                guard let bytePointer = buffer.baseAddress else {
                    return MIDIServoError.packetListCreationFailed.osStatus
                }
                let nextPacket = MIDIPacketListAdd(
                    packetListPointer,
                    rawBuffer.count,
                    packet,
                    0,
                    bytes.count,
                    bytePointer
                )
                packet = nextPacket
                return noErr
            }

            guard addStatus == noErr else {
                return addStatus
            }

            return MIDISend(outputPort, destination, packetListPointer)
        }

        guard sendStatus == noErr else {
            throw MIDIServoError.sendFailed(sendStatus)
        }
    }

    private static func stringProperty(object: MIDIObjectRef, property: CFString) -> String? {
        var unmanagedString: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(object, property, &unmanagedString)
        guard status == noErr, let unmanagedString else { return nil }
        return unmanagedString.takeRetainedValue() as String
    }

    private static func intProperty(object: MIDIObjectRef, property: CFString) -> Int32? {
        var value: Int32 = 0
        let status = MIDIObjectGetIntegerProperty(object, property, &value)
        guard status == noErr else { return nil }
        return value
    }
}

private extension MIDIServoError {
    var osStatus: OSStatus {
        switch self {
        case .clientCreationFailed(let status):
            return status
        case .outputPortCreationFailed(let status):
            return status
        case .sendFailed(let status):
            return status
        case .noDestinationConnected:
            return kMIDIUnknownEndpoint
        case .packetListCreationFailed:
            return -1
        }
    }
}

final class TargetSelectionController {
    private(set) var lastKnownTargetCenter: CGPoint?

    var hasSelection: Bool {
        lastKnownTargetCenter != nil
    }

    func clearSelection() {
        lastKnownTargetCenter = nil
    }

    @discardableResult
    func selectTarget(at normalizedPoint: CGPoint, in persons: [PersonObservation]) -> PersonObservation? {
        guard !persons.isEmpty else {
            clearSelection()
            return nil
        }

        let containing = persons.filter { $0.rect.contains(normalizedPoint) }
        let candidates = containing.isEmpty ? persons : containing

        let selected = candidates.min {
            distanceSquared(from: $0.center, to: normalizedPoint) < distanceSquared(from: $1.center, to: normalizedPoint)
        }

        lastKnownTargetCenter = selected?.center
        return selected
    }

    func resolveTrackedTarget(in persons: [PersonObservation]) -> PersonObservation? {
        guard let previousCenter = lastKnownTargetCenter, !persons.isEmpty else {
            return nil
        }

        let bestMatch = persons.min {
            distanceSquared(from: $0.center, to: previousCenter) < distanceSquared(from: $1.center, to: previousCenter)
        }

        if let bestMatch {
            lastKnownTargetCenter = bestMatch.center
        }
        return bestMatch
    }

    private func distanceSquared(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }
}

final class DeadzoneCommandController {
    private let tuning: TrackingTuning

    private var committedDirection: MotionDirection = .stop
    private var candidateDirection: MotionDirection = .stop
    private var candidateFrameCount: Int = 0
    private var lastSendTime: TimeInterval = 0
    private var lostTargetFrames: Int = 0

    init(tuning: TrackingTuning = TrackingTuning()) {
        self.tuning = tuning
    }

    func deadzoneRange() -> ClosedRange<CGFloat> {
        let halfWidth = tuning.deadzoneWidthRatio / 2.0
        return (0.5 - halfWidth)...(0.5 + halfWidth)
    }

    func forceStop(now: TimeInterval = CFAbsoluteTimeGetCurrent()) -> ServoCommand? {
        candidateDirection = .stop
        candidateFrameCount = 0
        lostTargetFrames = 0

        guard committedDirection != .stop else {
            return nil
        }

        committedDirection = .stop
        lastSendTime = now
        return ServoCommand(direction: .stop, strength: 0)
    }

    func update(target: PersonObservation?, now: TimeInterval = CFAbsoluteTimeGetCurrent()) -> ServoCommand? {
        guard let target else {
            lostTargetFrames += 1
            guard lostTargetFrames >= tuning.lostTargetStopFrames else {
                return nil
            }
            return forceStop(now: now)
        }

        lostTargetFrames = 0

        let desiredDirection = direction(forTargetCenterX: target.center.x)

        if desiredDirection == .stop {
            return forceStop(now: now)
        }

        if desiredDirection != committedDirection {
            if candidateDirection == desiredDirection {
                candidateFrameCount += 1
            } else {
                candidateDirection = desiredDirection
                candidateFrameCount = 1
            }

            guard candidateFrameCount >= tuning.consecutiveFramesToCommit else {
                return nil
            }

            guard shouldSend(now: now) else {
                committedDirection = desiredDirection
                return nil
            }

            committedDirection = desiredDirection
            lastSendTime = now
            candidateFrameCount = 0
            return ServoCommand(direction: desiredDirection, strength: tuning.stepStrength)
        }

        guard shouldSend(now: now) else {
            return nil
        }

        lastSendTime = now
        return ServoCommand(direction: committedDirection, strength: tuning.stepStrength)
    }

    private func direction(forTargetCenterX x: CGFloat) -> MotionDirection {
        let range = deadzoneRange()
        if x < range.lowerBound {
            return .left
        }
        if x > range.upperBound {
            return .right
        }
        return .stop
    }

    private func shouldSend(now: TimeInterval) -> Bool {
        now - lastSendTime >= tuning.sendInterval
    }
}

final class SoccerTrackingCoordinator {
    let tuning: TrackingTuning
    let targetSelection: TargetSelectionController
    let deadzoneController: DeadzoneCommandController

    init(tuning: TrackingTuning = TrackingTuning()) {
        self.tuning = tuning
        self.targetSelection = TargetSelectionController()
        self.deadzoneController = DeadzoneCommandController(tuning: tuning)
    }

    @discardableResult
    func handleUserTap(normalizedPoint: CGPoint, persons: [PersonObservation]) -> PersonObservation? {
        targetSelection.selectTarget(at: normalizedPoint, in: persons)
    }

    func clearSelection() -> ServoCommand? {
        targetSelection.clearSelection()
        return deadzoneController.forceStop()
    }

    @discardableResult
    func processFrame(
        persons: [PersonObservation],
        midi: USBMIDIServoOutput,
        now: TimeInterval = CFAbsoluteTimeGetCurrent()
    ) throws -> FrameTrackingResult {
        let selectedTarget = targetSelection.resolveTrackedTarget(in: persons)
        let command = deadzoneController.update(target: selectedTarget, now: now)

        if let command {
            try midi.send(direction: command.direction, strength: command.strength)
        }

        return FrameTrackingResult(
            selectedTarget: selectedTarget,
            deadzoneRange: deadzoneController.deadzoneRange(),
            commandSent: command
        )
    }
}

/*
 Integration sketch for the existing iPhone app:

 1. Convert detector output into normalized person observations.
    let persons = detections
        .filter { $0.className == "person" }
        .map { PersonObservation(rect: $0.rect, confidence: $0.confidence) }

 2. On tap, convert the tap to normalized preview coordinates and lock the target.
    coordinator.handleUserTap(normalizedPoint: normalizedTap, persons: persons)

 3. During startup, discover the Teensy USB MIDI destination.
    let midi = try USBMIDIServoOutput()
    let destination = midi.connect(toFirstMatching: "Teensy")

 4. On each frame after detection:
    let result = try coordinator.processFrame(persons: persons, midi: midi)

 5. Use result.selectedTarget and result.deadzoneRange to draw the overlay.

 This keeps camera, YOLO26n inference, target selection, and USB MIDI transport as separate pieces.
 */
