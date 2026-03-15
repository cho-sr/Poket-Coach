import SwiftUI

@main
struct RealtimeDetectionMVPApp: App {
    var body: some Scene {
        WindowGroup {
            DetectionViewControllerRepresentable()
                .ignoresSafeArea()
        }
    }
}
