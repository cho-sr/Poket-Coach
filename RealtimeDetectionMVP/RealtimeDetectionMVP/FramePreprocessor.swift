import AVFoundation
import CoreImage
import Foundation

final class FramePreprocessor {
    private let inputWidth: Int
    private let inputHeight: Int
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    init(inputWidth: Int = 320, inputHeight: Int = 320) {
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
    }

    func prepare(pixelBuffer: CVPixelBuffer, timestamp: CMTime) -> FramePacket? {
        guard let resized = makeResizeBuffer(width: inputWidth, height: inputHeight) else {
            return nil
        }

        let sourceWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let sourceHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)

        let scaleX = CGFloat(inputWidth) / sourceWidth
        let scaleY = CGFloat(inputHeight) / sourceHeight
        let resizedImage = sourceImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        ciContext.render(
            resizedImage,
            to: resized,
            bounds: CGRect(x: 0, y: 0, width: inputWidth, height: inputHeight),
            colorSpace: colorSpace
        )

        CVPixelBufferLockBaseAddress(resized, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(resized, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(resized) else {
            return nil
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(resized)
        let raw = baseAddress.assumingMemoryBound(to: UInt8.self)
        let planeSize = inputWidth * inputHeight
        var tensorData = [Float](repeating: 0.0, count: planeSize * 3)

        for y in 0..<inputHeight {
            let row = raw.advanced(by: y * bytesPerRow)
            for x in 0..<inputWidth {
                let pixel = row.advanced(by: x * 4)

                let b = Float(pixel[0]) / 255.0
                let g = Float(pixel[1]) / 255.0
                let r = Float(pixel[2]) / 255.0

                let index = y * inputWidth + x

                // RGB / CHW
                tensorData[index] = r
                tensorData[planeSize + index] = g
                tensorData[(2 * planeSize) + index] = b
            }
        }

        return FramePacket(
            tensorData: tensorData,
            inputShape: [1, 3, inputHeight, inputWidth],
            originalImageSize: CGSize(width: sourceWidth, height: sourceHeight),
            timestampSeconds: timestamp.seconds
        )
    }

    private func makeResizeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        return pixelBuffer
    }
}
