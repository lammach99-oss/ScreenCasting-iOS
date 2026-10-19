import UIKit
import SwiftUI
import UniformTypeIdentifiers

struct TransferPanel: View {
    @ObservedObject var networkManager: NetworkManager
    @State private var importing=false
    @State private var exporting=false
    @State private var exportURL: URL?
    var body: some View {
        let state=networkManager.transferSnapshot
        VStack(alignment:.leading,spacing:12) {
            Text("Data Transfer").font(.headline)
            Button("Send Files") {importing=true}
            Text(state.phase.rawValue)
            if state.count>0 {
                Text("\(state.index+1) / \(state.count) files · \(state.total.formatted()) bytes")
                Text(state.name).lineLimit(1)
                ProgressView(value:Double(state.bytes),total:Double(max(1,state.total)))
            }
            if state.phase == .awaitingDecision {
                HStack {Button("Accept"){networkManager.decideTransfer(true)};Button("Reject"){networkManager.decideTransfer(false)}}
            }
            if [.offering,.sending,.receiving,.verifying,.awaitingAck,.awaitingDecision].contains(state.phase) {
                Button("Cancel",role:.destructive){networkManager.cancelTransfer()}
            }
            ForEach(state.received,id:\.self) {url in
                HStack {Text(url.lastPathComponent).lineLimit(1);Button("Save to Files"){exportURL=url;exporting=true}}
            }
        }
        .fileImporter(isPresented:$importing,allowedContentTypes:[.data,.content],allowsMultipleSelection:true) {result in
            if case .success(let urls)=result {networkManager.sendTransferFiles(urls)}
        }
        .sheet(isPresented:$exporting) {if let exportURL {TransferExporter(url:exportURL)}}
    }
}
struct TransferExporter: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {UIDocumentPickerViewController(forExporting:[url],asCopy:true)}
    func updateUIViewController(_ controller: UIDocumentPickerViewController,context: Context) {}
}
