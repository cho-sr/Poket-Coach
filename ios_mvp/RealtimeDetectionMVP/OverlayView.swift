import AVFoundation
import UIKit

final class OverlayView: UIView {
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    private var tracks: [TrackResult] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(tracks: [TrackResult]) {
        self.tracks = tracks
        DispatchQueue.main.async {
            self.setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        for track in tracks {
            let color = colorForTrack(id: track.trackID)
            let drawRect = convertedRect(from: track.detection.rect)

            context.setStrokeColor(color.cgColor)
            context.setLineWidth(2.0)
            context.stroke(drawRect)

            let label = track.isPredictionOnly
                ? "\(track.detection.className) #\(track.trackID) P"
                : "\(track.detection.className) #\(track.trackID) \(Int(track.detection.confidence * 100))%"

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: UIColor.white,
                .backgroundColor: color,
            ]

            let textRect = CGRect(
                x: drawRect.minX,
                y: max(0, drawRect.minY - 20),
                width: min(bounds.width - drawRect.minX, 220),
                height: 18
            )
            label.draw(in: textRect, withAttributes: attributes)
        }
    }

    private func convertedRect(from normalizedRect: CGRect) -> CGRect {
        if let previewLayer {
            return previewLayer.layerRectConverted(fromMetadataOutputRect: normalizedRect)
        }

        return CGRect(
            x: normalizedRect.minX * bounds.width,
            y: normalizedRect.minY * bounds.height,
            width: normalizedRect.width * bounds.width,
            height: normalizedRect.height * bounds.height
        )
    }

    private func colorForTrack(id: Int) -> UIColor {
        let palette: [UIColor] = [
            .systemGreen,
            .systemOrange,
            .systemPink,
            .systemBlue,
            .systemYellow,
            .systemTeal,
            .systemRed,
        ]
        return palette[id % palette.count]
    }
}
