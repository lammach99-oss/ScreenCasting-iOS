import XCTest
import UIKit
import MetalKit
import CoreImage
import Combine
@testable import iPadCasting

#if targetEnvironment(simulator)
final class FocusCoordinatorTests: XCTestCase {
    @MainActor func testReleaseUsesOldLeaseAndDelayedPresentationCannotAcquireNewLease() throws {
        let focus = FocusCoordinator.forTesting(primary: NetworkManager(role: .secondaryRemote))
        final class Sink {
            var packets = [Data]()
        }
        let sinks = [Sink(), Sink()]
        for (index, network) in [focus.primary, focus.secondary].enumerated() {
            let sink = sinks[index]
            network.controlSendForAudioTesting = { data, done in
                sink.packets.append(data)
                done(nil)
            }
            _ = network.beginRemoteClipboardForTesting()
        }
        defer { focus.primary.stopForTesting(); focus.secondary.stopForTesting() }
        let a = try XCTUnwrap(focus.connect(.one, route: .wifi))
        let b = try XCTUnwrap(focus.connect(.two, route: .wifi))
        XCTAssertTrue(focus.authenticate(a, transport: focus.primary.remoteKeyboardGeneration, peer: try XCTUnwrap(TrustedPeerReference(String(repeating: "1", count: 64)))))
        XCTAssertTrue(focus.authenticate(b, transport: focus.secondary.remoteKeyboardGeneration, peer: try XCTUnwrap(TrustedPeerReference(String(repeating: "2", count: 64)))))
        focus.claimSurface("scene")
        let old = try XCTUnwrap(focus.binding)
        focus.contextReady(old)
        XCTAssertNil(focus.outputLease)
        focus.presented(old)
        XCTAssertEqual(focus.outputLease, old.ticket)
        XCTAssertTrue(focus.primary.acceptsFocusInput(old.ticket))
        let session = IPadInputSession(automaticallyTicks: false)
        // Install the old-peer sink exactly as the surface does. Generate a
        // held scan key; retireFocus must send the matching release to A.
        let oldNetwork = focus.primary
        session.configure(identity: "first", point: true, type: true, direct: true, zoom: false,
                          reason: nil) { event in
            guard case let .key(_, action) = event, oldNetwork.acceptsFocusInput(old.ticket) else { return }
            oldNetwork.sendRemoteScanKey(.init(action: action, flags: 0, scan: 30, token: 1),
                                         expectedGeneration: old.transport)
        }
        session.engine.hardware(usage: 4, down: true)
        oldNetwork.networkQueueForTesting.sync {}
        oldNetwork.networkQueueForTesting.sync {}
        focus.primary.retireFocusInput = { session.retireFocus() }
        let delayedText = { focus.performInput(old.ticket) { $0.sendTextCommit("test") } }
        let delayedPointer = { focus.performInput(old.ticket) {
            $0.sendRemotePointer(.init(kind: 2, button: 1, token: 1, a: 1, b: 0), expectedGeneration: old.transport)
        } }
        focus.select(.two, scene: "scene")
        func keyActions(_ network: NetworkManager, _ sink: Sink) -> [UInt8] {
            network.networkQueueForTesting.sync {}
            return network.networkQueueForTesting.sync {
                sink.packets.filter { $0.count >= 16 && $0[5] == WireMessageType.remoteScanKey.rawValue }
                    .compactMap { RemoteScanKeyCommand.decode(Data($0.dropFirst(16)))?.action }
            }
        }
        XCTAssertEqual(keyActions(oldNetwork, sinks[0]), [0, 1])
        XCTAssertFalse(focus.primary.acceptsFocusInput(old.ticket))
        XCTAssertFalse(focus.primary.clipboardSceneActiveForTesting)
        XCTAssertFalse(focus.secondary.clipboardSceneActiveForTesting)
        let new = try XCTUnwrap(focus.binding)
        focus.contextReady(new)
        focus.presented(old)
        XCTAssertNil(focus.outputLease)
        focus.select(.one, scene: "scene")
        focus.select(.two, scene: "scene")
        focus.presented(new)
        XCTAssertEqual(focus.outputLease, new.ticket)
        XCTAssertTrue(focus.secondary.clipboardSceneActiveForTesting)
        XCTAssertTrue(focus.secondary.acceptsFocusInput(new.ticket))
        focus.performInput(old.ticket) { _ in XCTFail("Retired input reached a peer") }
        delayedText()
        delayedPointer()
        XCTAssertTrue(keyActions(focus.secondary, sinks[1]).isEmpty)
        for (index, network) in [oldNetwork, focus.secondary].enumerated() {
            network.networkQueueForTesting.sync {}
            network.networkQueueForTesting.sync {
                let forbidden = [WireMessageType.remoteCommittedText, .textCommit, .remotePointer]
                XCTAssertFalse(sinks[index].packets.contains { bytes in
                    bytes.count >= 16 && forbidden.contains { $0.rawValue == bytes[5] }
                })
            }
        }
        XCTAssertFalse(focus.primary.acceptsFocusInput(old.ticket))
        focus.model.recordAuthorizedThumbnail(new.ticket, revision: 1)
        XCTAssertEqual(focus.model[.two].preview, .thumbnail(revision: 1))
        focus.appLifecycleChanged(active: false)
        XCTAssertNil(focus.outputLease)
        XCTAssertFalse(focus.secondary.acceptsFocusInput(new.ticket))
        for slot in [SlotOrdinal.one, .two] {
            XCTAssertFalse(focus.manager(slot).clipboardSceneActiveForTesting)
            XCTAssertNil(focus.thumbnail(for: slot))
            XCTAssertEqual(focus.model[slot].preview, .placeholder)
        }
        let parkedEpoch = focus.model[.one].epoch
        focus.appLifecycleChanged(active: true)
        XCTAssertGreaterThan(focus.model[.one].epoch, parkedEpoch)
        XCTAssertNil(focus.outputLease)
        let resumed = try XCTUnwrap(focus.binding)
        XCTAssertNotEqual(resumed.ticket, new.ticket)
        focus.presented(new)
        XCTAssertNil(focus.outputLease)
        focus.presented(resumed)
        XCTAssertEqual(focus.outputLease, resumed.ticket)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: focus.exportDiagnostics()) as? [[String: Any]])
        XCTAssertTrue(rows.contains { $0["event"] as? String == "parked" })
        XCTAssertTrue(rows.allSatisfy { Set($0.keys) == ["slot", "epoch", "route", "event", "elapsedMs"] })
    }

    @MainActor func testSwapRevokesFileGrantCreatedAfterOutputPromotion() async throws {
        let primary = NetworkManager(role: .secondaryRemote)
        let focus = FocusCoordinator.forTesting(primary: primary)
        defer { primary.stopForTesting(); focus.secondary.stopForTesting() }
        var controls = [RemoteFileProtocol.Message]()
        primary.controlSendForAudioTesting = { bytes, done in
            if bytes.count >= 16, bytes[5] == WireMessageType.remoteFileControl.rawValue,
               let message = RemoteFileProtocol.decode(type: .remoteFileControl, payload: Data(bytes.dropFirst(16)), flags: 0) {
                Task { @MainActor in controls.append(message) }
            }
            done(nil)
        }
        focus.secondary.controlSendForAudioTesting = { _, done in done(nil) }
        let owner = primary.beginRemoteClipboardForTesting(remoteFiles: true)
        _ = focus.secondary.beginRemoteClipboardForTesting()
        for (slot, digit) in [(SlotOrdinal.one, "1"), (.two, "2")] {
            let ticket = try XCTUnwrap(focus.connect(slot, route: .wifi))
            XCTAssertTrue(focus.authenticate(ticket, transport: focus.manager(slot).remoteKeyboardGeneration,
                peer: try XCTUnwrap(TrustedPeerReference(String(repeating: digit, count: 64)))))
        }
        focus.claimSurface("scene")
        let binding = try XCTUnwrap(focus.binding)
        focus.presented(binding)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([1]).write(to: file)
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertTrue(condition())
        }
        try await waitUntil { primary.isRemoteControlSession }
        primary.sendTransferFiles([file], scope: primary.transferActionScope)
        try await waitUntil { !controls.isEmpty }
        guard case let .control(.requestGrant, request, _, _)? = controls.first else {
            return XCTFail("Expected a grant request")
        }
        let grant = UUID()
        let reply = RemoteFileProtocol.Message.state(phase: .granted, requestId: request, reason: .none,
                                                     directions: .both, grantId: grant)
        primary.receiveMirrorWireForTesting(type: .remoteFileState, payload: try XCTUnwrap(RemoteFileProtocol.encode(reply)),
                                            generation: owner.generation, connection: owner.connection)
        try await waitUntil { primary.transferSnapshot.slotAction != nil }
        XCTAssertEqual(primary.transferSnapshot.slotAction?.epoch, binding.ticket.epoch)
        focus.select(.two, scene: "scene")
        try await waitUntil {
            let released = controls.contains { message in
                guard case let .control(.release, _, _, id) = message else { return false }
                return id == grant
            }
            return released && primary.transferSnapshot.slotAction == nil
        }
    }

    @MainActor func testSingleSlotExportPreservesTelemetryFileBytes() async throws {
        let primary = NetworkManager(role: .secondaryRemote)
        let focus = FocusCoordinator.forTesting(primary: primary)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let telemetry = primary.telemetryForFocusTesting
        let url: URL? = await withCheckedContinuation { continuation in
            _ = telemetry.startLogging(directoryURL: directory) { continuation.resume(returning: $0) }
        }
        let original = try Data(contentsOf: XCTUnwrap(url))
        XCTAssertFalse(original.isEmpty)
        XCTAssertEqual(focus.exportDiagnostics(), original)
        await withCheckedContinuation { continuation in
            telemetry.stopLogging { continuation.resume() }
        }
    }

    func testAudioLeaseStopsPreviousOutputBeforeGrantAndRejectsDelayedCompletion() {
        let lease = RemoteAudioOutputLease()
        var events = [String]()
        let a = lease.acquire { events.append("stop A") }
        let delayed = { if lease.owns(a) { events.append("play A") } }
        let b = lease.acquire { events.append("stop B") }
        XCTAssertFalse(lease.owns(a))
        XCTAssertTrue(lease.owns(b))
        delayed()
        lease.release(a)
        XCTAssertTrue(lease.owns(b))
        lease.release(b)
        XCTAssertEqual(events, ["stop A", "stop B"])
    }

    @MainActor func testWatchdogRequiresTapForAlternate() throws {
        let focus = FocusCoordinator.forTesting(primary: NetworkManager(role: .secondaryRemote))
        defer { focus.primary.stopForTesting(); focus.secondary.stopForTesting() }
        for (slot, digit) in [(SlotOrdinal.one, "1"), (.two, "2")] {
            let manager = focus.manager(slot)
            manager.controlSendForAudioTesting = { _, done in done(nil) }
            _ = manager.beginRemoteClipboardForTesting()
            let t = try XCTUnwrap(focus.connect(slot, route: .wifi))
            XCTAssertTrue(focus.authenticate(t, transport: manager.remoteKeyboardGeneration, peer: try XCTUnwrap(TrustedPeerReference(String(repeating: digit, count: 64)))))
        }
        focus.claimSurface("scene")
        let binding = try XCTUnwrap(focus.binding)
        focus.watchdog(binding, expired: false)
        XCTAssertNil(focus.outputLease)
        focus.watchdog(binding, expired: true)
        XCTAssertEqual(focus.model.offeredAlternate, .two)
        XCTAssertEqual(focus.model.selected, .one)
        XCTAssertTrue(focus.model[.one].retryRequested)
        XCTAssertTrue(focus.primary.authenticatedRemoteIP(binding.transport))
        XCTAssertNil(focus.connect(.one, route: .wifi))
        focus.select(.one, scene: "scene")
        let retry = try XCTUnwrap(focus.binding)
        XCTAssertNotEqual(retry.ticket, binding.ticket)
        XCTAssertEqual(retry.transport, binding.transport)
        focus.presented(binding)
        XCTAssertNil(focus.outputLease)
    }
}

extension FocusCoordinatorTests {
    @MainActor private func restoredPair(selected: SlotOrdinal) throws -> FocusCoordinator {
        let first = try XCTUnwrap(TrustedPeerReference(String(repeating: "1", count: 64)))
        let second = try XCTUnwrap(TrustedPeerReference(String(repeating: "2", count: 64)))
        return FocusCoordinator.forTesting(primary: NetworkManager(role: .secondaryRemote),
            pair: .init(first: first, second: second, selected: selected))
    }

    @MainActor private func authenticateSavedSlot(_ ticket: SlotTicket, in focus: FocusCoordinator) throws {
        let network = focus.manager(ticket.ordinal)
        network.controlSendForAudioTesting = { _, done in done(nil) }
        _ = network.beginRemoteClipboardForTesting()
        XCTAssertTrue(focus.authenticate(ticket, transport: network.remoteKeyboardGeneration,
            peer: try XCTUnwrap(focus.model[ticket.ordinal].peer)))
    }

    @MainActor func testRestoreFencesBothSlotsBeforeAuthentication() throws {
        let focus = try restoredPair(selected: .two)
        defer { focus.primary.stopForTesting(); focus.secondary.stopForTesting() }
        focus.prepareForRestore()
        for network in [focus.primary, focus.secondary] {
            XCTAssertTrue(network.focusManaged)
            XCTAssertFalse(network.acceptsFocusInput(nil))
        }
        XCTAssertNil(focus.outputLease)
        let network = focus.primary
        network.controlSendForAudioTesting = { _, done in done(nil) }
        let owner = network.beginRemoteClipboardForTesting(audioEnabled: true)
        var decoded = false
        network.captureTargetDecodeForTesting = { _, _, _ in decoded = true }
        network.receiveCaptureTargetWireForTesting(type: .video, payload: Data([0, 0, 0, 2, 38, 1]),
            flags: WireProtocol.videoFlagIDR | WireProtocol.videoFlagLengthPrefixed, sequence: 1,
            generation: owner.generation, connection: owner.connection)
        XCTAssertFalse(decoded)
        for message in [RemoteAudioProtocol.Message.state(phase: .streaming, reason: .none, requestId: 0,
                                                           audioEpoch: 1, startUs: 1),
                        .packet(audioSequence: 1, audioEpoch: 1, captureUs: 2, opus: Data([0]))] {
            network.receiveCaptureTargetWireForTesting(type: message.type,
                payload: try XCTUnwrap(RemoteAudioProtocol.encode(message)), flags: 0,
                generation: owner.generation, connection: owner.connection)
        }
        XCTAssertTrue(network.authenticatedRemoteIP(owner.generation))
        XCTAssertTrue(network.focusAudioFencedForTesting)
    }

    @MainActor func testPresentedWithoutContextExpiresAndCanReturn() async throws {
        let focus = try restoredPair(selected: .one)
        defer { focus.primary.stopForTesting(); focus.secondary.stopForTesting() }
        try authenticateSavedSlot(try XCTUnwrap(focus.connect(.one, route: .wifi)), in: focus)
        let second = try XCTUnwrap(focus.connect(.two, route: .wifi))
        focus.secondary.controlSendForAudioTesting = { _, done in done(nil) }
        let peer = focus.secondary.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS, remote: true)
        XCTAssertTrue(focus.authenticate(second, transport: peer.generation, peer: try XCTUnwrap(focus.model[.two].peer)))
        focus.claimSurface("scene")
        focus.presented(try XCTUnwrap(focus.binding))
        focus.select(.two, scene: "scene")
        let waiting = try XCTUnwrap(focus.binding)
        focus.presented(waiting)
        XCTAssertNil(focus.outputLease)
        let expired = expectation(description: "Lease deadline released the waiting slot")
        let observer = focus.$binding.dropFirst().sink { if $0 == nil { expired.fulfill() } }
        await fulfillment(of: [expired], timeout: 9)
        observer.cancel()
        XCTAssertNil(focus.model.inFlight)
        XCTAssertTrue(focus.model[.two].retryRequested)
        focus.select(.one, scene: "scene")
        focus.presented(try XCTUnwrap(focus.binding))
        XCTAssertEqual(focus.outputLease?.ordinal, .one)
    }

    @MainActor func testSwapTimelineUsesWireAndDecoderCallbacks() async throws {
        let focus = try restoredPair(selected: .one)
        defer { focus.primary.stopForTesting(); focus.secondary.stopForTesting() }
        try authenticateSavedSlot(try XCTUnwrap(focus.connect(.one, route: .wifi)), in: focus)
        let ticket = try XCTUnwrap(focus.connect(.two, route: .wifi))
        let network = focus.secondary
        network.controlSendForAudioTesting = { _, done in done(nil) }
        let peer = network.beginRemoteClipboardForTesting(standbyEnabled: true)
        XCTAssertTrue(focus.authenticate(ticket, transport: peer.generation, peer: try XCTUnwrap(focus.model[.two].peer)))
        func receive(_ type: WireMessageType, _ data: Data, flags: UInt16 = 0) {
            network.receiveCaptureTargetWireForTesting(type: type, payload: data, flags: flags, sequence: 1,
                                                      generation: peer.generation, connection: peer.connection)
        }
        receive(.remoteVideoStandby, try XCTUnwrap(RemoteVideoStandbyMessage(operation: .parked, serial: 1).encode()))
        focus.claimSurface("scene")
        focus.presented(try XCTUnwrap(focus.binding))
        focus.select(.two, scene: "scene")
        let binding = try XCTUnwrap(focus.binding)
        receive(.remoteVideoStandby, try XCTUnwrap(RemoteVideoStandbyMessage(operation: .resuming, serial: 2).encode()))
        network.captureTargetDecodeForTesting = { _, sequence, generation in
            network.decoder.onDecodeCompleted?(sequence, generation, true)
        }
        defer { network.captureTargetDecodeForTesting = nil }
        let idr = Data([UInt8(32), 33, 34, 19].flatMap { [UInt8(0), 0, 0, 2, $0 << 1, 1] })
        receive(.video, idr, flags: WireProtocol.videoFlagIDR | WireProtocol.videoFlagLengthPrefixed)
        network.networkQueueForTesting.sync {}
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { done.resume() }
        }
        focus.presented(binding)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: focus.exportDiagnostics()) as? [[String: Any]])
        let stages = rows.filter { $0["slot"] as? Int == 2 && $0["epoch"] as? UInt64 == binding.ticket.epoch }
                         .compactMap { $0["event"] as? String }
        XCTAssertEqual(stages.filter { ["request", "acknowledged", "receivedIDR", "decoded", "presented", "outputGranted"].contains($0) },
                       ["request", "acknowledged", "receivedIDR", "decoded", "presented", "outputGranted"])
        XCTAssertEqual(stages.filter { $0 == "inputReady" }.count, 1)
    }

    @MainActor func testSimulatorDrawGrantsLeaseAndProducesReadableThumbnail() async throws {
        let focus = try restoredPair(selected: .one)
        defer { focus.primary.stopForTesting(); focus.secondary.stopForTesting() }
        try authenticateSavedSlot(try XCTUnwrap(focus.connect(.one, route: .wifi)), in: focus)
        focus.claimSurface("scene")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: MTLCreateSystemDefaultDevice())
        controller.view.addSubview(view)
        window.isHidden = false
        window.layoutIfNeeded()
        defer { window.isHidden = true }
        let renderer = try XCTUnwrap(Renderer(metalView: view))
        let generation = focus.primary.decoder.currentSessionGeneration
        renderer.beginSession(generation: generation)
        let presented = expectation(description: "Simulator rendered frame")
        renderer.installFocusPresentation { _ in
            DispatchQueue.main.async {
                focus.primary.focusPresented?()
                presented.fulfill()
            }
        }
        var storage: CVPixelBuffer?
        var attributes = DecoderOutputBufferAttributes.make()
        attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, DecoderOutputBufferAttributes.pixelFormat,
                                           attributes as CFDictionary, &storage), kCVReturnSuccess)
        let frame = try XCTUnwrap(storage)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(frame, []), kCVReturnSuccess)
        for plane in 0..<2 {
            if let base = CVPixelBufferGetBaseAddressOfPlane(frame, plane) {
                let length = CVPixelBufferGetBytesPerRowOfPlane(frame, plane) * CVPixelBufferGetHeightOfPlane(frame, plane)
                memset(base, plane == 0 ? 255 : 128, length)
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        renderer.updateFrame(frame, sequence: 1, generation: generation)
        view.draw()
        await fulfillment(of: [presented], timeout: 3)
        XCTAssertEqual(focus.outputLease?.ordinal, .one)
        let image = try XCTUnwrap(renderer.focusThumbnail().flatMap { UIImage(data: $0) }?.cgImage)
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 180)
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(CIImage(cgImage: image), toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
        XCTAssertTrue(pixel.prefix(3).allSatisfy { $0 > 230 })
    }

    @MainActor func testFirstSlotOwnsOutputWhileSecondConnectsAndAfterRefusal() throws {
        let focus = try restoredPair(selected: .one)
        defer { focus.primary.stopForTesting(); focus.secondary.stopForTesting() }
        let first = try XCTUnwrap(focus.connect(.one, route: .wifi))
        try authenticateSavedSlot(first, in: focus)
        let second = try XCTUnwrap(focus.connect(.two, route: .wifi))
        focus.claimSurface("scene")
        let live = try XCTUnwrap(focus.binding)
        XCTAssertEqual(live.ticket.ordinal, .one)
        XCTAssertNil(focus.outputLease)
        focus.presented(live)
        XCTAssertTrue(focus.ownsOutput(live.ticket))
        focus.drop(second, error: .refused)
        XCTAssertEqual(focus.binding, live)
        XCTAssertTrue(focus.ownsOutput(live.ticket))
        focus.endPair(scene: "scene")
        XCTAssertNil(focus.binding)
        XCTAssertNil(focus.outputLease)
        XCTAssertFalse(focus.primary.focusManaged)
        XCTAssertTrue(focus.primary.acceptsFocusInput(nil))
        XCTAssertTrue(focus.primary.clipboardSceneActiveForTesting)
        XCTAssertTrue(focus.primary.authenticatedRemoteIP(live.transport))
    }

    @MainActor func testOfflineSavedSelectionNeedsTapBeforeSurvivorOwnsOutput() throws {
        let focus = try restoredPair(selected: .two)
        defer { focus.endPair(scene: "scene"); focus.primary.stopForTesting(); focus.secondary.stopForTesting() }
        focus.claimSurface("scene")
        let second = try XCTUnwrap(focus.connect(.two, route: .wifi))
        focus.drop(second, error: .transport)
        try authenticateSavedSlot(XCTUnwrap(focus.connect(.one, route: .wifi)), in: focus)
        XCTAssertEqual(focus.model.selected, .two)
        XCTAssertNil(focus.binding)
        XCTAssertNil(focus.outputLease)
        XCTAssertEqual(focus.model.offeredAlternate, .one)
        let target = try XCTUnwrap(PairPanelModel.tapTarget(focus.model, scene: "scene"))
        XCTAssertEqual(target, .one)
        focus.select(target, scene: "scene")
        let live = try XCTUnwrap(focus.binding)
        XCTAssertEqual(live.ticket.ordinal, .one)
        XCTAssertNil(focus.outputLease)
        focus.presented(live)
        XCTAssertTrue(focus.ownsOutput(live.ticket))
    }

    @MainActor func testLateJoinParksAndFencesClipboardAndFileActions() async throws {
        let focus = try restoredPair(selected: .one)
        defer { focus.endPair(scene: "scene"); focus.primary.stopForTesting(); focus.secondary.stopForTesting() }
        focus.claimSurface("scene")
        try authenticateSavedSlot(XCTUnwrap(focus.connect(.one, route: .wifi)), in: focus)
        let live = try XCTUnwrap(focus.binding)
        focus.presented(live)
        let late = focus.secondary
        late.controlSendForAudioTesting = { _, done in done(nil) }
        let owner = late.beginRemoteClipboardForTesting(remoteFiles: true)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !late.isRemoteControlSession && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(late.isRemoteControlSession)
        late.setRemoteClipboardSceneActive(true)
        let oldScope = late.transferActionScope
        let second = try XCTUnwrap(focus.connect(.two, route: .wifi))
        XCTAssertTrue(focus.authenticate(second, transport: owner.generation, peer: try XCTUnwrap(focus.model[.two].peer)))
        XCTAssertEqual(focus.model[.two].phase, .parked)
        XCTAssertEqual(focus.model.selected, .one)
        XCTAssertEqual(focus.binding, live)
        XCTAssertTrue(focus.ownsOutput(live.ticket))
        XCTAssertFalse(late.clipboardSceneActiveForTesting)
        XCTAssertGreaterThan(late.transferActionScope.fileEpoch, oldScope.fileEpoch)
    }

    @MainActor func testUnnegotiatedParkDropsVideoBeforeDecodeAndSingleSlotKeepsOriginalAdmission() throws {
        let primary = NetworkManager(role: .secondaryRemote)
        let focus = FocusCoordinator.forTesting(primary: primary)
        XCTAssertFalse(primary.focusManaged)
        XCTAssertTrue(primary.acceptsFocusInput(nil))
        for manager in [primary, focus.secondary] { manager.controlSendForAudioTesting = { _, done in done(nil) } }
        defer { primary.stopForTesting(); focus.secondary.stopForTesting() }
        _ = primary.beginRemoteClipboardForTesting()
        let oldHost = focus.secondary.beginRemoteClipboardForTesting()
        let first = try XCTUnwrap(focus.connect(.one, route: .wifi))
        XCTAssertTrue(focus.authenticate(first, transport: focus.primary.remoteKeyboardGeneration, peer: try XCTUnwrap(TrustedPeerReference(String(repeating: "3", count: 64)))))
        XCTAssertTrue(primary.focusManaged)
        let second = try XCTUnwrap(focus.connect(.two, route: .wifi))
        XCTAssertTrue(focus.authenticate(second, transport: focus.secondary.remoteKeyboardGeneration, peer: try XCTUnwrap(TrustedPeerReference(String(repeating: "4", count: 64)))))
        var decoded = [UInt32]()
        focus.secondary.captureTargetDecodeForTesting = { _, sequence, _ in decoded.append(sequence) }
        func sendVideo(_ sequence: UInt32) {
            focus.secondary.receiveCaptureTargetWireForTesting(type: .video, payload: Data([0,0,0,2,38,1]),
                flags: WireProtocol.videoFlagIDR | WireProtocol.videoFlagLengthPrefixed, sequence: sequence,
                generation: oldHost.generation, connection: oldHost.connection)
        }
        sendVideo(1)
        XCTAssertTrue(decoded.isEmpty)
        XCTAssertNil(focus.thumbnail(for: .two))
        focus.claimSurface("scene")
        focus.presented(try XCTUnwrap(focus.binding))
        focus.select(.two, scene: "scene")
        sendVideo(2)
        XCTAssertEqual(decoded, [2])
    }
}
#endif
