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
        await drain(network)
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
    #endif
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
