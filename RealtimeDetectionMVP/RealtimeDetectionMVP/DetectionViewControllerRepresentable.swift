import SwiftUI

struct DetectionViewControllerRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> DetectionViewController {
        DetectionViewController()
    }

    func updateUIViewController(_ uiViewController: DetectionViewController, context: Context) {}
}
