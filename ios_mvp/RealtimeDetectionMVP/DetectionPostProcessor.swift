import CoreGraphics
import Foundation

final class DetectionPostProcessor {
    private let confidenceThreshold: Float
    private let nmsIoUThreshold: CGFloat
    private let classNames: [String]

    init(
        confidenceThreshold: Float = 0.35,
        nmsIoUThreshold: CGFloat = 0.45,
        classNames: [String] = ["person", "ball"]
    ) {
        self.confidenceThreshold = confidenceThreshold
        self.nmsIoUThreshold = nmsIoUThreshold
        self.classNames = classNames
    }

    func parse(rawOutput: [Float]) -> [Detection] {
        guard rawOutput.count >= 6 else { return [] }

        // MVP assumption:
        // flat output = [x1, y1, x2, y2, score, classId, ...]
        // coordinates are already normalized to 0...1
        var detections: [Detection] = []

        for start in stride(from: 0, to: rawOutput.count, by: 6) {
            guard start + 5 < rawOutput.count else { break }

            let score = rawOutput[start + 4]
            if score < confidenceThreshold { continue }

            let classID = Int(rawOutput[start + 5])
            let x1 = CGFloat(rawOutput[start].clamped(to: 0.0...1.0))
            let y1 = CGFloat(rawOutput[start + 1].clamped(to: 0.0...1.0))
            let x2 = CGFloat(rawOutput[start + 2].clamped(to: 0.0...1.0))
            let y2 = CGFloat(rawOutput[start + 3].clamped(to: 0.0...1.0))

            let rect = CGRect(
                x: min(x1, x2),
                y: min(y1, y2),
                width: abs(x2 - x1),
                height: abs(y2 - y1)
            ).clampedToUnit()

            guard rect.width > 0.001, rect.height > 0.001 else { continue }

            let className = classID >= 0 && classID < classNames.count
                ? classNames[classID]
                : "cls_\(classID)"

            detections.append(
                Detection(
                    rect: rect,
                    confidence: score,
                    classID: classID,
                    className: className
                )
            )
        }

        return applyNMS(to: detections)
    }

    private func applyNMS(to detections: [Detection]) -> [Detection] {
        let sorted = detections.sorted { $0.confidence > $1.confidence }
        var kept: [Detection] = []

        for candidate in sorted {
            let shouldSuppress = kept.contains { keptDetection in
                keptDetection.classID == candidate.classID &&
                iou(lhs: keptDetection.rect, rhs: candidate.rect) > nmsIoUThreshold
            }

            if !shouldSuppress {
                kept.append(candidate)
            }
        }

        return kept
    }

    private func iou(lhs: CGRect, rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        if intersection.isNull || intersection.isEmpty { return 0.0 }

        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        guard unionArea > 0 else { return 0.0 }
        return intersectionArea / unionArea
    }
}
