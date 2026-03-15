import AVFoundation
import UIKit

final class DetectionViewController: UIViewController {
    private let cameraService = CameraService()
    private let preprocessor = FramePreprocessor(inputWidth: 320, inputHeight: 320)
    private let postProcessor = DetectionPostProcessor(classNames: ["person", "ball"])
    private let tracker = SimpleTracker()
    private let overlayView = OverlayView()
    private let inferenceQueue = DispatchQueue(label: "app.detector.inference", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "app.detector.state")

    private var detector: ExecuTorchRunner?
    private var frameIndex: Int = 0
    private var detectionInterval: Int = 3
    private var inferenceBusy: Bool = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        cameraService.delegate = self
        cameraService.configureSession()

        cameraService.previewLayer.frame = view.bounds
        view.layer.addSublayer(cameraService.previewLayer)

        overlayView.frame = view.bounds
        overlayView.previewLayer = cameraService.previewLayer
        view.addSubview(overlayView)

        do {
            detector = try ExecuTorchRunner(modelName: "detector")
        } catch {
            print("Failed to load ExecuTorch model: \(error)")
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        cameraService.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cameraService.stop()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        cameraService.previewLayer.frame = view.bounds
        overlayView.frame = view.bounds
    }

    private func render(_ tracks: [TrackResult]) {
        DispatchQueue.main.async {
            self.overlayView.update(tracks: tracks)
        }
    }
}

extension DetectionViewController: CameraServiceDelegate {
    func cameraService(_ service: CameraService, didOutput pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        stateQueue.async { [weak self] in
            self?.handleFrame(pixelBuffer: pixelBuffer, timestamp: timestamp)
        }
    }

    private func handleFrame(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        frameIndex += 1

        let shouldRunDetection = frameIndex % detectionInterval == 0

        // If this is not a detection frame, or the previous inference is still running,
        // keep IDs alive by advancing the tracker only.
        guard shouldRunDetection, !inferenceBusy, let detector else {
            let predictedTracks = tracker.predictOnly()
            render(predictedTracks)
            return
        }

        inferenceBusy = true

        // CVPixelBuffer is a Core Foundation object, so closure capture retains it.
        inferenceQueue.async { [weak self] in
            guard let self else { return }

            guard let framePacket = self.preprocessor.prepare(pixelBuffer: pixelBuffer, timestamp: timestamp) else {
                self.stateQueue.async {
                    self.inferenceBusy = false
                }
                return
            }

            do {
                let rawOutput = try detector.predict(
                    input: framePacket.tensorData,
                    shape: framePacket.inputShape
                )
                let detections = self.postProcessor.parse(rawOutput: rawOutput)

                self.stateQueue.async {
                    let tracks = self.tracker.update(detections: detections)
                    self.inferenceBusy = false
                    self.render(tracks)
                }
            } catch {
                self.stateQueue.async {
                    self.inferenceBusy = false
                    print("ExecuTorch inference failed: \(error)")
                }
            }
        }
    }
}
