import CoreGraphics
import Foundation

final class DetectionPostProcessor {
    private let confidenceThreshold: Float
    private let nmsIoUThreshold: CGFloat
    private let classNames: [String]
    private let rawModelClassCount: Int?
    private let sourceClassMap: [Int: Int]

    init(
        confidenceThreshold: Float = 0.35,
        nmsIoUThreshold: CGFloat = 0.45,
        classNames: [String] = ["person", "ball"],
        rawModelClassCount: Int? = nil,
        sourceClassMap: [Int: Int] = [:]
    ) {
        self.confidenceThreshold = confidenceThreshold
        self.nmsIoUThreshold = nmsIoUThreshold
        self.classNames = classNames
        self.rawModelClassCount = rawModelClassCount
        self.sourceClassMap = sourceClassMap
    }

    func parse(rawOutput: [Float], inputWidth: CGFloat = 1.0, inputHeight: CGFloat = 1.0) -> [Detection] {
        guard rawOutput.count >= 6 else { return [] }
        let safeInputWidth = max(inputWidth, 1.0)
        let safeInputHeight = max(inputHeight, 1.0)

        if let rawModelClassCount {
            let channelCount = 4 + rawModelClassCount
            if rawOutput.count % channelCount == 0 && rawOutput.count >= channelCount {
                return parseUltralyticsRawOutput(
                    rawOutput: rawOutput,
                    inputWidth: safeInputWidth,
                    inputHeight: safeInputHeight,
                    rawModelClassCount: rawModelClassCount
                )
            }
        }

        // MVP assumption:
        // flat output = [x1, y1, x2, y2, score, classId, ...]
        // coordinates are either normalized to 0...1 or absolute model-input pixels
        var detections: [Detection] = []

        for start in stride(from: 0, to: rawOutput.count, by: 6) {
            guard start + 5 < rawOutput.count else { break }

            let score = rawOutput[start + 4]
            if score < confidenceThreshold { continue }

            let classID = Int(rawOutput[start + 5])
            let rawX1 = CGFloat(rawOutput[start])
            let rawY1 = CGFloat(rawOutput[start + 1])
            let rawX2 = CGFloat(rawOutput[start + 2])
            let rawY2 = CGFloat(rawOutput[start + 3])
            let usesAbsoluteInputPixels = max(rawX1, rawY1, rawX2, rawY2) > 1.0

            let x1 = (usesAbsoluteInputPixels ? (rawX1 / safeInputWidth) : rawX1).clamped(to: 0.0...1.0)
            let y1 = (usesAbsoluteInputPixels ? (rawY1 / safeInputHeight) : rawY1).clamped(to: 0.0...1.0)
            let x2 = (usesAbsoluteInputPixels ? (rawX2 / safeInputWidth) : rawX2).clamped(to: 0.0...1.0)
            let y2 = (usesAbsoluteInputPixels ? (rawY2 / safeInputHeight) : rawY2).clamped(to: 0.0...1.0)

            let rect = CGRect(
                x: min(x1, x2),
                y: min(y1, y2),
                width: abs(x2 - x1),
                height: abs(y2 - y1)
            ).clampedToUnit()

            guard rect.width > 0.001, rect.height > 0.001 else { continue }

            let className: String
            if classID >= 0 && classID < classNames.count {
                className = classNames[classID]
            } else if classNames.count == 2 && classNames[0] == "person" && classNames[1] == "ball" && classID == 32 {
                // COCO-trained YOLO11 uses class 32 for "sports ball".
                className = classNames[1]
            } else {
                className = "cls_\(classID)"
            }

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

    private func parseUltralyticsRawOutput(
        rawOutput: [Float],
        inputWidth: CGFloat,
        inputHeight: CGFloat,
        rawModelClassCount: Int
    ) -> [Detection] {
        let channelCount = 4 + rawModelClassCount
        let anchorCount = rawOutput.count / channelCount
        let classMap = resolvedSourceClassMap(rawModelClassCount: rawModelClassCount)
        var detections: [Detection] = []

        guard anchorCount > 0, !classMap.isEmpty else { return [] }

        for anchorIndex in 0..<anchorCount {
            var bestScore: Float = 0.0
            var bestLocalClassID: Int?

            for (sourceClassID, localClassID) in classMap {
                let scoreIndex = (4 + sourceClassID) * anchorCount + anchorIndex
                guard scoreIndex < rawOutput.count else { continue }

                let score = rawOutput[scoreIndex]
                if score > bestScore {
                    bestScore = score
                    bestLocalClassID = localClassID
                }
            }

            guard let localClassID = bestLocalClassID, bestScore >= confidenceThreshold else {
                continue
            }

            let centerX = CGFloat(rawOutput[anchorIndex])
            let centerY = CGFloat(rawOutput[anchorCount + anchorIndex])
            let width = CGFloat(rawOutput[(2 * anchorCount) + anchorIndex])
            let height = CGFloat(rawOutput[(3 * anchorCount) + anchorIndex])

            let x1 = ((centerX - (width * 0.5)) / inputWidth).clamped(to: 0.0...1.0)
            let y1 = ((centerY - (height * 0.5)) / inputHeight).clamped(to: 0.0...1.0)
            let x2 = ((centerX + (width * 0.5)) / inputWidth).clamped(to: 0.0...1.0)
            let y2 = ((centerY + (height * 0.5)) / inputHeight).clamped(to: 0.0...1.0)

            let rect = CGRect(
                x: min(x1, x2),
                y: min(y1, y2),
                width: abs(x2 - x1),
                height: abs(y2 - y1)
            ).clampedToUnit()

            guard rect.width > 0.001, rect.height > 0.001 else { continue }
            guard localClassID >= 0 && localClassID < classNames.count else { continue }

            detections.append(
                Detection(
                    rect: rect,
                    confidence: bestScore,
                    classID: localClassID,
                    className: classNames[localClassID]
                )
            )
        }

        return applyNMS(to: detections)
    }

    private func resolvedSourceClassMap(rawModelClassCount: Int) -> [Int: Int] {
        if !sourceClassMap.isEmpty {
            return sourceClassMap
        }

        guard rawModelClassCount == classNames.count else { return [:] }
        return Dictionary(uniqueKeysWithValues: classNames.indices.map { ($0, $0) })
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
