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
                        session.start(host: host, port: p, generation: g, ca: ca, alpn: alpn)
                    }
                }.disabled(ca == nil)
                Button("Retire connection") { session.stop() }
                Text("Evidence is emitted as JSON lines to the Xcode console. No product media/input.")
            }.fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
                if case .success(let url) = result {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    ca = try? Data(contentsOf: url)
                }
            }
        }
    }
}