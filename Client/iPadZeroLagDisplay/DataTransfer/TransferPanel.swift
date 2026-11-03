import UIKit
import SwiftUI
import UniformTypeIdentifiers

struct TransferPanel: View {
    @ObservedObject var networkManager: NetworkManager
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "arrow.left.arrow.right").font(.title2).foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 5) {
                    Text("File Transfer").font(.headline).foregroundStyle(.white)
                    Text(networkManager.isConnected ? "Send to PC or open received files" : "Connect to your PC to send files")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.6))
            }.frame(minHeight: 60)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("File Transfer. Open Transfer Center")
        .sheet(isPresented: $presented) { TransferCenterSheet(networkManager: networkManager) }
    }
}
struct TransferExporter: UIViewControllerRepresentable {
    let url: URL
    let onRelease: () -> Void
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let lock = NSLock()
        private var released = false
        private let onRelease: () -> Void
        init(onRelease: @escaping () -> Void) { self.onRelease = onRelease }
        func finishOnce() {
            lock.lock(); let first = !released; released = true; lock.unlock()
            if first { onRelease() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finishOnce() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            // Export-mode delegate URLs denote new external copies; never inspect/delete them.
            finishOnce()
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(onRelease: onRelease) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: UIDocumentPickerViewController, coordinator: Coordinator) {
        coordinator.finishOnce()
    }
}
