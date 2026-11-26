import CryptoKit
import Combine
import Foundation
import Network
import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import iPadCasting

#if targetEnvironment(simulator)
final class ClipboardProviderReadTests: XCTestCase {
    fileprivate final class Provider: NSItemProvider, @unchecked Sendable {
        var file: URL?
        var fileReads = 0
        var dataReads = 0

        override func loadFileRepresentation(
            forTypeIdentifier typeIdentifier: String,
            completionHandler: @escaping @Sendable (URL?, (any Error)?) -> Void
        ) -> Progress {
            fileReads += 1
            completionHandler(file, nil)
            return Progress(totalUnitCount: 1)
        }

        override func loadDataRepresentation(
            forTypeIdentifier typeIdentifier: String,
            completionHandler: @escaping @Sendable (Data?, (any Error)?) -> Void
        ) -> Progress {
            dataReads += 1
            completionHandler(nil, nil)
            return Progress(totalUnitCount: 1)
        }
    }

    @MainActor func testManualAndAutomaticTextAndImagesRejectOversizedProviderFiles() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(RemoteClipboardProtocol.maxBytes + 1))
        try handle.close()

        for type in [UTType.utf8PlainText, .png] {
            for automatic in [false, true] {
                let provider = makeProvider(type, file: url)
                let (reader, change, grant) = makeReader(provider, type: type) { _ in
                    XCTFail("Oversized provider item was sent")
                }
                if automatic {
                    reader.setAutomatic(true)
                    change()
                    reader.pollForTesting(grant: grant)
                    reader.pollForTesting(grant: grant)
                } else {
                    reader.paste([provider])
                }
                let done = expectation(description: "Provider result published")
                DispatchQueue.main.async { done.fulfill() }
                await fulfillment(of: [done], timeout: 2)
                XCTAssertEqual(provider.fileReads, 1)
                XCTAssertEqual(provider.dataReads, 0)
                XCTAssertNotNil(reader.transferNotice)
                XCTAssertEqual(reader.automatic, automatic)
                reader.update(supported: false, grant: nil, reason: .ok)
            }
        }
    }

    @MainActor func testManualAndAutomaticSendValidFileBackedText() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let expected = Data([65, 10, 66])
        try Data([65, 13, 10, 66]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        for automatic in [false, true] {
            let type = UTType.utf8PlainText
            let provider = makeProvider(type, file: url)
            let sent = expectation(description: "Bounded clipboard payload sent")
            let (reader, change, grant) = makeReader(provider, type: type) { content in
                XCTAssertEqual(content.bytes, expected)
                sent.fulfill()
            }
            if automatic {
                reader.setAutomatic(true)
                change()
                reader.pollForTesting(grant: grant)
                reader.pollForTesting(grant: grant)
            } else {
                reader.paste([provider])
            }
            await fulfillment(of: [sent], timeout: 2)
            XCTAssertEqual(provider.fileReads, 1)
            XCTAssertEqual(provider.dataReads, 0)
            reader.update(supported: false, grant: nil, reason: .ok)
        }
    }

    private func makeProvider(_ type: UTType, file: URL) -> Provider {
        let provider = Provider()
        provider.file = file
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { _ in nil }
        return provider
    }

    @MainActor private func makeReader(
        _ provider: Provider, type: UTType, send: @escaping (RemoteClipboardContent) -> Void
    ) -> (RemoteClipboardPasteboard, () -> Void, RemoteClipboardAuthority.Grant) {
        var revision = 0
        let source = RemoteClipboardPasteboard.ReadSource(
            changeCount: { revision }, itemCount: { 1 }, types: { [type.identifier] }, providers: { [provider] })
        let authority = RemoteClipboardAuthority()
        let token = UUID()
        let grant = RemoteClipboardAuthority.Grant(token: token, epoch: 1, directions: 1, maxBytes: 128)
        let state = RemoteClipboardProtocol.State(kind: .enabled, directions: 1, maxBytes: 128,
            maxChunk: 128, formats: 3, nonce: UUID(), token: token, epoch: 1, requestID: 1, reason: .ok)
        authority.setSceneActive(true)
        authority.update(state, deadline: ProcessInfo.processInfo.systemUptime + 10, transfer: nil)
        let reader = RemoteClipboardPasteboard(authority: authority, worker: RemoteClipboardContentWorker(),
            send: { _, _, content, _ in send(content) }, changed: { _, _ in }, readSource: source)
        reader.update(supported: true, grant: grant, reason: .ok)
        return (reader, { revision += 1 }, grant)
    }
}
#endif

#if targetEnvironment(simulator)
final class CastingClipboardIntegrationTests: XCTestCase {
    private typealias Wire = RemoteClipboardProtocol
    private typealias Owner = (connection: NWConnection, generation: UInt64)
    private typealias Provider = ClipboardProviderReadTests.Provider

    private final class Host {
        private let suite: String
        let manager: NetworkManager
        private let defaults: UserDefaults
        private var writes: [Data] = [] // Network queue only.
        private var observeWrite: ((Data) -> Void)? // Network queue only.
        private var heldPing: ((NWError?) -> Void)?
        private var offerWritten: XCTestExpectation? // Network queue only.
        private var holdNextPing = false

        init(receivedFilesDirectory: URL? = nil) {
            let suite = "ClipboardTests." + UUID().uuidString
            self.suite = suite
            let defaults = UserDefaults(suiteName: suite)!
            self.defaults = defaults
            defaults.set(true, forKey: Wire.preferenceKey)
            manager = NetworkManager(userDefaults: defaults, receivedFilesDirectory: receivedFilesDirectory)
        }

        @MainActor func start() {
            manager.controlSendForAudioTesting = { [weak self] bytes, complete in
                guard let self else { complete(nil); return }
                self.writes.append(bytes)
                self.observeWrite?(bytes)
                if let offer = self.offerWritten, bytes.count >= WireProtocol.headerSize,
                   bytes[5] == WireMessageType.remoteFilePacket.rawValue,
                   case .packet(_, let packet)? = RemoteFileProtocol.decode(type: .remoteFilePacket,
                       payload: Data(bytes.dropFirst(WireProtocol.headerSize)), flags: 0), packet.kind == .offer {
                    self.offerWritten = nil
                    offer.fulfill()
                }
                if self.holdNextPing, bytes.count >= WireProtocol.headerSize, bytes[5] == WireMessageType.ping.rawValue {
                    self.holdNextPing = false
                    self.heldPing = complete
                } else {
                    complete(nil)
                }
            }
            manager.setRemoteClipboardSceneActive(true)
        }

        func stop() {
            manager.stopForTesting()
            defaults.removePersistentDomain(forName: suite)
        }

        func frames(_ type: UInt8, flags: UInt16 = 0) -> [Data] {
            manager.networkQueueForTesting.sync {
                writes.filter { $0.count >= 16 && $0[5] == type && $0[6] == UInt8(truncatingIfNeeded: flags) && $0[7] == UInt8(flags >> 8) }
                    .map { Data($0.dropFirst(16)) }
            }
        }

        // Replay writes and install the live observer on the same serial queue.
        // A fast response can arrive before the test starts awaiting it.
        func frame(_ type: UInt8, flags: UInt16 = 0, skipping: Int = 0,
                   file: StaticString = #filePath, line: UInt = #line) async throws -> Data {
            let seen = XCTestExpectation(description: "Wire frame \(type) after \(skipping)")
            var payload: Data?
            manager.networkQueueForTesting.sync {
                var remaining = skipping
                let inspect: (Data) -> Void = { bytes in
                    guard bytes.count >= WireProtocol.headerSize, bytes[5] == type,
                          bytes[6] == UInt8(truncatingIfNeeded: flags), bytes[7] == UInt8(flags >> 8) else { return }
                    if remaining > 0 { remaining -= 1; return }
                    payload = Data(bytes.dropFirst(WireProtocol.headerSize))
                    seen.fulfill()
                    self.observeWrite = nil
                }
                for bytes in writes {
                    inspect(bytes)
                    if payload != nil { return }
                }
                observeWrite = inspect
            }
            defer { manager.networkQueueForTesting.sync { observeWrite = nil } }
            guard await XCTWaiter.fulfillment(of: [seen], timeout: 15) == .completed else {
                XCTFail("Missing wire frame \(type) after \(skipping)", file: file, line: line)
                throw ClipboardWaitError.timedOut
            }
            return try manager.networkQueueForTesting.sync { try XCTUnwrap(payload, file: file, line: line) }
        }

        func send(_ type: UInt8, _ payload: Data, flags: UInt16 = 0, to owner: Owner) {
            manager.receiveClipboardWireForTesting(ConnectionControlProtocol.frame(type: type, payload: payload, flags: flags),
                                                   generation: owner.generation, connection: owner.connection)
        }

        func send(_ message: Wire.Message, to owner: Owner) {
            send(message.type.rawValue, message.encode(), to: owner)
        }

        func sendFile(_ message: RemoteFileProtocol.Message, to owner: Owner) throws {
            send(message.type.rawValue, try XCTUnwrap(RemoteFileProtocol.encode(message)), to: owner)
        }

        func observeNextFileOffer(_ expectation: XCTestExpectation) {
            manager.networkQueueForTesting.sync { offerWritten = expectation }
        }

        func filePackets() -> [TransferPacket] {
            frames(WireMessageType.remoteFilePacket.rawValue).compactMap { payload in
                guard case .packet(_, let packet)? = RemoteFileProtocol.decode(type: .remoteFilePacket, payload: payload, flags: 0)
                else { return nil }
                return packet
            }
        }

        func holdWriterWithPing() {
            manager.networkQueueForTesting.sync { holdNextPing = true }
            manager.enqueueTransferWireForTesting(bulk: false) { _ in }
        }

        func releasePing() throws {
            let complete = manager.networkQueueForTesting.sync {
                let complete = heldPing
                heldPing = nil
                return complete
            }
            let release = try XCTUnwrap(complete, "Expected a held ping")
            release(nil)
        }
    }

    // Poll inline so every sleep yields the main actor to pasteboard/apply work
    // (the shared Task+XCTWaiter helper starved it: 0.3 s pass became a 27 s timeout).
    @MainActor private func waitFor(_ traffic: String = "clipboard traffic", file: StaticString = #filePath,
                                    line: UInt = #line, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        if condition() { return }
        XCTFail("Timed out waiting for \(traffic)", file: file, line: line)
        throw ClipboardWaitError.timedOut
    }

    private enum ClipboardWaitError: Error { case timedOut, unexpectedResponse }

    @MainActor private func acknowledgeProbe(_ host: Host, owner: Owner) async throws -> UUID {
        let probeIndex = max(0, host.frames(6, flags: 0x1000).count - 1)
        let probe = try await host.frame(6, flags: 0x1000, skipping: probeIndex)
        XCTAssertEqual(probe.count, 16)
        let previousHellos = host.frames(111).count
        host.send(7, probe, flags: 0x1000, to: owner)
        let hello = try await host.frame(111, skipping: previousHellos)
        XCTAssertEqual(hello.count, 32)
        guard case .hello(3, 10_000_000, 16_384, let nonce)? = Wire.decode(type: .clipboardHello, payload: hello) else {
            XCTFail("Invalid casting Hello")
            return Wire.emptyID
        }
        return nonce
    }

    @MainActor private func grant(_ host: Host, owner: Owner, nonce: UUID) async throws -> Wire.State {
        let controlCount = host.frames(86).count
        host.send(.state(.init(kind: .disabled, directions: 0, maxBytes: 10_000_000, maxChunk: 16_384,
            formats: 3, nonce: nonce, token: Wire.emptyID, epoch: 1, requestID: 0, reason: .viewerDisabled)), to: owner)
        let expected = Wire.Message.control(.request, 3, 1, true, nonce)
        let request = try await host.frame(86, skipping: controlCount)
        XCTAssertEqual(Wire.decode(type: .clipboardControl, payload: request), expected)
        host.send(.state(.init(kind: .pendingConsent, directions: 0, maxBytes: 10_000_000, maxChunk: 16_384,
            formats: 3, nonce: nonce, token: Wire.emptyID, epoch: 1, requestID: 1, reason: .ok)), to: owner)
        let state = Wire.State(kind: .enabled, directions: 3, maxBytes: 10_000_000, maxChunk: 16_384,
            formats: 3, nonce: nonce, token: UUID(), epoch: 2, requestID: 1, reason: .ok)
        host.send(.state(state), to: owner)
        let enabled = expectation(description: "Clipboard grant published")
        let observation = host.manager.remoteClipboardPasteboard.$canSend.first(where: { $0 }).sink { _ in enabled.fulfill() }
        defer { observation.cancel() }
        guard await XCTWaiter.fulfillment(of: [enabled], timeout: 15) == .completed else {
            XCTFail("Clipboard grant missing")
            throw ClipboardWaitError.timedOut
        }
        return state
    }

    @MainActor private func grantRemoteClipboard(_ host: Host, owner: Owner) async throws -> Wire.State {
        try await waitFor("Remote ClipboardHello") { !host.frames(84).isEmpty }
        let hello = try XCTUnwrap(host.frames(84).last)
        let nonce = try XCTUnwrap(Wire.decode(type: .clipboardHello, payload: hello).flatMap { message -> UUID? in
            guard case .hello(_, _, _, let nonce) = message else { return nil }
            return nonce
        }, "Expected Remote Hello")
        return try await grant(host, owner: owner, nonce: nonce)
    }

    @MainActor private func acceptEmptyTextOffer(_ host: Host, owner: Owner, state: Wire.State) async throws {
        let responseCount = host.frames(88).count
        let prefix = Wire.Prefix(token: state.token, epoch: state.epoch, update: UUID())
        host.send(.offer(.init(prefix: prefix, format: .text, formats: 1, length: 0,
                               origin: UUID(), counter: 1, revision: 1, digest: Data(SHA256.hash(data: Data())))), to: owner)
        try await waitFor("ClipboardOfferResponse") { host.frames(88).count > responseCount }
        let response = try XCTUnwrap(host.frames(88).dropFirst(responseCount).first)
        guard case .response(let acceptedPrefix, true, .ok, _)? = Wire.decode(type: .clipboardOfferResponse, payload: response) else {
            return XCTFail("Expected the clipboard offer to be accepted")
        }
        XCTAssertEqual(acceptedPrefix, prefix)
    }

    @MainActor func testMissingUnflaggedMismatchedAndRawUSBRepliesLeaveCastingUnchanged() async throws {
        for (usb, replyFlags, matches) in [(false, UInt16(0), true), (false, 0x1000, false), (false, 0x1001, true),
                                           (false, nil, true), (true, 0x1000, true)] as [(Bool, UInt16?, Bool)] {
            let host = Host()
            host.start()
            defer { host.stop() }
            let owner = host.manager.commitCastingClipboardRouteForTesting(usb: usb, tls: !usb)
            try await waitFor { !host.frames(6, flags: 0x1000).isEmpty }
            let probe = try XCTUnwrap(host.frames(6, flags: 0x1000).last)
            if let replyFlags {
                var reply = probe
                if !matches { reply[0] ^= 1 }
                host.send(7, reply, flags: replyFlags, to: owner)
            } else {
                try await Task.sleep(nanoseconds: 2_100_000_000)
                host.send(7, probe, flags: 0x1000, to: owner)
            }
            XCTAssertTrue(host.frames(111).isEmpty)
            XCTAssertEqual(host.frames(6, flags: 0x1000).count, 1)
            XCTAssertFalse(host.manager.remoteClipboardPasteboard.supported)
            XCTAssertNil(host.manager.clipboardMissedCopyNotice)
            try await waitFor { host.manager.connectionState == .streaming }
        }
    }

    @MainActor func testWiFiAndUSBReprobeAndRejectRetiredOwners() async throws {
        let host = Host()
        host.start()
        defer { host.stop() }
        let wifi = host.manager.commitCastingClipboardRouteForTesting(usb: false, tls: true)
        let wifiNonce = try await acknowledgeProbe(host, owner: wifi)
        let wifiState = try await grant(host, owner: wifi, nonce: wifiNonce)
        try await acceptEmptyTextOffer(host, owner: wifi, state: wifiState)
        let wifiProbe = try XCTUnwrap(host.frames(6, flags: 0x1000).first)

        let usb = host.manager.commitCastingClipboardRouteForTesting(usb: true, tls: true)
        try await waitFor { host.frames(6, flags: 0x1000).count == 2 && !host.manager.remoteClipboardPasteboard.canSend }
        let usbProbe = try XCTUnwrap(host.frames(6, flags: 0x1000).last)
        XCTAssertNotEqual(wifiProbe, usbProbe)
        host.send(7, usbProbe, flags: 0x1000, to: wifi)
        XCTAssertEqual(host.frames(111).count, 1)
        let usbNonce = try await acknowledgeProbe(host, owner: usb)
        XCTAssertNotEqual(wifiNonce, usbNonce)
        let usbState = try await grant(host, owner: usb, nonce: usbNonce)
        try await acceptEmptyTextOffer(host, owner: usb, state: usbState)
        let newWiFi = host.manager.commitCastingClipboardRouteForTesting(usb: false, tls: true)
        try await waitFor { host.frames(6, flags: 0x1000).count == 3 && !host.manager.remoteClipboardPasteboard.canSend }
        let newProbe = try XCTUnwrap(host.frames(6, flags: 0x1000).last)
        host.send(7, newProbe, flags: 0x1000, to: usb)
        XCTAssertEqual(host.frames(111).count, 2)
        let newNonce = try await acknowledgeProbe(host, owner: newWiFi)
        XCTAssertNotEqual(usbNonce, newNonce)
        _ = try await grant(host, owner: newWiFi, nonce: newNonce)
        host.manager.stopForTesting()
        try await waitFor { !host.manager.remoteClipboardPasteboard.canSend && !host.manager.remoteClipboardPasteboard.supported }
    }

    @MainActor func testMissedCopyBeforeOfferBothDirectionsAndEchoSuppression() async throws {
        let board = UIPasteboard.general
        let savedItems = board.items
        defer { board.items = savedItems }
        let seed = Data("iPad copy".utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try seed.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = Provider()
        provider.file = url
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .ownProcess) { _ in nil }
        let host = Host()
        // Observe real pasteboard changes for PC copies and echo suppression. Drive
        // local copies through the file-backed provider with a stable test revision.
        var localRevision: Int?
        host.manager.clipboardReadSourceForTesting = .init(changeCount: { localRevision ?? board.changeCount },
            itemCount: { localRevision == nil ? board.numberOfItems : 1 },
            types: {
                if localRevision != nil { return [UTType.utf8PlainText.identifier] }
                return board.types(forItemSet: IndexSet(integer: 0))?.first ?? []
            },
            providers: { [provider] })
        host.start()
        defer { host.stop() }
        let owner = host.manager.commitCastingClipboardRouteForTesting(usb: false, tls: true)
        let nonce = try await acknowledgeProbe(host, owner: owner)
        let state = try await grant(host, owner: owner, nonce: nonce)
        XCTAssertTrue(host.manager.automaticClipboardSending)
        XCTAssertTrue(host.manager.remoteClipboardPasteboard.automatic)

        var notices: [String] = []
        let missed = expectation(description: "Missed copy notice published")
        let observer = host.manager.$clipboardMissedCopyNotice.compactMap { $0 }.sink {
            notices.append($0)
            if notices.count == 1 { missed.fulfill() }
        }
        defer { observer.cancel() }
        let status = Wire.Message.cancel(.init(token: state.token, epoch: state.epoch, update: UUID()), .clipboardBusy)
        host.send(status, to: owner)
        guard await XCTWaiter.fulfillment(of: [missed], timeout: 15) == .completed else { return XCTFail("Missing copy notice") }
        host.send(status, to: owner)

        let origin = UUID()
        func copyOnPC(_ text: String, counter: UInt64, retired: Wire.Prefix? = nil) async throws -> Wire.Prefix {
            let prefix = Wire.Prefix(token: state.token, epoch: state.epoch, update: UUID())
            let bytes = Data(text.utf8)
            let digest = Data(SHA256.hash(data: bytes))
            let responseCount = host.frames(88).count
            let resultCount = host.frames(91).count
            host.send(.offer(.init(prefix: prefix, format: .text, formats: 1, length: bytes.count,
                                   origin: origin, counter: counter, revision: counter, digest: digest)), to: owner)
            let response = try await host.frame(88, skipping: responseCount)
            guard case .response(let accepted, true, .ok, _)? = Wire.decode(type: .clipboardOfferResponse, payload: response),
                  accepted == prefix else {
                XCTFail("Expected acceptance of this PC offer")
                throw ClipboardWaitError.unexpectedResponse
            }
            if let retired {
                host.send(.cancel(retired, .timeout), to: owner)
                host.send(status, to: owner)
            }
            host.send(.chunk(prefix, 0, 0, bytes), to: owner)
            host.send(.end(prefix, bytes.count, digest), to: owner)
            let result = try await host.frame(91, skipping: resultCount)
            if case .result(let appliedPrefix, true, .ok, _)? = Wire.decode(type: .clipboardResult, payload: result) {
                XCTAssertEqual(appliedPrefix, prefix)
            } else { XCTFail("Expected iPad to apply the PC copy") }
            XCTAssertEqual(board.string, text)
            return prefix
        }

        let retired = try await copyOnPC("PC copy", counter: 1)
        XCTAssertEqual(notices, ["A copy on the PC was missed - copy it again"])
        host.manager.remoteClipboardPasteboard.pollForTesting()
        host.manager.remoteClipboardPasteboard.pollForTesting()
        XCTAssertEqual(provider.fileReads, 0)
        XCTAssertTrue(host.frames(87).isEmpty)

        host.manager.setAutomaticClipboardSending(false)
        _ = try await copyOnPC("PC copy in manual mode", counter: 2, retired: retired)
        XCTAssertEqual(notices.count, 1)
        localRevision = board.changeCount + 1
        host.manager.remoteClipboardPasteboard.pollForTesting()
        host.manager.remoteClipboardPasteboard.pollForTesting()
        XCTAssertEqual(provider.fileReads, 0)
        XCTAssertTrue(host.manager.remoteClipboardPasteboard.canPaste([provider]))
        host.manager.remoteClipboardPasteboard.paste([provider])
        let payload = try await host.frame(87)
        guard case .offer(let offer)? = Wire.decode(type: .clipboardOffer, payload: payload) else {
            return XCTFail("Expected iPad offer")
        }
        XCTAssertEqual(provider.fileReads, 1)
        XCTAssertEqual(offer.digest, Data(SHA256.hash(data: seed)))
        host.send(.response(offer.prefix, true, .ok, 1), to: owner)
        _ = try await host.frame(90)
        XCTAssertEqual(host.frames(89).compactMap { Wire.decode(type: .clipboardChunk, payload: $0) },
                       [.chunk(offer.prefix, 0, 0, seed)])
        host.send(.result(offer.prefix, true, .ok, 2), to: owner)

        host.manager.setAutomaticClipboardSending(true)
        let nextCopy = Data("Another copy".utf8)
        try nextCopy.write(to: url)
        localRevision = (localRevision ?? board.changeCount) + 1
        host.manager.remoteClipboardPasteboard.pollForTesting()
        host.manager.remoteClipboardPasteboard.pollForTesting()
        let automaticPayload = try await host.frame(87, skipping: 1)
        XCTAssertEqual(host.frames(87).count, 2)
        guard case .offer(let automaticOffer)? = Wire.decode(type: .clipboardOffer, payload: automaticPayload) else {
            return XCTFail("Expected automatic iPad offer")
        }
        XCTAssertEqual(automaticOffer.digest, Data(SHA256.hash(data: nextCopy)))
    }

    @MainActor func testRemoteMissedCopyHasNoTransferAndGrantStillAcceptsOffers() async throws {
        let host = Host()
        host.start()
        defer { host.stop() }
        host.manager.setAutomaticClipboardSending(false)
        let owner = host.manager.beginRemoteClipboardForTesting()
        let state = try await grantRemoteClipboard(host, owner: owner)
        XCTAssertEqual(host.manager.remoteInputFeatures & RemoteFeatureNegotiation.remoteFileFeature, 0)
        XCTAssertFalse(host.manager.remoteClipboardPasteboard.automatic)
        var notices = 0
        let observer = host.manager.$clipboardMissedCopyNotice.compactMap { $0 }.sink { _ in notices += 1 }
        defer { observer.cancel() }
        let status = Wire.Message.cancel(.init(token: state.token, epoch: state.epoch, update: UUID()), .timeout)
        host.send(status, to: owner)
        try await waitFor { notices == 1 }
        host.send(status, to: owner)
        XCTAssertTrue((UInt8(87)...92).allSatisfy { host.frames($0).isEmpty })
        try await acceptEmptyTextOffer(host, owner: owner, state: state)
        XCTAssertEqual(notices, 1)
    }

    @MainActor func testRemoteClipboardProgressesWhileQueuedFileChunkIsPaced() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let received = root.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: received, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.bin")
        let bytes = Data([0x01, 0x02, 0x03])
        try bytes.write(to: source)

        let host = Host(receivedFilesDirectory: received)
        // Inbound frames are driven by Host.send. Keep the simulated socket idle
        // when the file I/O callbacks ask the production receive loop for more data.
        host.manager.transferReceiveForTesting = { _, _ in }
        host.start()
        defer { host.stop() }
        host.manager.setAutomaticClipboardSending(false)
        let owner = host.manager.beginRemoteClipboardForTesting(remoteFiles: true)
        let state = try await grantRemoteClipboard(host, owner: owner)
        XCTAssertNotEqual(host.manager.remoteInputFeatures & RemoteFeatureNegotiation.remoteFileFeature, 0)
        // The upload takes a storage lease before it can send the offer.
        try await waitFor("Remote File storage setup") { host.manager.receivedFilesViewState.loaded }
        guard host.manager.receivedFilesViewState.loaded else { return }

        let control = WireMessageType.remoteFileControl
        host.manager.sendTransferFiles([source], scope: host.manager.transferActionScope)
        try await waitFor("Remote File grant request") { !host.frames(control.rawValue).isEmpty }
        let request = try XCTUnwrap(host.frames(control.rawValue).first)
        guard case .control(.requestGrant, let id, .both, _)? = RemoteFileProtocol.decode(type: control, payload: request, flags: 0) else {
            return XCTFail("Expected a Remote File grant request")
        }
        let grant = UUID()
        let offered = XCTestExpectation(description: "Remote File offer written after grant")
        host.observeNextFileOffer(offered)
        try host.sendFile(.state(phase: .granted, requestId: id, reason: .none, directions: .both, grantId: grant), to: owner)
        guard await XCTWaiter.fulfillment(of: [offered], timeout: 10) == .completed else {
            return XCTFail("Granted upload did not write an offer (stage: \(host.manager.transferSnapshot.stage))")
        }
        let snapshot = host.manager.transferSnapshot
        let offer = try XCTUnwrap(host.filePackets().first { $0.kind == .offer },
            "Expected an offer after the grant (waiting: \(host.manager.remoteFileWaiting), " +
            "stage: \(snapshot.stage), failure: \(snapshot.failure?.reason ?? "none"), " +
            "code: \(snapshot.failure?.code ?? 0))")
        XCTAssertEqual(offer.files, [TransferFile(name: "sample.bin", length: UInt64(bytes.count))])

        // Hold an earlier send so the healthy chunk queues, then pause pacing before it can start writing.
        let pingCount = host.frames(WireMessageType.ping.rawValue).count
        host.holdWriterWithPing()
        try await waitFor("held ping") { host.frames(WireMessageType.ping.rawValue).count > pingCount }
        host.manager.setRemoteFilePacingForTesting(healthy: true)
        let accepted = TransferPacket(kind: .response, generation: offer.generation, id: offer.id, accepted: true)
        try host.sendFile(.packet(grantId: grant, transfer: accepted), to: owner)
        try host.sendFile(.window(grantId: grant, offerId: offer.id, fileIndex: 0, consumedOffset: 0,
                                  maxOffset: UInt64(bytes.count), maxChunkIndexExclusive: 1), to: owner)
        try await waitFor("Remote File chunk pacing reservation") { host.manager.hasReservedRemoteFileWriteForTesting }
        host.manager.setRemoteFilePacingForTesting(healthy: false)
        try host.releasePing()

        try await acceptEmptyTextOffer(host, owner: owner, state: state)
        XCTAssertEqual(host.filePackets().map(\.kind), [.offer])

        host.manager.setRemoteFilePacingForTesting(healthy: true)
        try await waitFor("Remote File chunk after pacing resumes") { host.filePackets().contains { $0.kind == .chunk } }
        XCTAssertEqual(host.filePackets().first { $0.kind == .chunk }?.bytes, bytes)
    }

    @MainActor func testBackgroundDisablesThenRequestsFreshGrantAndControlLossDisables() async throws {
        let host = Host()
        host.start()
        defer { host.stop() }
        let owner = host.manager.commitCastingClipboardRouteForTesting(usb: false, tls: true)
        let nonce = try await acknowledgeProbe(host, owner: owner)
        let first = try await grant(host, owner: owner, nonce: nonce)
        func controls() -> [Wire.Message] { host.frames(86).compactMap { Wire.decode(type: .clipboardControl, payload: $0) } }
        host.manager.setRemoteClipboardSceneActive(false)
        XCTAssertFalse(host.manager.remoteClipboardPasteboard.canSend)
        let disable = Wire.Message.control(.disable, 0, 2, false, nonce)
        try await waitFor { controls().contains(disable) }
        host.manager.setRemoteClipboardSceneActive(true)
        let request = Wire.Message.control(.request, 3, 3, true, nonce)
        try await waitFor { controls().contains(request) }
        host.send(.state(.init(kind: .enabled, directions: 3, maxBytes: first.maxBytes, maxChunk: first.maxChunk,
            formats: first.formats, nonce: nonce, token: UUID(), epoch: 4, requestID: 3, reason: .ok)), to: owner)
        try await waitFor { host.manager.remoteClipboardPasteboard.canSend }
        host.manager.releaseMirrorControl()
        try await waitFor { controls().contains(.control(.disable, 0, 4, false, nonce)) && !host.manager.remoteClipboardPasteboard.canSend }
    }
}
#endif

final class RemoteClipboardTests: XCTestCase {
    private struct Vector: Decodable {
        let id: UInt8
        let payloadHex: String
    }

    func testHostGoldenVectorsRoundTrip() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "remote-clipboard-v2", withExtension: "json"))
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
        XCTAssertEqual(vectors.count, 17)
        for vector in vectors {
            let type = try XCTUnwrap(WireMessageType(rawValue: vector.id))
            let pairs = stride(from: 0, to: vector.payloadHex.count, by: 2).map { offset in
                String(vector.payloadHex.dropFirst(offset).prefix(2))
            }
            let data = Data(try pairs.map { try XCTUnwrap(UInt8($0, radix: 16)) })
            if vector.id == 61 || vector.id == 62 {
                XCTAssertEqual(try XCTUnwrap(RemoteFeaturesMessage.decode(data)).features, 0x1043)
                continue
            }
            let message = try XCTUnwrap(RemoteClipboardProtocol.decode(type: type, payload: data), "SCST \(vector.id)")
            XCTAssertEqual(message.encode(), data)
            XCTAssertNil(RemoteClipboardProtocol.decode(type: type, payload: data.dropLast()))
            var invalid = data
            invalid[0] = 1
            XCTAssertNil(RemoteClipboardProtocol.decode(type: type, payload: invalid))
        }
    }

    func testClipboardRequiresPairedOptInAndMatchingMarker() throws {
        for (flags, optedIn, expected) in [(UInt16(0x4000), true, false), (0x4800, false, false), (0x4800, true, true)] {
            var features = RemoteFeatureNegotiation()
            XCTAssertTrue(features.begin(now: 0))
            let request = try XCTUnwrap(features.pong(flags: flags, now: 1, requestClipboard: optedIn))
            XCTAssertEqual(RemoteFeaturesMessage.decode(request)?.features, expected ? 0x1043 : 3)
        }
    }

    func testOldHostResultDoesNotActivateClipboard() throws {
        for mask in [UInt64(3), 0x43, 0x1003, 0x1043] {
            var features = RemoteFeatureNegotiation()
            XCTAssertTrue(features.begin(now: 0))
            XCTAssertNotNil(features.pong(flags: 0x4800, now: 1, requestClipboard: true))
            XCTAssertTrue(features.result(flags: 0, payload: RemoteFeaturesMessage(features: mask).encode()))
            XCTAssertEqual(features.accepted, mask == 0x1043 ? 0x1043 : 3)
        }
    }

    func testLeaseRenewsOnlyWhileEligibleAndRequestsAgainAfterExpiry() throws {
        var lease = RemoteClipboardLease()
        let hello = try XCTUnwrap(lease.start())
        guard case .hello(_, _, _, let nonce) = hello else { return XCTFail("Expected Hello") }
        XCTAssertNil(lease.tick(eligible: true, now: 0))
        let disabled = RemoteClipboardProtocol.State(kind: .disabled, directions: 0, maxBytes: 10_000_000,
            maxChunk: 16_384, formats: 3, nonce: nonce, token: RemoteClipboardProtocol.emptyID,
            epoch: 1, requestID: 0, reason: .viewerDisabled)
        lease.receive(disabled, eligible: true, now: 0)
        let request = try XCTUnwrap(lease.tick(eligible: true, now: 0))
        XCTAssertEqual(request, .control(.request, 3, 1, true, nonce))
        let grant = RemoteClipboardProtocol.State(kind: .enabled, directions: 3, maxBytes: 10_000_000,
            maxChunk: 16_384, formats: 3, nonce: nonce, token: UUID(), epoch: 2, requestID: 1, reason: .ok)
        lease.receive(grant, eligible: true, now: 0.1)
        XCTAssertEqual(lease.tick(eligible: true, now: 1.1), .control(.renew, 3, 2, true, nonce))
        XCTAssertEqual(lease.tick(eligible: true, now: 4), .control(.request, 3, 3, true, nonce))
        XCTAssertNil(lease.grant)
        lease.receive(grant, eligible: true, now: 4.1)
        XCTAssertNil(lease.grant)
        XCTAssertEqual(lease.tick(eligible: false, now: 4.1), .control(.disable, 0, 4, false, nonce))
        XCTAssertNil(lease.tick(eligible: false, now: 5.1))
    }

    func testCastingConsentWaitKeepsRequestThenUsesThreeSecondGrantLease() throws {
        let wire = RemoteClipboardProtocol.self
        var lease = RemoteClipboardLease()
        _ = lease.start()
        let nonce = try XCTUnwrap(lease.nonce)
        func state(_ kind: RemoteClipboardProtocol.Kind, epoch: UInt64, id: UInt64) -> RemoteClipboardProtocol.State {
            .init(kind: kind, directions: kind == .enabled ? 3 : 0, maxBytes: wire.maxBytes, maxChunk: wire.maxChunk,
                  formats: 3, nonce: nonce, token: kind == .enabled ? UUID() : wire.emptyID,
                  epoch: epoch, requestID: id, reason: .ok)
        }
        lease.receive(state(.disabled, epoch: 1, id: 0), eligible: true, now: 0)
        XCTAssertEqual(lease.tick(eligible: true, now: 0, requestTimeout: 15), .control(.request, 3, 1, true, nonce))
        lease.receive(state(.pendingConsent, epoch: 1, id: 1), eligible: true, now: 0.25)
        XCTAssertNil(lease.tick(eligible: true, now: 14, requestTimeout: 15))
        lease.receive(state(.enabled, epoch: 2, id: 1), eligible: true, now: 15)
        XCTAssertNotNil(lease.grant)
        XCTAssertEqual(lease.validUntil, 18)
        XCTAssertNil(lease.tick(eligible: true, now: 15.9))
        XCTAssertEqual(lease.tick(eligible: true, now: 16), .control(.renew, 3, 2, true, nonce))
        XCTAssertEqual(lease.tick(eligible: false, now: 16.1), .control(.disable, 0, 3, false, nonce))
        XCTAssertEqual(lease.tick(eligible: true, now: 16.2), .control(.request, 3, 4, true, nonce))
        XCTAssertTrue(lease.mayWrite(.disable, id: 3, now: 16.2))
    }

    func testParserRejectsUnnegotiatedOrOversizedClipboardBeforeAllocation() {
        for (negotiated, length, flags, accepted) in [
            (false, 65, UInt16(0), false), (true, 65, 1, false),
            (true, 64, 0, false), (true, 16_449, 0, false), (true, 65, 0, true)
        ] {
            let parser = WireStreamParser(generation: 1, allowsRemoteClipboard: { negotiated })
            var header = Data(count: WireProtocol.headerSize)
            header.storeLittleEndian(WireProtocol.magic, at: 0)
            header[4] = WireProtocol.version
            header[5] = WireMessageType.clipboardChunk.rawValue
            header.storeLittleEndian(flags, at: 6)
            header.storeLittleEndian(UInt32(length), at: 8)
            var failed = false
            parser.consume(header, generation: 1) { event in
                if case .failure = event { failed = true }
            }
            XCTAssertEqual(failed, !accepted)
            XCTAssertEqual(parser.allocatedPayloadBytes, accepted ? length : 0)
        }
    }

    func testTransferRequiresContiguousChunksAndMatchingDigest() {
        let bytes = Data("abc".utf8)
        let digest = Data(SHA256.hash(data: bytes))
        let prefix = RemoteClipboardProtocol.Prefix(token: UUID(), epoch: 1, update: UUID())
        let offer = RemoteClipboardProtocol.Offer(prefix: prefix, format: .text, formats: 1, length: bytes.count,
                                                 origin: UUID(), counter: 1, revision: 0, digest: digest)
        let transfer = RemoteClipboardTransfer(offer: offer, now: 0)
        XCTAssertFalse(transfer.append(index: 0, offset: 0, data: bytes, maxChunk: 3, now: 1))
        XCTAssertTrue(transfer.accept(revision: 4, now: 1))
        XCTAssertFalse(transfer.append(index: 0, offset: 1, data: bytes, maxChunk: 3, now: 2))
        XCTAssertFalse(transfer.append(index: 0, offset: 0, data: bytes, maxChunk: 2, now: 2))
        XCTAssertTrue(transfer.append(index: 0, offset: 0, data: bytes, maxChunk: 3, now: 2))
        XCTAssertFalse(transfer.append(index: 0, offset: 0, data: bytes, maxChunk: 3, now: 3))
        XCTAssertNil(transfer.finish(length: 3, digest: Data(count: 32), now: 3))
        XCTAssertEqual(transfer.finish(length: 3, digest: digest, now: 3), bytes)
        XCTAssertNil(transfer.finish(length: 3, digest: digest, now: 3))
    }

    func testCanonicalTextAndChunkBounds() {
        XCTAssertEqual(RemoteClipboardProtocol.canonicalText(Data("a\r\nb".utf8), fromWire: false), Data("a\nb".utf8))
        XCTAssertEqual(RemoteClipboardProtocol.canonicalText(Data(), fromWire: true), Data())
        for invalid in [Data([0xff]), Data([0]), Data([0xef, 0xbb, 0xbf]), Data([13, 10])] {
            XCTAssertNil(RemoteClipboardProtocol.canonicalText(invalid, fromWire: true))
        }
        XCTAssertFalse(RemoteClipboardProtocol.validLength(.clipboardChunk, 64))
        XCTAssertTrue(RemoteClipboardProtocol.validLength(.clipboardChunk, 64 + 16_384))
        XCTAssertFalse(RemoteClipboardProtocol.validLength(.clipboardChunk, 65 + 16_384))
    }
}
