import CryptoKit
import Foundation
import Security

// Feasibility adapter. Serialize handshake/send/receive on an I/O worker.
// cancel() is safe from another queue and must wake any pending stream operation.
protocol RemoteUsbSession {
    func handshake(pin: String?, confirm: (String, String) -> Bool) throws
    func send(_ data: Data) throws
    func receive(maximum: Int) throws -> Data
    func cancel()
}

enum RemoteUsbTLSError: Error { case closed, rejected, status(OSStatus) }

// Blocking callbacks have bounded waits, return positive progress or throw.
// Only ciphertext crosses this boundary. The owner supplies an already accepted stream.
final class RemoteUsbDuplex {
    let read: (Int) throws -> Data
    let write: (UnsafeRawBufferPointer) throws -> Int
    private let stop: () -> Void
    private let lock = NSLock()
    private var stopped = false

    init(read: @escaping (Int) throws -> Data,
         write: @escaping (UnsafeRawBufferPointer) throws -> Int, cancel: @escaping () -> Void) {
        self.read = read
        self.write = write
        self.stop = cancel
    }

    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    func cancel() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        stop()
    }

    // Security/SecureTransport.h: SSLSetIOFuncs, SSLSetConnection. The context owner
    // retains the duplex for all calls. Callbacks report the exact prefix transferred.
    func attach(to context: SSLContext) throws {
        let status = SSLSetIOFuncs(context, { ref, destination, length in
            let io = Unmanaged<RemoteUsbDuplex>.fromOpaque(ref).takeUnretainedValue()
            let requested = length.pointee
            length.pointee = 0
            do {
                while length.pointee < requested {
                    let remaining = requested - length.pointee
                    guard !io.cancelled else { throw RemoteUsbTLSError.closed }
                    let part = try io.read(remaining)
                    guard !part.isEmpty, part.count <= remaining else { throw RemoteUsbTLSError.closed }
                    part.copyBytes(to: destination.advanced(by: length.pointee)
                        .assumingMemoryBound(to: UInt8.self), count: part.count)
                    length.pointee += part.count
                }
                return errSecSuccess
            } catch { return errSSLClosedAbort }
        }, { ref, source, length in
            let io = Unmanaged<RemoteUsbDuplex>.fromOpaque(ref).takeUnretainedValue()
            let requested = length.pointee
            length.pointee = 0
            do {
                while length.pointee < requested {
                    let remaining = requested - length.pointee
                    guard !io.cancelled else { throw RemoteUsbTLSError.closed }
                    let bytes = UnsafeRawBufferPointer(start: source.advanced(by: length.pointee), count: remaining)
                    let written = try io.write(bytes)
                    guard written > 0, written <= remaining else { throw RemoteUsbTLSError.closed }
                    length.pointee += written
                }
                return errSecSuccess
            } catch { return errSSLClosedAbort }
        })
        guard status == errSecSuccess else { throw RemoteUsbTLSError.status(status) }
        let bound = SSLSetConnection(context, Unmanaged.passUnretained(self).toOpaque())
        guard bound == errSecSuccess else { throw RemoteUsbTLSError.status(bound) }
    }
}

// Apple TN2232 describes the server-auth breakpoint and SSLCopyPeerTrust.
// Secure Transport is deprecated and supports TLS 1.2 for this prototype.
final class RemoteUsbTransport: RemoteUsbSession {
    private let stream: RemoteUsbDuplex
    private let context: SSLContext
    private var started = false
    private var ready = false

    init(stream: RemoteUsbDuplex) throws {
        self.stream = stream
        guard let context = SSLCreateContext(nil, .clientSide, .streamType) else {
            stream.cancel()
            throw RemoteUsbTLSError.closed
        }
        self.context = context
        do {
            try stream.attach(to: context)
            try check(SSLSetProtocolVersionMin(context, .tlsProtocol12))
            try check(SSLSetSessionOption(context, .breakOnServerAuth, true))
        } catch { stream.cancel(); throw error }
    }

    deinit { stream.cancel() }
    func cancel() { stream.cancel() }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw RemoteUsbTLSError.status(status) }
    }

    func handshake(pin: String?, confirm: (String, String) -> Bool) throws {
        guard !started, !stream.cancelled else { throw RemoteUsbTLSError.closed }
        started = true
        do {
            let breakpoint = SSLHandshake(context)
            guard breakpoint == errSSLPeerAuthCompleted else { throw RemoteUsbTLSError.status(breakpoint) }
            var trust: SecTrust?
            try check(SSLCopyPeerTrust(context, &trust))
            guard let trust, let leaf = SecTrustGetCertificateAtIndex(trust, 0) else {
                throw RemoteUsbTLSError.rejected
            }
            let fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
                .map { String(format: "%02X", $0) }.joined(separator: ":")
            switch WifiHostIdentityPolicy.decide(presentedFingerprint: fingerprint, pinnedFingerprint: pin) {
            case .trusted: break
            case .requiresFirstPairingConfirmation:
                guard let code = WifiHostIdentityPolicy.identityCode(for: fingerprint),
                      confirm(fingerprint, code) else { throw RemoteUsbTLSError.rejected }
            case .rejected: throw RemoteUsbTLSError.rejected
            }
            guard !stream.cancelled else { throw RemoteUsbTLSError.closed }
            try check(SSLHandshake(context))
            ready = true
        } catch { stream.cancel(); throw error }
    }

    func send(_ data: Data) throws {
        guard ready, !stream.cancelled else { throw RemoteUsbTLSError.closed }
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                var sent = 0
                let remaining = bytes.count - offset
                let status = SSLWrite(context, base.advanced(by: offset), remaining, &sent)
                guard status == errSecSuccess, sent > 0, sent <= remaining else {
                    stream.cancel()
                    throw RemoteUsbTLSError.status(status)
                }
                offset += sent
            }
        }
    }

    func receive(maximum: Int) throws -> Data {
        guard ready, !stream.cancelled, maximum > 0 else { throw RemoteUsbTLSError.closed }
        var data = Data(count: min(maximum, 16_384))
        var count = 0
        let status = data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            SSLRead(context, bytes.baseAddress!, bytes.count, &count)
        }
        guard status == errSecSuccess, count > 0, count <= data.count else {
            stream.cancel()
            throw RemoteUsbTLSError.status(status)
        }
        return data.prefix(count)
    }
}
