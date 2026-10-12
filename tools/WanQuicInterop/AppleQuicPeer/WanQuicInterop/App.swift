import SwiftUI

@main
struct WanQuicInteropApp: App {
    private let session = InteropSession()
    @State private var host = ""
    @State private var port = "4433"
    @State private var generation = "1"
    @State private var alpn = TestProtocol.alpn
    @State private var ca: Data?
    @State private var importing = false
    @State private var evidence = EvidenceSnapshot()
    @State private var exportURL: URL?
    @State private var exportError: String?
    private let refresh = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    var body: some Scene {
        WindowGroup {
            Form {
                Text("Isolated synthetic QUIC interoperability test")
                TextField("Server SAN / endpoint", text: $host).textInputAutocapitalization(.never)
                TextField("Port", text: $port)
                TextField("Run generation (same as Windows)", text: $generation)
                TextField("ALPN (change only for negative test)", text: $alpn)
                Button("Import dedicated CA DER") { importing = true }
                Button("Connect") {
                    if let ca, let p = UInt16(port), let g = UInt64(generation), !host.isEmpty {
                        EventLog.beginRun(generation: g)
                        exportURL = nil
                        session.start(host: host, port: p, generation: g, ca: ca, alpn: alpn)
                    }
                }.disabled(ca == nil)
                Button("Retire connection") {
                    session.stop()
                    EventLog.write("run_retired", generation: evidence.generation, owner: UUID())
                }
                Section("Runtime evidence") {
                    Text("Current run: \(evidence.runID)")
                    Text("Generation: \(evidence.generation)")
                    Text("Connection: \(evidence.connectionState)")
                    Text("Last event: \(evidence.lastEvent)")
                    Text("Apple DATAGRAM cap: \(evidence.appleCapacity.map(String.init) ?? "Not measured")")
                    Text("Control replies: \(evidence.controlReplies)")
                    Text("Host DATAGRAMs: \(evidence.hostDatagrams)")
                    Text("Send errors: \(evidence.sendErrors)")
                    if evidence.truncated { Text("Evidence limit reached — log incomplete").foregroundStyle(.red) }
                    if let error = evidence.storageError { Text("Storage error: \(error)").foregroundStyle(.red) }
                    if let error = exportError { Text(error).foregroundStyle(.red) }
                    Button("Prepare evidence export") {
                        do { exportURL = try EventLog.export(); exportError = nil }
                        catch { exportError = error.localizedDescription }
                    }.disabled(evidence.fileURL == nil)
                    if let exportURL { ShareLink("Share JSONL evidence", item: exportURL) }
                    Button("Clear current evidence") { EventLog.clear(); exportURL = nil }
                }
                Text("JSONL is retained locally (4 MiB per run, last 8 runs). Export before clearing or starting another run. Synthetic test content only.")
            }.onReceive(refresh) { _ in evidence = EventLog.snapshot() }.fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
                if case .success(let url) = result {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    ca = try? Data(contentsOf: url)
                }
            }
        }
    }
}