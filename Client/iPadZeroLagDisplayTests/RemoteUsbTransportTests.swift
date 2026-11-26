import XCTest
@testable import iPadCasting

#if targetEnvironment(simulator)
import CryptoKit
import Network
import Security

private enum GateError: Error { case timeout, closed, unexpected }

// Single producer. Consumers poll on the main actor or wait on a dedicated I/O worker.
private final class GateResult<Value> {
    private let lock = NSLock()
    private var stored: Value?
    func set(_ value: Value) { lock.lock(); defer { lock.unlock() }; stored = value }
    var value: Value? { lock.lock(); defer { lock.unlock() }; return stored }
}

final class RemoteUsbTransportTests: XCTestCase {
    @MainActor private func wait<Value>(_ box: GateResult<Value>) async throws -> Value {
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            if let value = box.value { return value }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw GateError.timeout
    }

    @MainActor func testFragmentedClientHelloAndCancelPendingHandshake() async throws {
        let reading = GateResult<Bool>()
        let result = GateResult<Bool>()
        let stopped = DispatchSemaphore(value: 0)
        var hello = Data()
        let io = RemoteUsbDuplex(read: { _ in
            reading.set(true)
            guard stopped.wait(timeout: .now() + 5) == .success else { throw GateError.timeout }
            throw GateError.closed
        }, write: { bytes in
            let count = min(3, bytes.count)
            hello.append(contentsOf: bytes.prefix(count))
            return count
        }, cancel: { stopped.signal() })
        let client = try RemoteUsbTransport(stream: io)
        DispatchQueue.global().async {
            do { try client.handshake(pin: nil) { _, _ in false }; result.set(false) }
            catch { result.set(true) }
        }
        _ = try await wait(reading)
        let cancellation = ContinuousClock.now
        client.cancel()
        let refused = try await wait(result)
        XCTAssertLessThan(cancellation.duration(to: .now), .seconds(2))
        XCTAssertTrue(refused)
        XCTAssertEqual(hello.first, 0x16) // TLS handshake record
        XCTAssertGreaterThan(hello.count, 5)
        XCTAssertEqual(hello.dropFirst(5).first, 1) // ClientHello
        XCTAssertThrowsError(try client.send(Data([1])))
    }
}
#endif
#if targetEnvironment(simulator)
extension RemoteUsbTransportTests {
    private enum TrustCase { case saved, changed, confirm, decline }

    @MainActor func testAcceptedClientExchangesPinnedPingPong() async throws { try await loopback(.saved) }
    @MainActor func testChangedPinClosesBeforeApplicationData() async throws { try await loopback(.changed) }
    @MainActor func testFirstUseConfirmationAllowsPingPong() async throws { try await loopback(.confirm) }
    @MainActor func testFirstUseDeclineClosesBeforeApplicationData() async throws { try await loopback(.decline) }

    private static func frame(_ type: WireMessageType) -> Data {
        Data([0x53, 0x43, 0x53, 0x54, 1, type.rawValue, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 42])
    }

    // This binding is test-only. NW callbacks run separately from both TLS workers.
    private static func duplex(_ connection: NWConnection) -> RemoteUsbDuplex {
        RemoteUsbDuplex(read: { maximum in
            let result = GateResult<Data>()
            let done = DispatchSemaphore(value: 0)
            connection.receive(minimumIncompleteLength: 1, maximumLength: min(97, maximum)) { data, _, _, _ in
                result.set(data ?? Data())
                done.signal()
            }
            guard done.wait(timeout: .now() + 4) == .success else { throw GateError.timeout }
            guard let part = result.value, !part.isEmpty else { throw GateError.closed }
            return part
        }, write: { bytes in
            let prefix = Data(bytes.prefix(113))
            let done = DispatchSemaphore(value: 0)
            let result = GateResult<Bool>()
            connection.send(content: prefix, completion: .contentProcessed { error in
                result.set(error == nil)
                done.signal()
            })
            guard done.wait(timeout: .now() + 4) == .success else { throw GateError.timeout }
            guard result.value == true else { throw GateError.closed }
            return prefix.count
        }, cancel: { connection.cancel() })
    }

    // Dialing peer deliberately chooses the TLS server role. Report decrypted bytes
    // even if an unexpected handshake succeeds in a refusal test.
    private static func serve(_ io: RemoteUsbDuplex, identity: SecIdentity) throws -> Data {
        defer { io.cancel() }
        let tls = try XCTUnwrap(SSLCreateContext(nil, .serverSide, .streamType))
        try io.attach(to: tls)
        guard SSLSetCertificate(tls, [identity] as CFArray) == errSecSuccess,
              SSLSetProtocolVersionMin(tls, .tlsProtocol12) == errSecSuccess else { throw GateError.unexpected }
        guard SSLHandshake(tls) == errSecSuccess else { return Data() }
        let ping = frame(.ping)
        var received = Data()
        while received.count < ping.count {
            var buffer = [UInt8](repeating: 0, count: ping.count - received.count)
            var count = 0
            let status = buffer.withUnsafeMutableBytes { SSLRead(tls, $0.baseAddress!, $0.count, &count) }
            received.append(contentsOf: buffer.prefix(count))
            guard status == errSecSuccess, count > 0 else { return received }
        }
        let pong = frame(.pong)
        var sent = 0
        let status = pong.withUnsafeBytes { SSLWrite(tls, $0.baseAddress, $0.count, &sent) }
        guard status == errSecSuccess, sent == pong.count else { throw GateError.unexpected }
        return received
    }

    @MainActor private func loopback(_ trustCase: TrustCase) async throws {
        let identity = try Self.fixtureIdentity()
        var leaf: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(identity, &leaf), errSecSuccess)
        let der = SecCertificateCopyData(try XCTUnwrap(leaf)) as Data
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        let pin: String?
        switch trustCase {
        case .saved: pin = fingerprint
        case .changed: pin = Array(repeating: "00", count: 32).joined(separator: ":")
        case .confirm, .decline: pin = nil
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        defer { listener.cancel() }
        let queue = DispatchQueue(label: "remote-usb-test-io")
        let accepted = GateResult<NWConnection>()
        let port = GateResult<NWEndpoint.Port>()
        listener.stateUpdateHandler = { [weak listener] state in
            if case .ready = state, let bound = listener?.port { port.set(bound) }
        }
        listener.newConnectionHandler = { connection in connection.start(queue: queue); accepted.set(connection) }
        listener.start(queue: queue)
        let bound = try await wait(port)
        let dial = NWConnection(host: .ipv4(.loopback), port: bound, using: .tcp)
        defer { dial.cancel() }
        dial.start(queue: queue)
        let incoming = try await wait(accepted)
        defer { incoming.cancel() }
        let client = try RemoteUsbTransport(stream: Self.duplex(incoming))
        defer { client.cancel() }
        let server = GateResult<Result<Data, Error>>()
        DispatchQueue.global().async {
            server.set(Result { try Self.serve(Self.duplex(dial), identity: identity) })
        }
        let response = GateResult<Result<Data, Error>>()
        let prompted = GateResult<String>()
        DispatchQueue.global().async {
            response.set(Result {
                do {
                    try client.handshake(pin: pin) { presented, code in
                        prompted.set(presented)
                        return trustCase == .confirm && code == WifiHostIdentityPolicy.identityCode(for: fingerprint)
                    }
                } catch RemoteUsbTLSError.rejected {
                    XCTAssertThrowsError(try client.send(Self.frame(.ping)))
                    return Data()
                }
                try client.send(Self.frame(.ping))
                var received = Data()
                while received.count < Self.frame(.pong).count {
                    received += try client.receive(maximum: Self.frame(.pong).count - received.count)
                }
                return received
            })
        }
        let reply = try await wait(response).get()
        let request = try await wait(server).get()
        let allowed = trustCase == .saved || trustCase == .confirm
        XCTAssertEqual(prompted.value, pin == nil ? fingerprint : nil)
        XCTAssertEqual(request, allowed ? Self.frame(.ping) : Data())
        XCTAssertEqual(reply, allowed ? Self.frame(.pong) : Data())
    }

    private static func fixtureIdentity() throws -> SecIdentity {
        // Same public loopback identity as USBControlTLSIntegrationTests. Its
        // declaration is private to that suite in a separately owned source file.
        let bytes = try XCTUnwrap(Data(base64Encoded: fixture, options: .ignoreUnknownCharacters))
        var options: [String: Any] = [kSecImportExportPassphrase as String: "usb-loopback"]
        if #available(iOS 18.0, *) { options[kSecImportToMemoryOnly as String] = true }
        var items: CFArray?
        guard SecPKCS12Import(bytes as CFData, options as CFDictionary, &items) == errSecSuccess,
              let entries = items as? [[String: Any]],
              let value = entries.first?[kSecImportItemIdentity as String] else { throw GateError.unexpected }
        let ref = value as CFTypeRef
        guard CFGetTypeID(ref) == SecIdentityGetTypeID() else { throw GateError.unexpected }
        return unsafeBitCast(ref, to: SecIdentity.self)
    }

    private static let fixture = """
        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
        """
}
#endif
