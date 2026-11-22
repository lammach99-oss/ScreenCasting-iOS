import XCTest
import Network
import UIKit
@testable import iPadCasting

final class CaptureTargetIntegrationTests: XCTestCase {
    static let modes = CaptureTargetProtocolTests.bytes("0102000054090000840600007800000054090000840600003c000000" +
        "000000000000000000000000000000000000000000000000")
    static func catalogue(revision: UInt64, current: UInt64, epoch: UInt64 = 5, allowed: Bool = true,
                          virtualId: UInt64 = 1, physicalId: UInt64 = 4) -> Data {
        var bytes=[UInt8](repeating: 0, count: 40);bytes[0]=1;bytes[1]=1;bytes[2]=allowed ? 1 : 0;bytes[3]=2
        MirrorControlCodec.put(30000, &bytes, 4, 4);MirrorControlCodec.put(2, &bytes, 8, 8)
        MirrorControlCodec.put(revision, &bytes, 16, 8);MirrorControlCodec.put(current, &bytes, 24, 8)
        MirrorControlCodec.put(epoch, &bytes, 32, 8)
        for (id, kind, name) in [(virtualId, UInt8(0), "Extend iPad"), (physicalId, UInt8(1), "Panel")] {
            var row=[UInt8](repeating: 0, count: 12)
            MirrorControlCodec.put(id, &row, 0, 8);row[8]=kind
            MirrorControlCodec.put(UInt64(name.utf8.count), &row, 10, 2);bytes += row+Array(name.utf8)
        }
        return Data(bytes)
    }
    static func result(status: UInt8 = 0, kind: UInt8 = 0, transaction: UInt64 = 1,
                       revision: UInt64 = 4, current: UInt64 = 11,
                       retiringEpoch: UInt64 = 0, retiringSource: UInt64 = 0,
                       firstFrame: UInt32 = 0, source: UInt64 = 6) -> Data {
        var bytes=[UInt8](repeating: 0, count: 64);bytes[0]=1;bytes[1]=status
        bytes[2]=status == 9 ? 2 : 1;bytes[3]=status == 9 ? 255 : kind
        for (offset, value) in [(8, transaction), (16, UInt64(2)), (24, revision),
                                (32, status == 9 ? UInt64(0) : current),
                                 (40, status == 9 ? retiringEpoch : 5), (48, status == 9 ? retiringSource : source)] {
            MirrorControlCodec.put(value, &bytes, offset, 8)
        }
        MirrorControlCodec.put(UInt64(firstFrame), &bytes, 56, 4)
        return Data(bytes)
    }
    static func mode(revision: UInt64, epoch: UInt64, physical: Bool, active: Bool = false) throws -> Data {
        let geometry=MirrorGeometry(left: -1920, top: 0, width: 1920, height: 1080, frameWidth: 2388, frameHeight: 1668)
        return try MirrorControlCodec.encodeState(MirrorControlState(revision: revision, epoch: epoch,
            source: physical ? 6 : 0, mode: physical ? (active ? .active : .viewOnly) : .virtualDisplay,
            token: MirrorToken(low: active ? 7 : 0, high: active ? 8 : 0), geometry: physical ? geometry : nil,
            firstFrame: physical ? 0 : nil, lastSent: physical ? 10 : nil))
    }

    #if targetEnvironment(simulator)
    @MainActor private func drain(_ network: NetworkManager) async {
        for _ in 0..<4 {
            network.networkQueueForTesting.sync {}
            let done=expectation(description: "typed source publication")
            DispatchQueue.main.async { done.fulfill() };await fulfillment(of: [done], timeout: 2)
        }
        network.networkQueueForTesting.sync {}
    }

    @MainActor func testAcceptedFailureRecoversRestoredSourceWithFreshDecoderAndIDR() async throws {
        for physical in [false, true] {
            let network = NetworkManager()
            var writes: [Data] = [], decoded: [(UInt32, UInt64)] = []
            network.controlSendForAudioTesting = { bytes, done in writes.append(bytes); done(nil) }
            network.captureTargetDecodeForTesting = { _, sequence, generation in decoded.append((sequence, generation)) }
            var terminalTimers: [(TimeInterval, () -> Void)] = []
            network.captureTargetScheduleForTesting = { seconds, callback in
                if seconds >= 60 { terminalTimers.append((seconds, callback)) }
            }
            let peer = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
            defer { network.stopForTesting() }
            network.beginTransferWriterForTesting()
            func receive(_ type: WireMessageType, _ payload: Data, flags: UInt16 = 0, sequence: UInt32 = 0) {
                network.receiveCaptureTargetWireForTesting(type: type, payload: payload, flags: flags,
                    sequence: sequence, generation: peer.generation, connection: peer.connection)
            }
            receive(.displayCapabilities, Self.modes, flags: 0x7c00)
            receive(.mirrorState, try Self.mode(revision: 1, epoch: 4, physical: physical))
            receive(.sourceCatalogue, Self.catalogue(revision: 3, current: physical ? 4 : 1, epoch: 4))
            await drain(network)
            let oldDecoder = network.decoderForTesting.currentSessionGeneration
            network.requestCaptureTarget(physical ? 1 : 4, catalogue: try XCTUnwrap(network.captureTargetState.catalogue))
            await drain(network)
            let source = physical ? UInt64(6) : UInt64.max
            receive(.sourceSwitchResult, Self.result(status: 9, revision: 3, current: 0, retiringEpoch: 4, retiringSource: source))
            XCTAssertEqual(terminalTimers.count, 2)
            XCTAssertGreaterThan(try XCTUnwrap(terminalTimers.last?.0), 70)
            let admissionDeadline = try XCTUnwrap(terminalTimers.first?.1)
            network.networkQueueForTesting.sync { admissionDeadline() }
            await drain(network)
            XCTAssertTrue(network.captureTargetState.pending?.accepted == true)
            receive(.video, Data([1]), flags: 3, sequence: 10)
            receive(.sourceCatalogue, Self.catalogue(revision: 4, current: physical ? 14 : 11, virtualId: 11, physicalId: 14))
            let terminal = Self.result(status: 4, kind: physical ? 1 : 0, current: physical ? 14 : 11,
                                       firstFrame: 12, source: source)
            receive(.sourceSwitchResult, terminal)
            receive(.mirrorState, try Self.mode(revision: 2, epoch: 5, physical: physical))
            receive(.video, Data([1]), flags: 2, sequence: 11)
            XCTAssertTrue(decoded.isEmpty, "The candidate decoder chain belongs to an unconfirmed source")
            receive(.video, Data([1]), flags: 3, sequence: 12)
            await drain(network)
            let recovery = try XCTUnwrap(writes.first {
                $0[5] == WireMessageType.videoFeedback.rawValue &&
                    $0.loadLittleEndian(UInt16.self, at: 6) == CaptureTargetProtocol.recoveryFlag
            })
            XCTAssertEqual(recovery.count, 40)
            XCTAssertEqual(recovery.loadLittleEndian(UInt64.self, at: 16), 2)
            XCTAssertEqual(recovery.loadLittleEndian(UInt64.self, at: 24), 5)
            XCTAssertEqual(recovery.loadLittleEndian(UInt64.self, at: 32), source)
            XCTAssertEqual(decoded.map { $0.0 }, [12])
            let restoredDecoder = try XCTUnwrap(decoded.first?.1)
            XCTAssertNotEqual(restoredDecoder, oldDecoder)
            network.recordRenderCompletion(sequence: 12, generation: oldDecoder)
            await drain(network)
            XCTAssertTrue(network.captureTargetState.inputBlocked)
            network.recordRenderCompletion(sequence: 12, generation: restoredDecoder)
            await drain(network)
            XCTAssertFalse(network.captureTargetState.inputBlocked)
            XCTAssertEqual(network.captureTargetState.issue, .failed)
        }
    }

    @MainActor func testAcceptedFailureWithoutRetiringStampCannotAuthorizeBufferedMedia() async throws {
        let network = NetworkManager()
        var decoded: [UInt32] = []
        network.controlSendForAudioTesting = { _, done in done(nil) }
        network.captureTargetDecodeForTesting = { _, sequence, _ in decoded.append(sequence) }
        network.captureTargetScheduleForTesting = { _, _ in }
        let peer = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }
        network.beginTransferWriterForTesting()
        func receive(_ type: WireMessageType, _ bytes: Data, flags: UInt16 = 0) {
            network.receiveCaptureTargetWireForTesting(type: type, payload: bytes, flags: flags,
                generation: peer.generation, connection: peer.connection)
        }
        receive(.displayCapabilities, Self.modes, flags: 0x7c00)
        receive(.mirrorState, try Self.mode(revision: 1, epoch: 4, physical: false))
        receive(.sourceCatalogue, Self.catalogue(revision: 3, current: 1, epoch: 4))
        await drain(network)
        network.requestCaptureTarget(4, catalogue: try XCTUnwrap(network.captureTargetState.catalogue))
        await drain(network)
        receive(.sourceSwitchResult, Self.result(status: 9, revision: 3, current: 0))
        receive(.sourceCatalogue, Self.catalogue(revision: 4, current: 11, virtualId: 11, physicalId: 14))
        receive(.sourceSwitchResult, Self.result(status: 4))
        receive(.mirrorState, try Self.mode(revision: 2, epoch: 5, physical: false))
        receive(.video, Data([1]), flags: 3)
        await drain(network)
        XCTAssertTrue(decoded.isEmpty)
        XCTAssertNil(network.captureTargetState.applied)
        XCTAssertTrue(network.captureTargetState.inputBlocked)
        XCTAssertEqual(network.captureTargetState.issue, .failed)
    }

    @MainActor func testAcceptedRollbackUsesWrappedHostAnchorAndMatchingPhysicalIdentity() async throws {
        let network = NetworkManager()
        var decoded: [(UInt32, UInt64)] = []
        network.controlSendForAudioTesting = { _, done in done(nil) }
        network.captureTargetDecodeForTesting = { _, sequence, generation in decoded.append((sequence, generation)) }
        network.captureTargetScheduleForTesting = { _, _ in }
        let peer = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.wifiRTP)
        defer { network.stopForTesting() }
        network.beginTransferWriterForTesting()
        func receive(_ type: WireMessageType, _ payload: Data, flags: UInt16 = 0) {
            network.receiveCaptureTargetWireForTesting(type: type, payload: payload, flags: flags,
                generation: peer.generation, connection: peer.connection)
        }
        func idr(_ sequence: UInt32) {
            network.receiveCaptureTargetVideoForTesting(Data([1]), sequence: sequence, isIDR: true,
                generation: peer.generation, connection: peer.connection)
        }
        receive(.displayCapabilities, Self.modes, flags: 0x7c00)
        receive(.mirrorState, try Self.mode(revision: 1, epoch: 4, physical: true))
        receive(.sourceCatalogue, Self.catalogue(revision: 3, current: 4, epoch: 4))
        await drain(network)
        network.requestCaptureTarget(1, catalogue: try XCTUnwrap(network.captureTargetState.catalogue))
        await drain(network)
        receive(.sourceSwitchResult, Self.result(status: 9, revision: 3, current: 0, retiringEpoch: 4, retiringSource: 6))
        receive(.sourceCatalogue, Self.catalogue(revision: 4, current: 14, virtualId: 11, physicalId: 14))
        idr(UInt32.max)
        receive(.sourceSwitchResult, Self.result(status: 7, kind: 1, current: 14))
        XCTAssertTrue(decoded.isEmpty, "The restore must wait for physical source metadata")
        receive(.mirrorState, try Self.mode(revision: 2, epoch: 5, physical: true))
        XCTAssertTrue(decoded.isEmpty, "The buffered frame predates the wrapped restore anchor")
        idr(0)
        await drain(network)
        XCTAssertEqual(decoded.map { $0.0 }, [0])
        network.recordRenderCompletion(sequence: 0, generation: try XCTUnwrap(decoded.first?.1))
        await drain(network)
        XCTAssertFalse(network.captureTargetState.inputBlocked)
        XCTAssertEqual(network.captureTargetState.issue, .timedOut)
        XCTAssertEqual(network.captureTargetState.confirmedCurrentId, 14)
    }

    @MainActor func testDisplayChangeWaitsForSuccessfulSourcePresentation() async throws {
        let network = NetworkManager()
        network.useAutomaticOrientationForTesting()
        var writes: [Data] = []
        network.controlSendForAudioTesting = { bytes, done in writes.append(bytes); done(nil) }
        network.captureTargetScheduleForTesting = { _, _ in }
        network.captureTargetDecodeForTesting = { _, _, _ in }
        let peer = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }
        network.beginTransferWriterForTesting()
        func receive(_ type: WireMessageType, _ payload: Data, flags: UInt16 = 0) {
            network.receiveCaptureTargetWireForTesting(type: type, payload: payload, flags: flags,
                generation: peer.generation, connection: peer.connection)
        }
        receive(.displayCapabilities, Self.modes, flags: 0x7c00)
        receive(.mirrorState, try Self.mode(revision: 1, epoch: 2, physical: false))
        receive(.sourceCatalogue, Self.catalogue(revision: 3, current: 1))
        await drain(network)
        network.requestCaptureTarget(4, catalogue: try XCTUnwrap(network.captureTargetState.catalogue))
        await drain(network)
        receive(.sourceSwitchResult, Self.result(status: 9, revision: 3, current: 0))
        network.updateInterfaceOrientation(.landscape)
        network.updateInterfaceOrientation(.portrait)
        network.runOrientationDebounceForTesting()
        await drain(network)
        XCTAssertTrue(network.captureTargetState.pending?.accepted == true)
        XCTAssertFalse(writes.contains { $0[5] == WireMessageType.displayConfigurationRequest.rawValue })
        receive(.sourceCatalogue, Self.catalogue(revision: 4, current: 14, virtualId: 11, physicalId: 14))
        receive(.mirrorState, try Self.mode(revision: 2, epoch: 5, physical: true))
        receive(.sourceSwitchResult, Self.result(kind: 1, current: 14))
        receive(.video, Data([1]), flags: 3)
        let decoder = try XCTUnwrap(network.captureTargetDecoderForTesting)
        network.recordRenderCompletion(sequence: 0, generation: decoder)
        await drain(network)
        XCTAssertFalse(network.captureTargetState.unknownOutcome)
        XCTAssertEqual(network.captureTargetState.confirmedCurrentId, 14)
        let displayRequests = writes.filter { $0[5] == WireMessageType.displayConfigurationRequest.rawValue }
        XCTAssertEqual(displayRequests.count, 1)
        XCTAssertEqual(displayRequests.first?[17], ClientDisplayOrientation.portrait.rawValue)
    }

    @MainActor func testScreenPermissionCanBeRequestedAgainAfterNoApproval() async throws {
        let network = NetworkManager()
        var writes: [Data] = [], timers: [(TimeInterval, () -> Void)] = []
        network.controlSendForAudioTesting = { bytes, done in writes.append(bytes); done(nil) }
        network.captureTargetScheduleForTesting = { seconds, callback in timers.append((seconds, callback)) }
        let peer = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }
        network.beginTransferWriterForTesting()
        func receive(_ type: WireMessageType, _ payload: Data, flags: UInt16 = 0) {
            network.receiveCaptureTargetWireForTesting(type: type, payload: payload, flags: flags,
                generation: peer.generation, connection: peer.connection)
        }
        func actionIsAvailable() -> Bool {
            ScreenPickerSnapshot.make(captureTargets: network.captureTargetState, state: network.mirrorControlState,
                permissionAsked: network.screenSwitchPermissionPending).canAskPermission
        }
        receive(.displayCapabilities, Self.modes, flags: 0x7c00)
        receive(.mirrorState, try Self.mode(revision: 1, epoch: 2, physical: false))
        receive(.sourceCatalogue, Self.catalogue(revision: 3, current: 1, allowed: false))
        await drain(network)
        XCTAssertTrue(actionIsAvailable())
        network.requestMirrorSwitchPermission()
        await drain(network)
        XCTAssertFalse(actionIsAvailable())
        let expire = try XCTUnwrap(timers.last { $0.0 == 30 }?.1)
        network.networkQueueForTesting.sync { expire() }
        await drain(network)
        XCTAssertTrue(actionIsAvailable())
        XCTAssertEqual(network.screenSwitchPermissionNotice, "No answer from the PC")
        network.requestMirrorSwitchPermission()
        await drain(network)
        network.networkQueueForTesting.sync { expire() }
        await drain(network)
        XCTAssertTrue(network.screenSwitchPermissionPending)
        XCTAssertNil(network.screenSwitchPermissionNotice)
        let permissions = writes.filter { $0.count > 17 && $0[5] == WireMessageType.mirrorAction.rawValue && $0[17] == 8 }
        XCTAssertEqual(permissions.count, 2)
        receive(.sourceCatalogue, Self.catalogue(revision: 4, current: 11, virtualId: 11, physicalId: 14))
        await drain(network)
        XCTAssertFalse(network.screenSwitchPermissionPending)
        XCTAssertNil(network.screenSwitchPermissionNotice)
        XCTAssertFalse(actionIsAvailable(), "Approval makes the request action unnecessary")
    }

    @MainActor func testScreenAndRouteRequestsExcludeEachOtherBeforeHostAcknowledges() async throws {
        for screenFirst in [true, false] {
            let network = NetworkManager()
            var writes: [Data] = [], retirements = 0, panelRetirements = 0
            network.controlSendForAudioTesting = { bytes, done in writes.append(bytes); done(nil) }
            network.captureTargetRetireInput = { retirements += 1 }
            network.captureTargetScheduleForTesting = { _, _ in }
            let peer = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
            defer { network.stopForTesting() }
            network.beginTransferWriterForTesting()
            network.setConnectionIdentityForTesting(verified: true)
            network.seedRouteEndpointForTesting()
            func receive(_ type: WireMessageType, _ payload: Data, flags: UInt16 = 0) {
                network.receiveCaptureTargetWireForTesting(type: type, payload: payload, flags: flags,
                    generation: peer.generation, connection: peer.connection)
            }
            receive(.displayCapabilities, Self.modes, flags: 0x7e00)
            receive(.mirrorState, try Self.mode(revision: 1, epoch: 2, physical: false))
            receive(.sourceCatalogue, Self.catalogue(revision: 3, current: 1))
            receive(.connectionState, try ConnectionSwitchStateTests.snapshot(route: .usb).encode())
            await drain(network)
            let catalogue = try XCTUnwrap(network.captureTargetState.catalogue)
            if screenFirst {
                network.requestCaptureTarget(4, catalogue: catalogue)
                network.requestConnectionRoute(.wifi) { panelRetirements += 1 }
            } else {
                network.requestConnectionRoute(.wifi) { panelRetirements += 1 }
                network.requestCaptureTarget(4, catalogue: catalogue)
            }
            await drain(network)
            let requests = writes.map { $0[5] }.filter { [WireMessageType.sourceSwitchRequest.rawValue,
                WireMessageType.connectionSelectRequest.rawValue].contains($0) }
            XCTAssertEqual(requests, [screenFirst ? WireMessageType.sourceSwitchRequest.rawValue
                : WireMessageType.connectionSelectRequest.rawValue])
            XCTAssertEqual(retirements, 1)
            XCTAssertEqual(panelRetirements, screenFirst ? 0 : 1)
        }
    }
    @MainActor func testActualDiscoveryOldHostFallbackAndExtendPermissionGoldenBytes() async throws {
        for typed in [false, true] {
            let network=NetworkManager();var writes: [Data]=[]
            network.controlSendForAudioTesting={ bytes, done in writes.append(bytes);done(nil) }
            let peer=network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
            defer { network.stopForTesting() }
            network.beginTransferWriterForTesting()
            network.receiveCaptureTargetWireForTesting(type: .displayCapabilities, payload: Self.modes,
                flags: typed ? 0x7c00 : 0x7800, generation: peer.generation, connection: peer.connection)
            network.receiveCaptureTargetWireForTesting(type: .mirrorState,
                payload: try Self.mode(revision: 1, epoch: 5, physical: false), generation: peer.generation, connection: peer.connection)
            await drain(network)
            XCTAssertEqual(writes.first(where: { $0[5] == 51 }).map { Data($0.dropFirst(16)) }, Data([1,0,0,0,7,0,0,0]))
            XCTAssertEqual(writes.filter { $0[5] == 72 }.count, typed ? 1 : 0)
            network.refreshMirrorScreens();network.requestMirrorSwitchPermission();await drain(network)
            if typed {
                let ask=try XCTUnwrap(writes.first { $0[5] == 54 && $0[17] == 8 })
                XCTAssertEqual(Data(ask.dropFirst(16)), CaptureTargetProtocolTests.bytes(
                    "0108000005000000000000000000000000000000000000000000000000000000"))
            } else {
                XCTAssertFalse(writes.contains { (72...75).contains($0[5]) })
                XCTAssertFalse(ScreenPickerSnapshot.shouldShowPicker(remote: false, mirror: false, acceptedFeatures: 0))
            }
            let registration=network.mirrorInputRevision
            network.setMirrorInputForeground(false)
            XCTAssertEqual(network.legacyInputIsCurrent(revision: registration), !typed,
                "only typed sessions change legacy callback admission")
            network.setMirrorInputForeground(true)
        }
    }
    @MainActor func testActualAllSourceDirectionsRetireBeforeRequestAndBufferEitherModeOrderOnBothVideoPaths() async throws {
        for rtp in [false, true] {
            for (startsPhysical, targetPhysical) in [(false, true), (true, false), (true, true), (false, false)] {
                for metadataFirst in [false, true] {
                    let network=NetworkManager();var writes: [Data]=[], decoded: [(UInt32, UInt64)]=[], events: [String]=[]
                    network.controlSendForAudioTesting={ bytes, done in
                        if bytes[5] == 74 {
                            XCTAssertEqual(events.first, "retire");XCTAssertFalse(network.permitsLegacyVirtualInput)
                            XCTAssertNil(network.mirrorTicketAtRegistration);events.append("request")
                        }
                        writes.append(bytes);done(nil)
                    }
                    network.captureTargetDecodeForTesting={ _, sequence, generation in decoded.append((sequence, generation)) }
                    network.captureTargetScheduleForTesting={ _, _ in }
                    let peer=network.simulateCommittedWifiSessionForTesting(mode: rtp ? RealtimeTransportMode.wifiRTP : RealtimeTransportMode.legacyTLS)
                    defer { network.stopForTesting() }
                    network.beginTransferWriterForTesting()
                    func receive(_ type: WireMessageType, _ payload: Data, flags: UInt16 = 0, sequence: UInt32 = 0) {
                        network.receiveCaptureTargetWireForTesting(type: type, payload: payload, flags: flags, sequence: sequence,
                            generation: peer.generation, connection: peer.connection)
                    }
                    receive(.displayCapabilities, Self.modes, flags: 0x7c00)
                    receive(.mirrorState, try Self.mode(revision: 1, epoch: 2, physical: startsPhysical))
                    receive(.sourceCatalogue, Self.catalogue(revision: 3, current: startsPhysical ? 4 : 1))
                    await drain(network)
                    network.captureTargetRetireInput={ events.append("retire") }
                    let catalogue=try XCTUnwrap(network.captureTargetState.catalogue)
                    network.requestCaptureTarget(targetPhysical ? 4 : 1, catalogue: catalogue)
                    await drain(network);XCTAssertEqual(events, ["retire", "request"])
                    let request=try XCTUnwrap(writes.first { $0[5] == 74 })
                    XCTAssertEqual(request.count, 56);XCTAssertEqual(request[6], 0);XCTAssertEqual(request[7], 0)
                    XCTAssertFalse(writes.contains { $0[5] == 56 || $0[5] == 54 && ($0[17] == 3 || $0[17] == 5) })
                    receive(.sourceSwitchResult, Self.result(status: 9, revision: 3, current: 0))
                    func video(_ sequence: UInt32, idr: Bool) {
                        if rtp {
                            network.receiveCaptureTargetVideoForTesting(Data([1]), sequence: sequence, isIDR: idr,
                                generation: peer.generation, connection: peer.connection)
                        } else { receive(.video, Data([1]), flags: idr ? 3 : 2, sequence: sequence) }
                    }
                    video(0, idr: true);video(1, idr: false)
                    XCTAssertTrue(decoded.isEmpty, "pending encoded candidates cannot present")
                    receive(.sourceCatalogue, Self.catalogue(revision: 4, current: targetPhysical ? 14 : 11, virtualId: 11, physicalId: 14))
                    let mode=try Self.mode(revision: 2, epoch: targetPhysical ? 5 : 3, physical: targetPhysical)
                    if metadataFirst { receive(.mirrorState, mode) }
                    receive(.sourceSwitchResult, Self.result(kind: targetPhysical ? 1 : 0, current: targetPhysical ? 14 : 11))
                    if !metadataFirst { XCTAssertTrue(decoded.isEmpty);receive(.mirrorState, mode) }
                    await drain(network)
                    XCTAssertEqual(decoded.map { $0.0 }, [0, 1])
                    XCTAssertTrue(network.captureTargetState.inputBlocked)
                    let decoder=try XCTUnwrap(decoded.first?.1)
                    network.recordRenderCompletion(sequence: UInt32.max, generation: decoder);await drain(network)
                    XCTAssertTrue(network.captureTargetState.inputBlocked)
                    network.recordRenderCompletion(sequence: 0, generation: decoder);await drain(network)
                    XCTAssertFalse(network.captureTargetState.inputBlocked)
                    if targetPhysical {
                        XCTAssertFalse(network.permitsLegacyVirtualInput);XCTAssertNil(network.mirrorTicketAtRegistration)
                        receive(.mirrorState, try Self.mode(revision: 3, epoch: 5, physical: true, active: true));await drain(network)
                        XCTAssertNotNil(network.mirrorTicketAtRegistration)
                        XCTAssertTrue(writes.contains { $0[5] == 54 && $0[17] == 2 })
                    } else {
                        XCTAssertTrue(network.permitsLegacyVirtualInput)
                        XCTAssertFalse(writes.contains { $0[5] == 54 && $0[17] == 2 })
                    }
                    video(UInt32.max, idr: true);XCTAssertEqual(decoded.count, 2, "old sequence cannot enter new decoder")
                    if !rtp && !metadataFirst && !startsPhysical && !targetPhysical {
                        network.requestCaptureTarget(11, catalogue: try XCTUnwrap(network.captureTargetState.catalogue));await drain(network)
                        receive(.sourceSwitchResult, Self.result(status: 9, transaction: 2, revision: 4, current: 0))
                        receive(.sourceCatalogue, Self.catalogue(revision: 5, current: 21, virtualId: 21, physicalId: 24))
                        receive(.sourceCatalogue, Self.catalogue(revision: 6, current: 31, epoch: 6, virtualId: 31, physicalId: 34))
                        receive(.sourceSwitchResult, Self.result(transaction: 2, revision: 5, current: 21));await drain(network)
                        XCTAssertTrue(network.captureTargetState.unknownOutcome, "a newer publication already retired this Applied owner")
                        XCTAssertNil(network.captureTargetState.applied);XCTAssertTrue(network.captureTargetState.inputBlocked)
                        XCTAssertEqual(network.captureTargetState.catalogue?.revision, 6)
                    }
                }
            }
        }
    }
    @MainActor func testActualScopedReleaseReachesWireBeforeNextSourceRequest() async throws {
        let network=NetworkManager();var writes: [Data]=[]
        network.controlSendForAudioTesting={ bytes, done in writes.append(bytes);done(nil) }
        network.captureTargetScheduleForTesting={ _, _ in }
        network.captureTargetDecodeForTesting={ _, _, _ in }
        let peer=network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }
        network.beginTransferWriterForTesting()
        func receive(_ type: WireMessageType, _ payload: Data, flags: UInt16 = 0) {
            network.receiveCaptureTargetWireForTesting(type: type, payload: payload, flags: flags,
                generation: peer.generation, connection: peer.connection)
        }
        receive(.displayCapabilities, Self.modes, flags: 0x7c00)
        receive(.mirrorState, try Self.mode(revision: 1, epoch: 2, physical: false))
        receive(.sourceCatalogue, Self.catalogue(revision: 3, current: 1));await drain(network)
        network.requestCaptureTarget(4, catalogue: try XCTUnwrap(network.captureTargetState.catalogue));await drain(network)
        receive(.sourceSwitchResult, Self.result(status: 9, revision: 3, current: 0))
        receive(.sourceCatalogue, Self.catalogue(revision: 4, current: 14, virtualId: 11, physicalId: 14))
        receive(.mirrorState, try Self.mode(revision: 2, epoch: 5, physical: true))
        receive(.sourceSwitchResult, Self.result(kind: 1, current: 14))
        receive(.video, Data([1]), flags: 3);await drain(network)
        network.recordRenderCompletion(sequence: 0, generation: try XCTUnwrap(network.captureTargetDecoderForTesting));await drain(network)
        receive(.mirrorState, try Self.mode(revision: 3, epoch: 5, physical: true, active: true));await drain(network)
        let ticket=try XCTUnwrap(network.mirrorTicketAtRegistration)
        network.sendMirrorInput(ticket: ticket, kind: .keyboard, payload: KeyboardInputCommand(action: .keyDown, virtualKey: 65).encode())
        await drain(network);let start=writes.count
        network.captureTargetRetireInput={
            network.sendMirrorInput(ticket: ticket, kind: .keyboard, payload: KeyboardInputCommand(action: .keyUp, virtualKey: 65).encode())
        }
        network.requestCaptureTarget(11, catalogue: try XCTUnwrap(network.captureTargetState.catalogue));await drain(network)
        let terminal=Array(writes.dropFirst(start))
        let release=try XCTUnwrap(terminal.firstIndex { $0[5] == WireMessageType.mirrorInput.rawValue })
        let request=try XCTUnwrap(terminal.firstIndex { $0[5] == 74 })
        XCTAssertLessThan(release, request)
        XCTAssertEqual(KeyboardInputCommand.decode(Data(terminal[release].suffix(4)))?.action, .keyUp)
    }
    @MainActor func testActualScopedRecoveryDeadlineNeverOpensInputFromLateRender() async throws {
        let network=NetworkManager();var writes: [Data]=[], timers: [(TimeInterval, () -> Void)]=[]
        network.controlSendForAudioTesting={ bytes, done in writes.append(bytes);done(nil) }
        network.captureTargetScheduleForTesting={ seconds, callback in timers.append((seconds, callback)) }
        network.captureTargetDecodeForTesting={ _, _, _ in }
        let peer=network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }
        network.beginTransferWriterForTesting()
        func receive(_ type: WireMessageType, _ payload: Data, flags: UInt16 = 0) {
            network.receiveCaptureTargetWireForTesting(type: type, payload: payload, flags: flags,
                generation: peer.generation, connection: peer.connection)
        }
        receive(.displayCapabilities, Self.modes, flags: 0x7c00)
        receive(.mirrorState, try Self.mode(revision: 1, epoch: 2, physical: false))
        receive(.sourceCatalogue, Self.catalogue(revision: 3, current: 1));await drain(network)
        network.requestCaptureTarget(1, catalogue: try XCTUnwrap(network.captureTargetState.catalogue));await drain(network)
        XCTAssertTrue(timers.contains { $0.0 == CaptureTargetProtocol.terminalWait })
        receive(.sourceSwitchResult, Self.result(status: 9, revision: 3, current: 0))
        receive(.mirrorState, try Self.mode(revision: 2, epoch: 3, physical: false))
        receive(.sourceCatalogue, Self.catalogue(revision: 4, current: 11, virtualId: 11, physicalId: 14))
        receive(.sourceSwitchResult, Self.result());await drain(network)
        let decoder=try XCTUnwrap(network.captureTargetDecoderForTesting)
        let golden=CaptureTargetProtocolTests.bytes("53435354010800101800000000000000020000000000000005000000000000000600000000000000")
        XCTAssertTrue(writes.contains(golden))
        let recoveryTimers=timers.filter { $0.0 >= 1 && $0.0 <= 5 }.suffix(5)
        XCTAssertEqual(recoveryTimers.map { $0.0 }, [1,2,3,4,5])
        for (_, callback) in recoveryTimers { network.networkQueueForTesting.sync { callback() };await drain(network) }
        XCTAssertEqual(writes.filter { $0 == golden }.count, 5)
        XCTAssertTrue(network.captureTargetState.unknownOutcome);XCTAssertTrue(network.captureTargetState.inputBlocked)
        network.recordRenderCompletion(sequence: 0, generation: decoder)
        receive(.sourceSwitchResult, Self.result());await drain(network)
        XCTAssertTrue(network.captureTargetState.inputBlocked);XCTAssertFalse(network.permitsLegacyVirtualInput)
        XCTAssertEqual(writes.filter { $0[5] == 74 }.count, 1, "keyframe recovery never retries a source")
        XCTAssertGreaterThan(writes.filter { $0[5] == 72 }.count, 1)
    }
    @MainActor func testActualReconnectFencesRetiredTerminalCallbacksAndRequiresNewAdvertisement() async throws {
        let network=NetworkManager();var writes: [Data]=[], timers: [(TimeInterval, () -> Void)]=[]
        network.controlSendForAudioTesting={ bytes, done in writes.append(bytes);done(nil) }
        network.captureTargetScheduleForTesting={ seconds, callback in timers.append((seconds, callback)) }
        let old=network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        network.beginTransferWriterForTesting()
        network.receiveCaptureTargetWireForTesting(type: .displayCapabilities, payload: Self.modes, flags: 0x7c00,
            generation: old.generation, connection: old.connection)
        network.receiveCaptureTargetWireForTesting(type: .sourceCatalogue, payload: Self.catalogue(revision: 3, current: 1),
            generation: old.generation, connection: old.connection)
        await drain(network)
        network.requestCaptureTarget(4, catalogue: try XCTUnwrap(network.captureTargetState.catalogue));await drain(network)
        let expire=try XCTUnwrap(timers.first { $0.0 == CaptureTargetProtocol.terminalWait }?.1)
        network.stopForTesting();await drain(network)
        let next=network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }
        network.beginTransferWriterForTesting();await drain(network)
        XCTAssertFalse(network.captureTargetState.enabled);XCTAssertNil(network.captureTargetState.pending)
        network.refreshMirrorScreens();await drain(network)
        let before=writes.filter { $0[5] == 72 }.count
        network.receiveCaptureTargetWireForTesting(type: .displayCapabilities, payload: Self.modes, flags: 0x7c00,
            generation: old.generation, connection: old.connection)
        network.networkQueueForTesting.sync { expire() };await drain(network)
        XCTAssertFalse(network.captureTargetState.enabled);XCTAssertEqual(writes.filter { $0[5] == 72 }.count, before)
        network.receiveCaptureTargetWireForTesting(type: .displayCapabilities, payload: Self.modes, flags: 0x7c00,
            generation: next.generation, connection: next.connection)
        network.receiveCaptureTargetWireForTesting(type: .sourceCatalogue, payload: Self.catalogue(revision: 3, current: 1),
            generation: next.generation, connection: next.connection)
        await drain(network)
        network.requestCaptureTarget(4, catalogue: try XCTUnwrap(network.captureTargetState.catalogue));await drain(network)
        network.networkQueueForTesting.sync { expire() };await drain(network)
        XCTAssertEqual(network.captureTargetState.pending?.request.transaction, 1)
    }

    @MainActor func testReconnectRequestsFreshTargetsWhenCapabilitiesPrecedeTransportCommit() async throws {
        let network = NetworkManager()
        var writes: [Data] = []
        network.controlSendForAudioTesting = { bytes, done in writes.append(bytes); done(nil) }
        network.captureTargetScheduleForTesting = { _, _ in }
        let old = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        network.beginTransferWriterForTesting()
        network.receiveCaptureTargetWireForTesting(type: .displayCapabilities, payload: Self.modes,
            flags: CaptureTargetProtocol.advertisementFlag, generation: old.generation, connection: old.connection)
        network.receiveCaptureTargetWireForTesting(type: .sourceCatalogue, payload: Self.catalogue(revision: 3, current: 1),
            generation: old.generation, connection: old.connection)
        await drain(network)
        XCTAssertEqual(network.captureTargetState.confirmedCurrentId, 1)
        network.stopForTesting()

        let next = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }
        network.configureTransferAuthorizationForTesting(manager: nil, authenticated: true, committed: false)
        network.beginTransferWriterForTesting()
        let before = writes.filter { $0[5] == WireMessageType.sourceHello.rawValue }.count
        network.receiveIdentityWireForTesting(type: .displayCapabilities, payload: Self.modes,
            flags: CaptureTargetProtocol.advertisementFlag)
        await drain(network)
        XCTAssertEqual(writes.filter { $0[5] == WireMessageType.sourceHello.rawValue }.count, before)
        network.commitAudioTransportForTesting(mode: RealtimeTransportMode.legacyTLS, audioAvailable: true)
        await drain(network)
        XCTAssertEqual(writes.filter { $0[5] == WireMessageType.sourceHello.rawValue }.count, before + 1)
        network.receiveCaptureTargetWireForTesting(type: .sourceCatalogue,
            payload: Self.catalogue(revision: 1, current: 14, virtualId: 11, physicalId: 14),
            generation: next.generation, connection: next.connection)
        await drain(network)
        XCTAssertEqual(network.captureTargetState.generation, next.generation)
        XCTAssertEqual(network.captureTargetState.confirmedCurrentId, 14)
    }
    @MainActor func testActualSurfaceRetiresHeldPointerContactAndKeySynchronouslyBeforeRequest() async throws {
        let network=NetworkManager();var buttons: [PointerInputCommand]=[], contacts: [DirectTouchContactCommand]=[]
        var keys: [KeyboardInputCommand]=[], requests=0
        network.controlSendForAudioTesting={ bytes, done in
            if bytes[5] == 74 {
                XCTAssertEqual(buttons.last?.action, .leftUp);XCTAssertEqual(contacts.last?.phase, .cancel)
                XCTAssertEqual(keys.last?.action, .keyUp);requests+=1
            }
            done(nil)
        }
        network.captureTargetScheduleForTesting={ _, _ in }
        let peer=network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }
        network.beginTransferWriterForTesting()
        network.receiveCaptureTargetWireForTesting(type: .displayCapabilities, payload: Self.modes, flags: 0x7c00,
            generation: peer.generation, connection: peer.connection)
        network.receiveCaptureTargetWireForTesting(type: .mirrorState, payload: try Self.mode(revision: 1, epoch: 2, physical: false),
            generation: peer.generation, connection: peer.connection)
        network.receiveCaptureTargetWireForTesting(type: .sourceCatalogue, payload: Self.catalogue(revision: 3, current: 1),
            generation: peer.generation, connection: peer.connection)
        await drain(network)
        let window=UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let container=ConnectedPresentationContainer(frame: window.bounds);window.addSubview(container)
        defer { container.removeFromSuperview() }
        container.touchView.frame=window.bounds
        container.touchView.contentViewport=VideoContentViewport(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        let surface=ConnectedPresentationSurface(networkManager: network, remoteKeyboardActive: true,
            onKeyboardInput: { keys.append($0) }, onDirectTouchContact: { contacts.append($0) },
            onPointerInput: { buttons.append($0) })
        let coordinator=surface.makeCoordinator();surface.configureInputForTesting(container, coordinator: coordinator)
        container.touchView.handleExternalPointer(id: 1, phase: 1, point: CGPoint(x: 200, y: 150), primary: true,
            generation: network.mirrorInputRevision)
        container.touchView.emitDirectOutputs([.directTouch(.down, 1, CGPoint(x: 200, y: 150), 255)])
        container.touchView.keyboardCaptureEnabled=true;container.touchView.softwareResponderOwnsInput=false
        container.touchView.hardwareKeyUsageForTesting={ _ in .keyboardA }
        container.touchView.pressesBegan([UIPress()], with: nil)
        XCTAssertEqual(buttons.last?.action, .leftDown);XCTAssertEqual(contacts.last?.phase, .down)
        XCTAssertEqual(keys.last?.action, .keyDown)
        network.requestCaptureTarget(1, catalogue: try XCTUnwrap(network.captureTargetState.catalogue))
        XCTAssertEqual(buttons.last?.action, .leftUp);XCTAssertEqual(contacts.last?.phase, .cancel)
        XCTAssertEqual(keys.last?.action, .keyUp, "local held input retires before request queue admission")
        await drain(network);XCTAssertEqual(requests, 1)
    }
    #endif
}
