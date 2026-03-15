import CoreGraphics
import Foundation

struct Detection {
    let rect: CGRect
    let confidence: Float
    let classID: Int
    let className: String
}

struct TrackResult {
    let trackID: Int
    let detection: Detection
    let isPredictionOnly: Bool
}

struct FramePacket {
    let tensorData: [Float]
    let inputShape: [Int]
    let originalImageSize: CGSize
    let timestampSeconds: Double
}

extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    func clampedToUnit() -> CGRect {
        let x = min(max(origin.x, 0.0), 1.0)
        let y = min(max(origin.y, 0.0), 1.0)
        let maxWidth = 1.0 - x
        let maxHeight = 1.0 - y
        let width = min(max(size.width, 0.0), maxWidth)
        let height = min(max(size.height, 0.0), maxHeight)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
