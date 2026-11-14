import XCTest
@testable import iPadCasting

final class RemoteMonitorIntegrationTests: XCTestCase {
    #if targetEnvironment(simulator)
    @MainActor private func drain(_ network: NetworkManager) async {
        network.networkQueueForTesting.sync {}
        let done = expectation(description: "monitor publication")
        DispatchQueue.main.async { done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        network.networkQueueForTesting.sync {}
    }
    @MainActor func testActualRemoteCatalogueAndTapSend68And70Never56() async throws {
        let network = NetworkManager(); var writes: [Data] = []
        network.controlSendForAudioTesting = { bytes, done in writes.append(bytes); done(nil) }
        let connection = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }
        network.beginTransferWriterForTesting()
        network.beginRemoteMonitorForTesting(acceptedFeatures: 7)
        await drain(network)
        XCTAssertEqual(writes.filter { $0[5] == 68 }.count, 1)
        let catalogue = RemoteMonitorStateTests.catalogue()
        network.receiveMirrorWireForTesting(type: .remoteMonitorCatalogue, payload: try XCTUnwrap(catalogue.encode()),
            generation: connection.generation, connection: connection.connection)
        network.receiveRemoteMonitorContextForTesting(RemoteMonitorStateTests.context(), keyframe: true)
        await drain(network)
        let input = bindMonitorInput(network)
        network.requestRemoteMonitor(2, catalogue: catalogue)
        await drain(network)
        let packet = try XCTUnwrap(writes.first { $0[5] == 70 })
        let request = try XCTUnwrap(RemoteMonitorSelectCommand.decode(Data(packet.dropFirst(16))))
        XCTAssertEqual(Array(packet.prefix(8)), [0x53, 0x43, 0x53, 0x54, 1, 70, 0, 0])
        XCTAssertEqual(packet.loadLittleEndian(UInt32.self, at: 8), 40)
        XCTAssertEqual(packet.loadLittleEndian(UInt32.self, at: 12), 0)
        XCTAssertEqual(request.targetId, 2); XCTAssertNotNil(network.remoteMonitorState.pending)
        XCTAssertFalse(writes.contains { $0[5] == 56 })
        let stale = RemoteMonitorSelectResultCommand(status: 1, requestId: request.requestId, epoch: 9, catalogueRevision: 4, currentId: 1)
        network.receiveMirrorWireForTesting(type: .remoteMonitorSelectResult, payload: try XCTUnwrap(stale.encode()),
            generation: connection.generation, connection: connection.connection)
        await drain(network)
        XCTAssertEqual(network.remoteMonitorState.issue, .stale)
        XCTAssertEqual(writes.filter { $0[5] == 68 }.count, 2)
        XCTAssertEqual(RemoteMonitorCatalogueRequest.decode(Data(try XCTUnwrap(writes.last { $0[5] == 68 }).dropFirst(16)))?.knownRevision, 0)
        _ = input
    }
    @MainActor func testActualOldHostNeverReceivesMonitorCommandsAndResetClearsPicker() async throws {
        let network = NetworkManager(); var writes: [Data] = []
        network.controlSendForAudioTesting = { bytes, done in writes.append(bytes); done(nil) }
        _ = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        network.beginTransferWriterForTesting()
        network.beginRemoteMonitorForTesting(acceptedFeatures: 3)
        await drain(network)
        network.refreshRemoteScreens(); network.requestRemoteMonitor(2, catalogue: RemoteMonitorStateTests.catalogue())
        await drain(network)
        XCTAssertFalse(network.remoteMonitorState.enabled)
        XCTAssertFalse(writes.contains { $0[5] == 68 || $0[5] == 70 })
        network.beginRemoteMonitorForTesting(acceptedFeatures: 7)
        await drain(network); XCTAssertTrue(network.remoteMonitorState.enabled)
        network.stopForTesting(); await drain(network)
        XCTAssertFalse(network.remoteMonitorState.enabled); XCTAssertNil(network.remoteMonitorState.catalogue)
        XCTAssertNil(network.remoteMonitorState.pending)
    }
    @MainActor private func bindMonitorInput(_ network: NetworkManager, ready: Bool = true, active: Bool = true) -> RemoteSessionInputState {
        let input = RemoteSessionInputState(); input.bind(network)
        input.configure(RemoteSessionInputConfiguration(remote: true, connected: true, active: active,
            generation: network.remoteKeyboardGeneration, features: 7, context: network.remoteInputContext,
            ready: ready, revision: network.remoteInputRevision))
        return input
    }
    @MainActor func testActualMonitorAdmissionWaitsForSharedInputAndReopens() async throws {
        let network = NetworkManager(); var writes: [Data] = []
        network.controlSendForAudioTesting = { bytes, done in writes.append(bytes); done(nil) }
        let owner = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }; network.beginTransferWriterForTesting()
        network.beginRemoteMonitorForTesting(acceptedFeatures: 7)
        let catalogue = RemoteMonitorStateTests.catalogue()
        network.receiveMirrorWireForTesting(type: .remoteMonitorCatalogue, payload: try XCTUnwrap(catalogue.encode()),
            generation: owner.generation, connection: owner.connection)
        network.receiveRemoteMonitorContextForTesting(RemoteMonitorStateTests.context(), keyframe: false)
        await drain(network)
        let input = bindMonitorInput(network, ready: false)
        network.requestRemoteMonitor(2, catalogue: catalogue); await drain(network)
        XCTAssertFalse(writes.contains { $0[5] == 70 })
        network.receiveRemoteMonitorContextForTesting(RemoteMonitorStateTests.context(), keyframe: true)
        await drain(network)
        input.configure(RemoteSessionInputConfiguration(remote: true, connected: true, active: true,
            generation: owner.generation, features: 7, context: network.remoteInputContext,
            ready: network.remoteInputReady, revision: network.remoteInputRevision))
        network.requestRemoteMonitor(2, catalogue: catalogue); await drain(network)
        XCTAssertEqual(writes.filter { $0[5] == 70 }.count, 1)
    }
    @MainActor func testFinalWriterRejectsRawSelectionWithoutAdmission() async throws {
        let network = NetworkManager(); var writes: [Data] = []
        network.controlSendForAudioTesting = { bytes, done in writes.append(bytes); done(nil) }
        let owner = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }; network.beginTransferWriterForTesting()
        network.beginRemoteMonitorForTesting(acceptedFeatures: 7)
        let catalogue = RemoteMonitorStateTests.catalogue()
        network.receiveMirrorWireForTesting(type: .remoteMonitorCatalogue, payload: try XCTUnwrap(catalogue.encode()),
            generation: owner.generation, connection: owner.connection)
        network.receiveRemoteMonitorContextForTesting(RemoteMonitorStateTests.context(), keyframe: true)
        await drain(network)
        let input = bindMonitorInput(network)
        network.bypassRemoteMonitorAdmissionForTesting(target: 2, catalogue: catalogue)
        await drain(network)
        XCTAssertFalse(writes.contains { $0[5] == 70 }); XCTAssertNil(network.remoteMonitorState.pending)
        _ = input
    }
    @MainActor func testQueuedSelectionRejectsRetiredControlAndReplacedContext() async throws {
        for change in 0..<3 {
            let network = NetworkManager(); var writes: [Data] = []; var release: (() -> Void)?
            network.controlSendForAudioTesting = { bytes, done in
                if bytes[5] == 6 { release = { done(nil) } }
                else { writes.append(bytes); done(nil) }
            }
            let owner = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
            network.beginTransferWriterForTesting(); network.beginRemoteMonitorForTesting(acceptedFeatures: 7)
            let catalogue = RemoteMonitorStateTests.catalogue()
            network.receiveMirrorWireForTesting(type: .remoteMonitorCatalogue, payload: try XCTUnwrap(catalogue.encode()),
                generation: owner.generation, connection: owner.connection)
            network.receiveRemoteMonitorContextForTesting(RemoteMonitorStateTests.context(), keyframe: true)
            await drain(network)
            let input = bindMonitorInput(network)
            network.enqueueTransferWireForTesting(bulk: false) { _ in }
            await drain(network); XCTAssertNotNil(release)
            network.requestRemoteMonitor(2, catalogue: catalogue); await drain(network)
            XCTAssertNotNil(network.remoteMonitorState.pending)
            if change == 0 {
                input.configure(RemoteSessionInputConfiguration(remote: true, connected: true, active: false,
                    generation: owner.generation, features: 7, context: network.remoteInputContext,
                    ready: true, revision: network.remoteInputRevision))
            } else {
                let context = change == 1
                    ? RemoteInputContextCommand(state: 0, desktop: 1, token: 0, desktopEpoch: 9, left: 0, top: 0, width: 0, height: 0)
                    : RemoteMonitorStateTests.context()
                network.receiveRemoteMonitorContextForTesting(context, keyframe: change == 2)
            }
            if let release { network.networkQueueForTesting.sync { release() } }
            await drain(network)
            XCTAssertFalse(writes.contains { $0[5] == 70 }); XCTAssertNil(network.remoteMonitorState.pending)
            network.stopForTesting()
        }
    }
    @MainActor func testRecoveryFinalWriterUsesSameAdmissionTable() async throws {
        let cases: [(current: UInt64, entries: Bool, paused: Bool, keyframe: Bool, control: Bool, allowed: Bool)] = [
            (0, true, true, false, true, true),
            (0, true, true, false, false, false),
            (0, false, true, false, true, false),
            (1, true, true, false, true, false),
            (1, true, false, false, true, false),
            (1, true, false, true, true, true)]
        for value in cases {
            let network = NetworkManager(); var writes: [Data] = []
            network.controlSendForAudioTesting = { bytes, done in writes.append(bytes); done(nil) }
            let owner = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
            network.beginTransferWriterForTesting(); network.beginRemoteMonitorForTesting(acceptedFeatures: 7)
            let catalogue = value.current == 0
                ? RemoteMonitorStateTests.recoveryCatalogue(entries: value.entries ? [RemoteMonitorStateTests.entries[1]] : [])
                : RemoteMonitorStateTests.catalogue()
            network.receiveMirrorWireForTesting(type: .remoteMonitorCatalogue, payload: try XCTUnwrap(catalogue.encode()),
                generation: owner.generation, connection: owner.connection)
            network.receiveRemoteMonitorContextForTesting(value.paused ? RemoteMonitorStateTests.pausedContext() : RemoteMonitorStateTests.context(), keyframe: value.keyframe)
            await drain(network)
            let input = bindMonitorInput(network, ready: value.keyframe, active: value.control)
            network.requestRemoteMonitor(2, catalogue: catalogue); await drain(network)
            XCTAssertEqual(writes.filter { $0[5] == 70 }.count, value.allowed ? 1 : 0)
            if value.allowed {
                let packet = try XCTUnwrap(writes.first { $0[5] == 70 })
                XCTAssertEqual(RemoteMonitorSelectCommand.decode(Data(packet.dropFirst(16)))?.targetId, 2)
                network.requestRemoteMonitor(2, catalogue: catalogue); await drain(network)
                XCTAssertEqual(writes.filter { $0[5] == 70 }.count, 1, "pending is still busy")
            }
            _ = input; network.stopForTesting()
        }
    }
    @MainActor func testQueuedRecoveryFinalWriterRejectsPermissionLoss() async throws {
        let network = NetworkManager(); var writes: [Data] = []; var release: (() -> Void)?
        network.controlSendForAudioTesting = { bytes, done in
            if bytes[5] == 6 { release = { done(nil) } }
            else { writes.append(bytes); done(nil) }
        }
        let owner = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }; network.beginTransferWriterForTesting()
        network.beginRemoteMonitorForTesting(acceptedFeatures: 7)
        let catalogue = RemoteMonitorStateTests.recoveryCatalogue()
        network.receiveMirrorWireForTesting(type: .remoteMonitorCatalogue, payload: try XCTUnwrap(catalogue.encode()),
            generation: owner.generation, connection: owner.connection)
        network.receiveRemoteMonitorContextForTesting(RemoteMonitorStateTests.pausedContext(), keyframe: false)
        await drain(network); let input = bindMonitorInput(network, ready: false)
        network.enqueueTransferWireForTesting(bulk: false) { _ in }; await drain(network)
        network.requestRemoteMonitor(2, catalogue: catalogue); await drain(network)
        XCTAssertNotNil(network.remoteMonitorState.pending)
        input.configure(RemoteSessionInputConfiguration(remote: true, connected: true, active: false,
            generation: owner.generation, features: 7, context: network.remoteInputContext, ready: false, revision: network.remoteInputRevision))
        let complete = try XCTUnwrap(release); network.networkQueueForTesting.sync { complete() }; await drain(network)
        XCTAssertFalse(writes.contains { $0[5] == 70 }); XCTAssertNil(network.remoteMonitorState.pending)
    }
    @MainActor func testRecoveryAppliedWriterWaitsForNormalKeyframeGate() async throws {
        let network = NetworkManager(); var writes: [Data] = []
        network.controlSendForAudioTesting = { bytes, done in writes.append(bytes); done(nil) }
        let owner = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }; network.beginTransferWriterForTesting()
        network.beginRemoteMonitorForTesting(acceptedFeatures: 7)
        let third = RemoteMonitorEntry(id: 3, left: 2560, top: 0, width: 800, height: 600, flags: 0, name: "Panel C")
        let entries = [RemoteMonitorStateTests.entries[1], third], catalogue = RemoteMonitorStateTests.recoveryCatalogue(entries: [RemoteMonitorStateTests.entries[1], third])
        network.receiveMirrorWireForTesting(type: .remoteMonitorCatalogue, payload: try XCTUnwrap(catalogue.encode()),
            generation: owner.generation, connection: owner.connection)
        network.receiveRemoteMonitorContextForTesting(RemoteMonitorStateTests.pausedContext(), keyframe: false)
        await drain(network); let input = bindMonitorInput(network, ready: false)
        network.requestRemoteMonitor(2, catalogue: catalogue); await drain(network)
        let first = try XCTUnwrap(writes.first { $0[5] == 70 })
        let request = try XCTUnwrap(RemoteMonitorSelectCommand.decode(Data(first.dropFirst(16))))
        let applied = RemoteMonitorSelectResultCommand(status: 0, requestId: request.requestId, epoch: 10, catalogueRevision: 5, currentId: 2)
        network.receiveMirrorWireForTesting(type: .remoteMonitorSelectResult, payload: try XCTUnwrap(applied.encode()),
            generation: owner.generation, connection: owner.connection)
        let next = RemoteMonitorCatalogueCommand(desktop: 1, state: 1, epoch: 10, revision: 5, currentId: 2, entries: entries)
        network.receiveMirrorWireForTesting(type: .remoteMonitorCatalogue, payload: try XCTUnwrap(next.encode()),
            generation: owner.generation, connection: owner.connection)
        network.receiveRemoteMonitorContextForTesting(RemoteMonitorStateTests.context(epoch: 10, target: 1), keyframe: false)
        await drain(network)
        input.configure(RemoteSessionInputConfiguration(remote: true, connected: true, active: true,
            generation: owner.generation, features: 7, context: network.remoteInputContext, ready: false, revision: network.remoteInputRevision))
        network.requestRemoteMonitor(3, catalogue: next); await drain(network)
        XCTAssertEqual(writes.filter { $0[5] == 70 }.count, 1)
        network.receiveRemoteMonitorContextForTesting(RemoteMonitorStateTests.context(epoch: 10, target: 1), keyframe: true)
        await drain(network)
        input.configure(RemoteSessionInputConfiguration(remote: true, connected: true, active: true,
            generation: owner.generation, features: 7, context: network.remoteInputContext, ready: true, revision: network.remoteInputRevision))
        network.requestRemoteMonitor(3, catalogue: next); await drain(network)
        XCTAssertEqual(writes.filter { $0[5] == 70 }.count, 2)
    }
    #endif
    @MainActor func testRecoveryControlPermissionIsIndependentOfContextReadiness() {
        let input = RemoteSessionInputState()
        for (features, active, allowed) in [(UInt64(7), true, true), (UInt64(3), true, false), (UInt64(7), false, false)] {
            input.configure(RemoteSessionInputConfiguration(remote: true, connected: true, active: active,
                generation: 7, features: features, context: RemoteMonitorStateTests.pausedContext(), ready: false, revision: 1))
            XCTAssertFalse(input.pointerEnabled); XCTAssertEqual(input.monitorControlAvailable, allowed)
        }
    }
    func testProductionRoutingAndRetirementAreConnectionScoped() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("iPadZeroLagDisplay/NetworkManager.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("RemoteFeatureNegotiation(requestedFeatures: 7)"))
        XCTAssertTrue(source.contains("remoteMonitors.begin(session: UUID(), acceptedFeatures:"))
        XCTAssertTrue(source.contains("remoteMonitors.session == session"))
        XCTAssertTrue(source.contains("case .remoteMonitorCatalogueRequest:"))
        XCTAssertTrue(source.contains("case .remoteMonitorSelectRequest:"))
        let panel = try String(contentsOf: root.appendingPathComponent("iPadZeroLagDisplay/SessionPanelOverlay.swift"), encoding: .utf8)
        XCTAssertTrue(panel.contains("ScreenPickerSnapshot.shouldShowPicker"))
        XCTAssertTrue(panel.contains("networkManager.requestRemoteMonitor(tile.id, catalogue: catalogue)"))
        XCTAssertTrue(panel.contains("networkManager.requestMirrorMonitor(tile.id, catalogue: catalogue)"))
    }
}
