import AVFoundation
import UIKit

protocol CameraServiceDelegate: AnyObject {
    func cameraService(_ service: CameraService, didOutput pixelBuffer: CVPixelBuffer, timestamp: CMTime)
}

final class CameraService: NSObject {
    let session = AVCaptureSession()
    let previewLayer = AVCaptureVideoPreviewLayer()

    weak var delegate: CameraServiceDelegate?

    private let sessionQueue = DispatchQueue(label: "app.camera.session")
    private let videoOutputQueue = DispatchQueue(label: "app.camera.output", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()

    override init() {
        super.init()
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
    }

    func configureSession() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .hd1280x720

            guard
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                let input = try? AVCaptureDeviceInput(device: device),
                self.session.canAddInput(input)
            else {
                self.session.commitConfiguration()
                return
            }

            self.session.addInput(input)

            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.videoOutputQueue)

            guard self.session.canAddOutput(self.videoOutput) else {
                self.session.commitConfiguration()
                return
            }

            self.session.addOutput(self.videoOutput)
            self.applyVideoOrientation(.portrait)

            self.session.commitConfiguration()
        }
    }

    func updateOrientation(_ orientation: UIInterfaceOrientation) {
        guard let videoOrientation = AVCaptureVideoOrientation(interfaceOrientation: orientation) else {
            return
        }

        sessionQueue.async {
            self.applyVideoOrientation(videoOrientation)
        }
    }

    func start() {
        sessionQueue.async {
            guard !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func applyVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        if let previewConnection = previewLayer.connection, previewConnection.isVideoOrientationSupported {
            previewConnection.videoOrientation = orientation
        }

        if let outputConnection = videoOutput.connection(with: .video), outputConnection.isVideoOrientationSupported {
            outputConnection.videoOrientation = orientation
        }
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        delegate?.cameraService(self, didOutput: pixelBuffer, timestamp: timestamp)
    }
}

private extension AVCaptureVideoOrientation {
    init?(interfaceOrientation: UIInterfaceOrientation) {
        switch interfaceOrientation {
        case .portrait:
            self = .portrait
        case .portraitUpsideDown:
            self = .portraitUpsideDown
        case .landscapeLeft:
            self = .landscapeRight
        case .landscapeRight:
            self = .landscapeLeft
        default:
            return nil
        }
    }
}
