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
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {UIDocumentPickerViewController(forExporting:[url],asCopy:true)}
    func updateUIViewController(_ controller: UIDocumentPickerViewController,context: Context) {}
}
