import SwiftUI

@main
struct MinimalQuicReproApp: App {
    private let session = MinimalQuicSession()
    @State private var host = "192.168.1.10"
    @State private var port = "4433"
    @State private var generation = "1"
    @State private var alpn = MinimalControlProtocol.alpn
    @State private var ca: Data?
    @State private var importing = false
    @State private var snapshot = MinimalSnapshot()
    @State private var exportURL: URL?
    @State private var error = ""
    var body: some Scene {
        WindowGroup {
            Form {
                Section("Minimal QUIC Reproducer") {
                    TextField("Host", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port", text: $port)
                    TextField("Generation", text: $generation)
                    TextField("ALPN", text: $alpn).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Import dedicated CA DER") { importing = true }
                    Button("Connect once") {
                        guard let ca, let port = UInt16(port), let generation = UInt64(generation) else { return }
                        exportURL = nil
                        session.start(host: host, port: port, generation: generation, alpn: alpn, ca: ca)
                    }.disabled(ca == nil)
                    Button("Retire") { session.stop() }
                }
                Section("Evidence") {
                    Text("Run: \(snapshot.runID)")
                    Text("Group: \(snapshot.groupID)")
                    Text("Control: \(snapshot.controlID)")
                    Text("Group state: \(snapshot.groupState)")
                    Text("Control state: \(snapshot.controlState)")
                    Text("Last event: \(snapshot.lastEvent)")
                    Text("Control replies: \(snapshot.replies)")
                    Text("Capture complete: \(snapshot.complete.description)")
                    Text("Dropped diagnostics: \(snapshot.drops)")
                    Text("Truncated: \(snapshot.truncated.description)")
                    Text("Storage error: \(snapshot.storageError)")
                    if !error.isEmpty { Text(error).foregroundStyle(.red) }
                    Button("Prepare evidence export") {
                        session.export { result in
                            switch result {
                            case .success(let url): exportURL = url; error = ""
                            case .failure(let failure): error = failure.localizedDescription
                            }
                        }
                    }.disabled(snapshot.runID.isEmpty)
                    if let exportURL { ShareLink("Share JSONL", item: exportURL) }
                }
            }.onAppear { session.onSnapshot = { snapshot = $0 } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    ca = try Data(contentsOf: url)
                    error = ""
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}
