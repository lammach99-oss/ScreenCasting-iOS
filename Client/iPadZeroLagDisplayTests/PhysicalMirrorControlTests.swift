import XCTest
import UIKit
import Network
@testable import iPadCasting

final class PhysicalMirrorControlTests: XCTestCase {
    private let geometry = MirrorGeometry(left: -1920, top: 0, width: 1920, height: 1080, frameWidth: 2388, frameHeight: 1668)
    private let zero = MirrorToken(low: 0, high: 0)
    private let token = MirrorToken(low: 11, high: 12)
    private func state(_ revision: UInt64, _ epoch: UInt64, _ source: UInt64, _ mode: MirrorControlMode,
                       _ token: MirrorToken, _ first: UInt32? = nil) throws -> Data {
        try MirrorControlCodec.encodeState(MirrorControlState(revision: revision, epoch: epoch, source: source,
            mode: mode, token: token, geometry: geometry, firstFrame: first, lastSent: first))
    }
    private func model() -> MirrorClientControl {
        let model = MirrorClientControl(); model.beginSession(7)
        XCTAssertEqual(model.helloIfAdvertised(session: 7, flags: 0x4000), Data([1, 0, 0, 0, 1, 0, 0, 0]))
        return model
    }
    private func active(_ model: MirrorClientControl) throws -> MirrorInputTicket {
        _ = try model.receiveState(session: 7, data: state(1, 1, 1, .awaitingPresentation, zero, 100))
        XCTAssertNotNil(model.observeRendered(session: 7, sequence: 100))
        _ = try model.receiveState(session: 7, data: state(2, 1, 1, .active, token, 100))
        return try XCTUnwrap(model.captureTicket())
    }
    func testOldHostNeverReceivesUnknownMirrorHello() {
        let model = MirrorClientControl(); model.beginSession(7)
        XCTAssertNil(model.helloIfAdvertised(session: 7, flags: 0))
        XCTAssertTrue(model.allowsLegacyVirtualInput); XCTAssertNil(model.captureTicket())
    }
    func testHelloIsExactAndSentOncePerAuthenticatedConnection() {
        let model = self.model()
        XCTAssertNil(model.helloIfAdvertised(session: 7, flags: 0x4000))
        XCTAssertNil(model.helloIfAdvertised(session: 8, flags: 0x4000))
        XCTAssertFalse(model.allowsLegacyVirtualInput)
    }
    func testNewEpochRequiresItsOwnCompletedRender() throws {
        let model = self.model(); _ = try active(model)
        // TLS/RTP counters may occupy different domains. A cached old completion cannot ACK B.
        let transition = try model.receiveState(session: 7, data: state(3, 2, 2, .awaitingPresentation, zero, 50))
        XCTAssertNil(transition?.acknowledgement)
        XCTAssertNil(model.captureTicket())
        XCTAssertNotNil(model.observeRendered(session: 7, sequence: 50))
    }
    func testTransportRetirementRejectsOverlappingOldDomainUntilFreshDescriptor() throws {
        let model=self.model(),ticket=try active(model)
        model.retireTransportPresentation()
        XCTAssertNil(model.captureTicket())
        XCTAssertFalse(model.permitsVideoSequence(100))
        XCTAssertNil(model.observeRendered(session:7,sequence:100))
        XCTAssertThrowsError(try model.encodeInput(ticket:ticket,kind:.keyboard,payload:Data([1,0,65,0])))
        // A queued active descriptor from the old domain cannot reopen admission.
        _=try model.receiveState(session:7,data:state(3,1,1,.active,token,100))
        XCTAssertNil(model.captureTicket());XCTAssertFalse(model.permitsVideoSequence(100))
        _=try model.receiveState(session:7,data:state(4,2,1,.awaitingPresentation,zero,0))
        XCTAssertNil(model.captureTicket());XCTAssertTrue(model.permitsVideoSequence(0))
        XCTAssertNotNil(model.observeRendered(session:7,sequence:0))
        _=try model.receiveState(session:7,data:state(5,2,1,.active,MirrorToken(low:13,high:14),0))
        XCTAssertNotNil(model.captureTicket())
        XCTAssertThrowsError(try model.encodeInput(ticket:ticket,kind:.keyboard,payload:Data([1,0,65,0])))
    }
    func testTransportRetirementRejectsSameEpochInEveryMirrorMode() throws {
        for mode in [MirrorControlMode.awaitingPresentation, .viewOnly, .active] {
            for first in [UInt32(100), UInt32.max] {
                let model = self.model()
                _ = try model.receiveState(session: 7, data: state(1, 1, 1, .awaitingPresentation, zero, first))
                XCTAssertNotNil(model.observeRendered(session: 7, sequence: first))
                _ = try model.receiveState(session: 7, data: state(2, 1, 1, mode, mode == .active ? token : zero, first))
                let ticket = model.captureTicket()
                if mode == .active { XCTAssertNotNil(ticket) }
                model.retireTransportPresentation()
                XCTAssertNil(model.captureTicket())
                // A later revision, mode change, or overlapping/wrapped sequence is not a new transport epoch.
                for (index, delayedMode) in [MirrorControlMode.viewOnly, .awaitingPresentation, .active].enumerated() {
                    let transition = try model.receiveState(session: 7,
                        data: state(UInt64(index + 3), 1, 1, delayedMode, delayedMode == .active ? token : zero, first))
                    XCTAssertNil(transition?.acknowledgement)
                    for delayed in [first, first &+ 1] {
                        XCTAssertFalse(model.permitsVideoSequence(delayed), "retired mode=\(mode), delayed mode=\(delayedMode)")
                        XCTAssertNil(model.observeRendered(session: 7, sequence: delayed))
                    }
                    XCTAssertFalse(model.hasPresentedCurrentSource)
                    XCTAssertNil(model.captureTicket())
                    if let ticket {
                        XCTAssertThrowsError(try model.encodeInput(ticket: ticket, kind: .keyboard, payload: Data([1, 0, 65, 0])))
                    }
                }
            }
        }
    }
    func testTransportRetirementRequiresFreshEpochAnchorRenderAndToken() throws {
        for mode in [MirrorControlMode.awaitingPresentation, .viewOnly, .active] {
            let model = self.model()
            let oldTicket = try active(model)
            _ = try model.receiveState(session: 7, data: state(3, 1, 1, mode, mode == .active ? token : zero, 100))
            model.retireTransportPresentation()
            // A fresh epoch without the Host's published IDR anchor is still closed.
            _ = try model.receiveState(session: 7, data: state(4, 2, 1, .awaitingPresentation, zero))
            XCTAssertFalse(model.permitsVideoSequence(0))
            XCTAssertNil(model.observeRendered(session: 7, sequence: 0))
            XCTAssertNil(model.captureTicket())
            _ = try model.receiveState(session: 7, data: state(5, 2, 1, .awaitingPresentation, zero, 0))
            XCTAssertTrue(model.permitsVideoSequence(0))
            XCTAssertFalse(model.permitsVideoSequence(UInt32.max))
            let freshToken = MirrorToken(low: 13, high: 14)
            _ = try model.receiveState(session: 7, data: state(6, 2, 1, .active, freshToken, 0))
            XCTAssertNil(model.captureTicket(), "a grant cannot replace an actual completed new-domain render")
            XCTAssertNotNil(model.observeRendered(session: 7, sequence: 0))
            XCTAssertNil(model.observeRendered(session: 7, sequence: 0), "ACK each epoch once")
            let freshTicket = try XCTUnwrap(model.captureTicket())
            XCTAssertEqual(freshTicket.epoch, 2)
            XCTAssertEqual(freshTicket.token, freshToken)
            XCTAssertThrowsError(try model.encodeInput(ticket: oldTicket, kind: .keyboard, payload: Data([1, 0, 65, 0])))
            XCTAssertNoThrow(try model.encodeInput(ticket: freshTicket, kind: .keyboard, payload: Data([1, 0, 65, 0])))
        }
    }
    func testNewActiveDescriptorAloneCannotReleaseRetiredTransportFence() throws {
        let model = self.model()
        _ = try active(model)
        model.retireTransportPresentation()
        let freshToken = MirrorToken(low: 13, high: 14)
        _ = try model.receiveState(session: 7, data: state(3, 2, 1, .active, freshToken, 0))
        XCTAssertFalse(model.permitsVideoSequence(0))
        XCTAssertNil(model.observeRendered(session: 7, sequence: 0))
        XCTAssertNil(model.captureTicket())
        _ = try model.receiveState(session: 7, data: state(4, 2, 1, .awaitingPresentation, zero, 0))
        XCTAssertTrue(model.permitsVideoSequence(0))
        XCTAssertNotNil(model.observeRendered(session: 7, sequence: 0))
        _ = try model.receiveState(session: 7, data: state(5, 2, 1, .active, freshToken, 0))
        XCTAssertNotNil(model.captureTicket())
    }
    func testTransportRetirementAtMaximumEpochCannotReopenOrWrap() throws {
        for mode in [MirrorControlMode.awaitingPresentation, .viewOnly, .active] {
            let model = self.model()
            _ = try model.receiveState(session: 7, data: state(1, UInt64.max, 1, .awaitingPresentation, zero, UInt32.max))
            XCTAssertNotNil(model.observeRendered(session: 7, sequence: UInt32.max))
            _ = try model.receiveState(session: 7, data: state(2, UInt64.max, 1, mode, mode == .active ? token : zero, UInt32.max))
            let ticket = model.captureTicket()
            model.retireTransportPresentation()
            _ = try model.receiveState(session: 7, data: state(3, UInt64.max, 1, .viewOnly, zero, UInt32.max))
            for sequence in [UInt32.max, 0] {
                XCTAssertFalse(model.permitsVideoSequence(sequence))
                XCTAssertNil(model.observeRendered(session: 7, sequence: sequence))
            }
            XCTAssertThrowsError(try model.receiveState(session: 7, data: state(4, 1, 1, .awaitingPresentation, zero, 0)))
            XCTAssertNil(model.captureTicket())
            if let ticket {
                XCTAssertThrowsError(try model.encodeInput(ticket: ticket, kind: .keyboard, payload: Data([1, 0, 65, 0])))
            }
        }
    }
    func testTransportRetirementLeavesVirtualAndUnnegotiatedBehaviorUnchanged() throws {
        let legacy = MirrorClientControl()
        legacy.beginSession(7)
        legacy.retireTransportPresentation()
        XCTAssertTrue(legacy.allowsLegacyVirtualInput)
        XCTAssertTrue(legacy.permitsVideoSequence(0))
        let model = self.model()
        let virtual = MirrorControlState(revision: 1, epoch: 1, source: 0, mode: .virtualDisplay,
            token: zero, geometry: nil, firstFrame: nil, lastSent: nil)
        _ = try model.receiveState(session: 7, data: MirrorControlCodec.encodeState(virtual))
        model.retireTransportPresentation()
        XCTAssertTrue(model.allowsLegacyVirtualInput)
        XCTAssertTrue(model.permitsVideoSequence(UInt32.max))
        XCTAssertNil(model.captureTicket())
    }
    func testPresentationRecoveryIsExplicitScopedAndCannotGrant() throws {
        let model=self.model()
        XCTAssertNil(model.presentationRecoveryRequest())
        _=try model.receiveState(session:7,data:state(1,2,3,.awaitingPresentation,zero,UInt32.max))
        let bytes=try XCTUnwrap(model.presentationRecoveryRequest())
        XCTAssertEqual(bytes.count,32);XCTAssertEqual(bytes[1],4)
        XCTAssertEqual(MirrorControlCodec.read(Array(bytes),4,8),2)
        XCTAssertEqual(MirrorControlCodec.read(Array(bytes),12,8),3)
        XCTAssertEqual(MirrorControlCodec.read(Array(bytes),20,4),0)
        XCTAssertNil(model.captureTicket())
    }
    #if targetEnvironment(simulator)
    @MainActor
    func testActualSurfaceAdmissionAndRetirementPreserveLegacyAndDenyViewOnly() async throws {
        let network=NetworkManager()
        network.controlSendForAudioTesting={_,done in done(nil)}
        let session=network.simulateCommittedWifiSessionForTesting()
        defer {network.stopForTesting()}
        network.beginTransferWriterForTesting()
        network.networkQueueForTesting.sync {network.beginMirrorControlForTesting(generation:session.generation)}
        let window=UIWindow(frame:CGRect(x:0,y:0,width:400,height:300))
        let container=ConnectedPresentationContainer(frame:window.bounds)
        window.addSubview(container)
        defer {container.removeFromSuperview()}
        container.touchView.frame=window.bounds
        container.touchView.contentViewport=VideoContentViewport(rect:CGRect(x:0,y:0,width:1,height:1))
        var buttons:[PointerInputCommand]=[],contacts:[DirectTouchContactCommand]=[]
        var surface=ConnectedPresentationSurface(networkManager:network,remoteKeyboardActive:true,
            onDirectTouchContact:{contacts.append($0)},onPointerInput:{buttons.append($0)})
        let coordinator=surface.makeCoordinator()
        func receive(_ state:MirrorControlState) throws {
            network.receiveMirrorWireForTesting(type:.mirrorState,payload:try MirrorControlCodec.encodeState(state),
                generation:session.generation,connection:session.connection)
        }
        func drain() async {
            let flushed=expectation(description:"input registration publication")
            DispatchQueue.main.async {flushed.fulfill()}
            await fulfillment(of:[flushed],timeout:2)
        }
        func down(_ id:UInt64) {
            container.touchView.handleExternalPointer(id:id,phase:1,point:CGPoint(x:200,y:150),primary:true,generation:network.mirrorInputRevision)
            container.touchView.emitDirectOutputs([.directTouch(.down,id,CGPoint(x:200,y:150),255)])
        }
        try receive(MirrorControlState(revision:1,epoch:1,source:0,mode:.virtualDisplay,token:zero,geometry:nil,firstFrame:nil,lastSent:nil))
        await drain();surface.configureInputForTesting(container,coordinator:coordinator);down(1)
        XCTAssertEqual(buttons.map(\.action),[.leftDown]);XCTAssertEqual(contacts.map(\.phase),[.down])
        surface.remoteKeyboardActive=false
        surface.configureInputForTesting(container,coordinator:coordinator)
        XCTAssertEqual(buttons.map(\.action),[.leftDown,.leftUp]);XCTAssertEqual(contacts.map(\.phase),[.down,.cancel])
        down(2);XCTAssertEqual(buttons.count,2);XCTAssertEqual(contacts.count,2)
        try receive(MirrorControlState(revision:2,epoch:2,source:1,mode:.awaitingPresentation,token:zero,geometry:geometry,firstFrame:100,lastSent:100))
        await drain();surface.remoteKeyboardActive=true
        surface.configureInputForTesting(container,coordinator:coordinator);down(3)
        XCTAssertEqual(buttons.count,2);XCTAssertEqual(contacts.count,2)
        ConnectedPresentationSurface.dismantleUIView(container,coordinator:coordinator)
        XCTAssertEqual(buttons.count,2);XCTAssertEqual(contacts.count,2)
    }
    @MainActor
    func testLostMonitorSwitchResponseHasBoundedUnknownSettlement() async throws {
        try await exerciseSwitchDeadline(replaceConnection: false, recoverCatalogue: false)
    }
    @MainActor
    func testMonitorSwitchDeadlineCannotSettleReplacementConnectionAttempt() async throws {
        try await exerciseSwitchDeadline(replaceConnection: true, recoverCatalogue: false)
    }
    @MainActor
    func testRecoveredSwitchIgnoresItsLateDeadline() async throws {
        try await exerciseSwitchDeadline(replaceConnection: false, recoverCatalogue: true)
    }
    @MainActor
    private func exerciseSwitchDeadline(replaceConnection: Bool, recoverCatalogue: Bool) async throws {
        let network = NetworkManager()
        var sent: [Data] = []
        network.controlSendForAudioTesting = { bytes, done in sent.append(bytes); done(nil) }
        var deadlines: [(TimeInterval, () -> Void)] = []
        network.mirrorSwitchDeadlineForTesting = { delay, completion in deadlines.append((delay, completion)) }
        var session = network.simulateCommittedWifiSessionForTesting()
        defer { network.stopForTesting() }
        func begin() {
            network.beginTransferWriterForTesting()
            network.networkQueueForTesting.sync {
                network.beginMirrorControlForTesting(generation: session.generation, monitorSelection: true)
            }
        }
        func receive(_ type: WireMessageType, _ payload: Data) {
            network.receiveMirrorWireForTesting(type: type, payload: payload,
                generation: session.generation, connection: session.connection)
        }
        func drain() async {
            network.networkQueueForTesting.sync {}
            let flushed = expectation(description: "owned switch UI publication")
            DispatchQueue.main.async { flushed.fulfill() }
            await fulfillment(of: [flushed], timeout: 2)
        }
        func catalogue(_ revision: UInt64, _ selected: UInt64) -> Data {
            var bytes = [UInt8](repeating: 0, count: 20)
            bytes[0] = 1; bytes[1] = 1; bytes[2] = 2
            MirrorControlCodec.put(revision, &bytes, 4, 8); MirrorControlCodec.put(selected, &bytes, 12, 8)
            for id in UInt64(1)...2 {
                var row = [UInt8](repeating: 0, count: 10)
                MirrorControlCodec.put(id, &row, 0, 8); row[8] = 1
                bytes += row + [id == 1 ? 65 : 66]
            }
            return Data(bytes)
        }
        func prepare() async throws -> MirrorMonitorCatalogue {
            receive(.mirrorState, try state(1, 1, 1, .awaitingPresentation, zero, 100))
            let decoder = try XCTUnwrap(network.mirrorDecoderGenerationForTesting)
            network.recordRenderCompletion(sequence: 100, generation: decoder)
            receive(.mirrorState, try state(2, 1, 1, .active, token, 100))
            receive(.mirrorCatalogue, catalogue(7, 1)); await drain()
            XCTAssertNotNil(network.mirrorTicketAtRegistration)
            return try XCTUnwrap(network.mirrorMonitorCatalogue)
        }
        begin()
        let choices = try await prepare()
        network.requestMirrorMonitor(2, catalogue: choices); await drain()
        XCTAssertTrue(network.mirrorMonitorSwitchPending)
        XCTAssertNil(network.mirrorTicketAtRegistration)
        XCTAssertNil(network.mirrorMonitorCatalogue)
        XCTAssertEqual(deadlines.count, 1, "lost response needs one finite completion, not permanent Pending")
        guard deadlines.count == 1 else { return }
        XCTAssertGreaterThan(deadlines[0].0, 0)
        XCTAssertLessThanOrEqual(deadlines[0].0, 10, "bounded recovery must not wait for the 30-second Host lease")
        let oldDeadline = deadlines[0].1
        if replaceConnection {
            session = network.simulateCommittedWifiSessionForTesting()
            begin()
            let nextChoices = try await prepare()
            network.requestMirrorMonitor(2, catalogue: nextChoices); await drain()
            XCTAssertEqual(deadlines.count, 2)
            network.networkQueueForTesting.sync { oldDeadline() }; await drain()
            XCTAssertTrue(network.mirrorMonitorSwitchPending, "old owner cannot settle new Pending")
            XCTAssertNil(network.mirrorTicketAtRegistration)
            guard deadlines.count == 2 else { return }
            network.networkQueueForTesting.sync { deadlines[1].1() }
        } else if recoverCatalogue {
            receive(.mirrorState, try state(3, 2, 2, .awaitingPresentation, zero, 200))
            let decoder = try XCTUnwrap(network.mirrorDecoderGenerationForTesting)
            receive(.mirrorCatalogue, catalogue(8, 2)); await drain()
            XCTAssertTrue(network.mirrorMonitorSwitchPending, "received B catalogue is not rendered B")
            network.recordRenderCompletion(sequence: 200, generation: decoder); await drain()
            XCTAssertFalse(network.mirrorMonitorSwitchPending)
            XCTAssertEqual(network.mirrorMonitorCatalogue?.selected, 2)
            network.networkQueueForTesting.sync { oldDeadline() }; await drain()
            XCTAssertEqual(network.mirrorMonitorCatalogue?.selected, 2, "late deadline cannot erase known rendered source")
            return
        } else {
            network.networkQueueForTesting.sync { oldDeadline() }
        }
        await drain()
        XCTAssertFalse(network.mirrorMonitorSwitchPending, "lost response settles without implying switch success")
        XCTAssertNil(network.mirrorMonitorCatalogue, "timeout does not assert A or B is current")
        XCTAssertNil(network.mirrorTicketAtRegistration, "timeout never restores input authority")
        let count = sent.count
        network.networkQueueForTesting.sync { oldDeadline() }; await drain()
        XCTAssertEqual(sent.count, count, "one-shot timeout cannot generate retry traffic")
    }
    @MainActor
    func testMonitorSelectionWaitsForCurrentSourceRender() async throws {
        let network=NetworkManager()
        network.controlSendForAudioTesting={_,done in done(nil)}
        let session=network.simulateCommittedWifiSessionForTesting()
        defer {network.stopForTesting()}
        network.beginTransferWriterForTesting()
        network.networkQueueForTesting.sync {
            network.beginMirrorControlForTesting(generation:session.generation,monitorSelection:true)
        }
        func receive(_ type:WireMessageType,_ payload:Data) {
            network.receiveMirrorWireForTesting(type:type,payload:payload,generation:session.generation,connection:session.connection)
        }
        func drain() async {
            network.networkQueueForTesting.sync {}
            let flushed=expectation(description:"source-owned UI publication")
            DispatchQueue.main.async {flushed.fulfill()}
            await fulfillment(of:[flushed],timeout:2)
        }
        func catalogue(_ revision:UInt64,_ selected:UInt64)->Data {
            var bytes=[UInt8](repeating:0,count:20)
            bytes[0]=1;bytes[1]=1;bytes[2]=2
            MirrorControlCodec.put(revision,&bytes,4,8);MirrorControlCodec.put(selected,&bytes,12,8)
            for id in UInt64(1)...2 {
                var row=[UInt8](repeating:0,count:10)
                MirrorControlCodec.put(id,&row,0,8);row[8]=1
                bytes+=row+[id==1 ? 65:66]
            }
            return Data(bytes)
        }
        receive(.mirrorState,try state(1,1,1,.awaitingPresentation,zero,100))
        let oldDecoder=try XCTUnwrap(network.mirrorDecoderGenerationForTesting)
        receive(.mirrorCatalogue,catalogue(7,1));await drain()
        XCTAssertNil(network.mirrorMonitorCatalogue,"receipt alone is not current-source presentation")
        network.recordRenderCompletion(sequence:100,generation:oldDecoder);await drain()
        let choices=try XCTUnwrap(network.mirrorMonitorCatalogue)
        XCTAssertEqual(choices.selected,1)
        receive(.mirrorState,try state(2,1,1,.active,token,100));await drain()
        XCTAssertNotNil(network.mirrorTicketAtRegistration)
        network.requestMirrorMonitor(2,catalogue:choices);await drain()
        XCTAssertNil(network.mirrorTicketAtRegistration,"request retires the local sending scope immediately")
        XCTAssertNil(network.mirrorMonitorCatalogue,"consumed choices cannot imply switch completion")
        XCTAssertTrue(network.mirrorMonitorSwitchPending)
        receive(.mirrorCatalogue,catalogue(7,1));await drain()
        XCTAssertNil(network.mirrorMonitorCatalogue,"a consumed revision cannot re-admit selection")
        receive(.mirrorState,try state(3,2,2,.awaitingPresentation,zero,200))
        let freshDecoder=try XCTUnwrap(network.mirrorDecoderGenerationForTesting)
        receive(.mirrorCatalogue,catalogue(8,2));await drain()
        XCTAssertNil(network.mirrorMonitorCatalogue)
        network.recordRenderCompletion(sequence:200,generation:oldDecoder);await drain()
        XCTAssertNil(network.mirrorMonitorCatalogue,"old decoder cannot complete B selection")
        network.recordRenderCompletion(sequence:200,generation:freshDecoder);await drain()
        XCTAssertEqual(network.mirrorMonitorCatalogue?.selected,2)
        XCTAssertFalse(network.mirrorMonitorSwitchPending)
    }
    func testActualNetworkFallbackRetiresDecoderAndOldInputScope() throws {
        let network=NetworkManager()
        network.controlSendForAudioTesting={_,done in done(nil)}
        let session=network.simulateCommittedWifiSessionForTesting()
        defer {network.stopForTesting()}
        network.beginTransferWriterForTesting()
        func receive(_ type:WireMessageType,_ payload:Data) {
            network.receiveMirrorWireForTesting(type:type,payload:payload,generation:session.generation,connection:session.connection)
        }
        network.networkQueueForTesting.sync {
            network.beginMirrorControlForTesting(generation:session.generation)
        }
        receive(.mirrorState,try state(1,1,1,.awaitingPresentation,zero,100))
        let oldDecoder=try XCTUnwrap(network.mirrorDecoderGenerationForTesting)
        network.recordRenderCompletion(sequence:100,generation:oldDecoder)
        network.networkQueueForTesting.sync {}
        receive(.mirrorState,try state(2,1,1,.active,token,100))
        XCTAssertNotNil(network.mirrorTicketAtRegistration)
        XCTAssertTrue(network.networkQueueForTesting.sync {network.fallbackCommittedWifiToLegacy(generation:session.generation)})
        XCTAssertNil(network.mirrorTicketAtRegistration)
        network.recordRenderCompletion(sequence:100,generation:oldDecoder)
        network.networkQueueForTesting.sync {}
        XCTAssertNil(network.mirrorTicketAtRegistration)
        receive(.mirrorState,try state(3,2,1,.awaitingPresentation,zero,0))
        let freshDecoder=try XCTUnwrap(network.mirrorDecoderGenerationForTesting)
        XCTAssertNotEqual(oldDecoder,freshDecoder)
        receive(.mirrorState,try state(4,2,1,.active,MirrorToken(low:13,high:14),0))
        XCTAssertNil(network.mirrorTicketAtRegistration)
        network.recordRenderCompletion(sequence:0,generation:freshDecoder)
        network.networkQueueForTesting.sync {}
        XCTAssertNotNil(network.mirrorTicketAtRegistration)
    }
    #endif
    func testDelayedOldSourceMediaCannotEnterTheNewDecoderScope() throws {
        let model = self.model(); _ = try active(model)
        _ = try model.receiveState(session: 7, data: state(3, 2, 2, .awaitingPresentation, zero))
        XCTAssertFalse(model.permitsVideoSequence(199))
        _ = try model.receiveState(session: 7, data: state(4, 2, 2, .awaitingPresentation, zero, 200))
        XCTAssertFalse(model.permitsVideoSequence(199))
        XCTAssertTrue(model.permitsVideoSequence(200))
        XCTAssertNil(model.observeRendered(session: 7, sequence: 199))
        XCTAssertNotNil(model.observeRendered(session: 7, sequence: 200))
    }
    func testCapturedTicketCannotAcquireAnotherSourceInDelayedQueue() throws {
        let model = self.model(); let ticket = try active(model)
        let delayed = { try model.encodeInput(ticket: ticket, kind: .keyboard, payload: Data([1, 0, 65, 0])) }
        _ = try model.receiveState(session: 7, data: state(3, 2, 2, .awaitingPresentation, zero, 200))
        XCTAssertThrowsError(try delayed()); XCTAssertNil(model.captureTicket())
    }
    func testBackgroundReturnCannotReuseGrantedToken() throws {
        let model = self.model(); let ticket = try active(model)
        XCTAssertEqual(model.setForeground(false)?[1], 3)
        _ = model.setForeground(true); XCTAssertNil(model.captureTicket())
        XCTAssertThrowsError(try model.encodeInput(ticket: ticket, kind: .keyboard, payload: Data([1, 0, 65, 0])))
    }
    func testSettingsSuspensionRetiresModelScopeWithoutGrantingRequest() throws {
        let model = self.model(); let ticket = try active(model)
        XCTAssertEqual(model.suspendInput()?[1], 3); XCTAssertNil(model.captureTicket())
        XCTAssertEqual(model.requestControl()?[1], 1)
        XCTAssertThrowsError(try model.encodeInput(ticket: ticket, kind: .text, payload: Data([1, 1, 0, 65])))
    }
    func testConnectionRetirementRejectsOldDescriptorAndTicket() throws {
        let model = self.model(); let ticket = try active(model); model.beginSession(8)
        XCTAssertThrowsError(try model.receiveState(session: 7, data: state(4, 2, 2, .active, token, 100)))
        XCTAssertThrowsError(try model.encodeInput(ticket: ticket, kind: .keyboard, payload: Data([1, 0, 65, 0])))
        XCTAssertNil(model.captureTicket())
    }
    func testModelAcknowledgesEachEpochOnceAfterActualObservation() throws {
        let model = self.model()
        _ = try model.receiveState(session: 7, data: state(1, 1, 1, .awaitingPresentation, zero, 100))
        XCTAssertNil(model.observeRendered(session: 8, sequence: 100))
        XCTAssertNil(model.observeRendered(session: 7, sequence: 99))
        XCTAssertNotNil(model.observeRendered(session: 7, sequence: 100))
        XCTAssertNil(model.observeRendered(session: 7, sequence: 101))
    }
    func testStrictDescriptorReservedBytesAndLength() throws {
        var bytes = try state(1, 1, 1, .awaitingPresentation, zero, 100); bytes[92] = 1
        XCTAssertThrowsError(try MirrorControlCodec.decodeState(bytes))
        XCTAssertThrowsError(try MirrorControlCodec.decodeState(bytes.dropLast()))
    }
    func testInputEnvelopePreservesRaw37EightByteInnerRecord() throws {
        let model = self.model(); let ticket = try active(model)
        let raw = Data([1, 2, 0, 128, 0, 128, 0, 0])
        let bytes = try model.encodeInput(ticket: ticket, kind: .pointer, payload: raw)
        XCTAssertEqual(bytes.count, 56); XCTAssertEqual(bytes[1], 37)
        XCTAssertEqual(Data(bytes.suffix(8)), raw)
        XCTAssertEqual(try MirrorControlCodec.decodeInput(bytes).sequence, 1)
        XCTAssertEqual(WireMessageType.pointerInput.rawValue, 37)
    }
    func testBakedBarsRejectAndSignedDesktopOriginIsPreserved() throws {
        XCTAssertNil(try geometry.map(x: 32768, y: 0)); XCTAssertNil(try geometry.map(x: 32768, y: 65535))
        XCTAssertEqual(try geometry.map(x: 0, y: 32768)?.x, -1920)
        XCTAssertEqual(try geometry.map(x: 65535, y: 32768)?.x, -1)
    }
    func testPositiveVirtualStateRestoresOnlyLegacyVirtualRoute() throws {
        let model = self.model(); XCTAssertFalse(model.allowsLegacyVirtualInput)
        let virtual = MirrorControlState(revision: 1, epoch: 1, source: 0, mode: .virtualDisplay,
            token: zero, geometry: nil, firstFrame: nil, lastSent: nil)
        _ = try model.receiveState(session: 7, data: MirrorControlCodec.encodeState(virtual))
        XCTAssertTrue(model.allowsLegacyVirtualInput); XCTAssertNil(model.captureTicket())
    }
    private func catalogueBytes()->Data {
        var b=[UInt8](repeating:0,count:20);b[0]=1;b[1]=1;b[2]=1;b[4]=7;b[12]=1
        b += [1,0,0,0,0,0,0,0,7,0] + Array("Panel A".utf8)
        return Data(b)
    }
    func testMonitorSelectionRequiresSeparatelyAdvertisedCapability() {
        let model=MirrorClientControl();model.beginSession(7)
        XCTAssertEqual(model.helloIfAdvertised(session:7,flags:0x6000),Data([1,0,0,0,3,0,0,0]))
    }
    func testTerminalRetirementRequiresSeparatelyAdvertisedCapability() {
        let legacy=MirrorClientControl();legacy.beginSession(7)
        XCTAssertEqual(legacy.helloIfAdvertised(session:7,flags:0x6000),Data([1,0,0,0,3,0,0,0]))
        let noSelection=MirrorClientControl();noSelection.beginSession(7)
        XCTAssertEqual(noSelection.helloIfAdvertised(session:7,flags:0x5000),Data([1,0,0,0,1,0,0,0]))
        let terminal=MirrorClientControl();terminal.beginSession(7)
        XCTAssertEqual(terminal.helloIfAdvertised(session:7,flags:0x7000),Data([1,0,0,0,7,0,0,0]))
    }
    private func terminalAck(_ nonce:UInt64,_ epoch:UInt64=2,_ source:UInt64=1)->Data {
        var bytes=[UInt8](repeating:0,count:32);bytes[0]=2;bytes[1]=6
        MirrorControlCodec.put(epoch,&bytes,4,8);MirrorControlCodec.put(source,&bytes,12,8)
        MirrorControlCodec.put(nonce,&bytes,24,8);return Data(bytes)
    }
    private func terminalModel() throws -> MirrorClientControl {
        let model=MirrorClientControl();model.beginSession(7)
        XCTAssertEqual(model.helloIfAdvertised(session:7,flags:0x7000),Data([1,0,0,0,7,0,0,0]))
        _=try active(model);return model
    }
    func testTerminalBarrierRequiresMatchingStateAndAckInEitherOrder() throws {
        for ackFirst in [false,true] {
            let model=try terminalModel(),ticket=try XCTUnwrap(model.captureTicket())
            let request=try XCTUnwrap(model.beginTerminalSwitch(nonce:91))
            XCTAssertEqual(request[0],2);XCTAssertEqual(request[1],5)
            XCTAssertEqual(MirrorControlCodec.read(Array(request),24,8),91)
            XCTAssertNil(model.captureTicket())
            XCTAssertThrowsError(try model.encodeInput(ticket:ticket,kind:.keyboard,payload:Data([1,0,65,0])))
            if ackFirst {try model.receiveTerminalAcknowledgement(session:7,data:terminalAck(91))}
            else {_=try model.receiveState(session:7,data:state(3,2,1,.unavailable,zero))}
            XCTAssertFalse(model.takeTerminalSwitch(nonce:91))
            if ackFirst {_=try model.receiveState(session:7,data:state(3,2,1,.unavailable,zero))}
            else {try model.receiveTerminalAcknowledgement(session:7,data:terminalAck(91))}
            XCTAssertTrue(model.takeTerminalSwitch(nonce:91));XCTAssertFalse(model.takeTerminalSwitch(nonce:91))
            XCTAssertNil(model.captureTicket())
        }
    }
    #if targetEnvironment(simulator)
    @MainActor
    func testActualTerminalWriterRequiresCompletedKind5AndBothResponses() async throws {
        for ackFirst in [false,true] {
            let network=NetworkManager()
            var writes:[Data]=[],completions:[(NWError?)->Void]=[]
            network.controlSendForAudioTesting={bytes,done in writes.append(bytes);completions.append(done)}
            let session=network.simulateCommittedWifiSessionForTesting()
            network.beginTransferWriterForTesting()
            network.networkQueueForTesting.sync {
                network.beginMirrorControlForTesting(generation:session.generation,monitorSelection:true,terminal:true)
            }
            func drain() async {
                network.networkQueueForTesting.sync {}
                let done=expectation(description:"terminal writer owner")
                DispatchQueue.main.async{done.fulfill()}
                await fulfillment(of:[done],timeout:2)
                network.networkQueueForTesting.sync {}
            }
            func receive(_ type:WireMessageType,_ bytes:Data) {
                network.receiveMirrorWireForTesting(type:type,payload:bytes,generation:session.generation,connection:session.connection)
            }
            receive(.mirrorState,try state(1,1,1,.awaitingPresentation,zero,100))
            let decoder=try XCTUnwrap(network.mirrorDecoderGenerationForTesting)
            network.recordRenderCompletion(sequence:100,generation:decoder)
            receive(.mirrorState,try state(2,1,1,.active,token,100))
            receive(.mirrorCatalogue,catalogueBytes());await drain()
            // Drain initial render ACKs before measuring the terminal barrier.
            while !completions.isEmpty {
                let completion=completions.removeFirst()
                network.networkQueueForTesting.sync{completion(nil)};await drain()
            }
            writes.removeAll()
            let catalogue=try XCTUnwrap(network.mirrorMonitorCatalogue)
            network.requestMirrorMonitor(1,catalogue:catalogue);await drain()
            XCTAssertNil(network.mirrorTicketAtRegistration)
            let terminal=try XCTUnwrap(writes.first)
            XCTAssertEqual(terminal[5],WireMessageType.mirrorAction.rawValue)
            XCTAssertEqual(terminal[16],2);XCTAssertEqual(terminal[17],5)
            let nonce=MirrorControlCodec.read(Array(terminal),40,8)
            if ackFirst {receive(.mirrorAction,terminalAck(nonce))}
            else {receive(.mirrorState,try state(3,2,1,.unavailable,zero))}
            await drain();XCTAssertFalse(writes.contains{$0[5]==WireMessageType.mirrorSwitchRequest.rawValue})
            if ackFirst {receive(.mirrorState,try state(3,2,1,.unavailable,zero))}
            else {receive(.mirrorAction,terminalAck(nonce))}
            await drain();XCTAssertFalse(writes.contains{$0[5]==WireMessageType.mirrorSwitchRequest.rawValue},"ACK/state are not local writer completion")
            let terminalCompletion=try XCTUnwrap(completions.first);completions.removeFirst()
            network.networkQueueForTesting.sync{terminalCompletion(nil)};await drain()
            XCTAssertEqual(writes.filter{$0[5]==WireMessageType.mirrorSwitchRequest.rawValue}.count,1)
            receive(.mirrorAction,terminalAck(nonce));await drain()
            XCTAssertEqual(writes.filter{$0[5]==WireMessageType.mirrorSwitchRequest.rawValue}.count,1)
            network.stopForTesting()
        }
    }
    @MainActor
    func testActualTerminalLostResponseDeadlineNeverSendsSwitchOrRestoresInput() async throws {
        let network=NetworkManager();var writes:[Data]=[];var deadline:(()->Void)?
        network.controlSendForAudioTesting={bytes,done in writes.append(bytes);done(nil)}
        network.mirrorSwitchDeadlineForTesting={seconds,done in XCTAssertEqual(seconds,5);deadline=done}
        let session=network.simulateCommittedWifiSessionForTesting();defer{network.stopForTesting()}
        network.beginTransferWriterForTesting()
        network.networkQueueForTesting.sync {
            network.beginMirrorControlForTesting(generation:session.generation,monitorSelection:true,terminal:true)
        }
        func receive(_ type:WireMessageType,_ bytes:Data) {
            network.receiveMirrorWireForTesting(type:type,payload:bytes,generation:session.generation,connection:session.connection)
        }
        func drain() async {
            network.networkQueueForTesting.sync {}
            let done=expectation(description:"terminal deadline owner")
            DispatchQueue.main.async{done.fulfill()};await fulfillment(of:[done],timeout:2)
            network.networkQueueForTesting.sync {}
        }
        receive(.mirrorState,try state(1,1,1,.awaitingPresentation,zero,100))
        let decoder=try XCTUnwrap(network.mirrorDecoderGenerationForTesting)
        network.recordRenderCompletion(sequence:100,generation:decoder)
        receive(.mirrorState,try state(2,1,1,.active,token,100))
        receive(.mirrorCatalogue,catalogueBytes());await drain()
        let catalogue=try XCTUnwrap(network.mirrorMonitorCatalogue)
        network.requestMirrorMonitor(1,catalogue:catalogue);await drain()
        let expire=try XCTUnwrap(deadline)
        network.networkQueueForTesting.sync{expire()};await drain()
        XCTAssertFalse(network.mirrorMonitorSwitchPending);XCTAssertNil(network.mirrorTicketAtRegistration)
        XCTAssertFalse(writes.contains{$0[5]==WireMessageType.mirrorSwitchRequest.rawValue})
        network.networkQueueForTesting.sync{expire()};await drain()
        XCTAssertFalse(writes.contains{$0[5]==WireMessageType.mirrorSwitchRequest.rawValue})
    }
    #endif
    func testTerminalBarrierRejectsNonceSourceReservedAndOldEpoch() throws {
        for mutation in 0..<6 {
            let model=try terminalModel();_=model.beginTerminalSwitch(nonce:92)
            var ack=terminalAck(92)
            switch mutation {
            case 0: ack[24]=93
            case 1: ack[12]=2
            case 2: ack[4]=1
            case 3: ack[2]=1
            case 4: ack[20]=1
            default: ack[0]=1
            }
            XCTAssertThrowsError(try model.receiveTerminalAcknowledgement(session:7,data:ack))
            XCTAssertFalse(model.takeTerminalSwitch(nonce:92));XCTAssertNil(model.captureTicket())
        }
    }
    func testTerminalBarrierCancellationAndReplacementNeverRestoreTicket() throws {
        for reason in 0..<4 {
            let model=try terminalModel();_=model.beginTerminalSwitch(nonce:93)
            switch reason {
            case 0: model.cancelTerminalSwitch()
            case 1: model.retireTransportPresentation()
            case 2: XCTAssertEqual(model.suspendInput()?[1],3)
            default: model.beginSession(8)
            }
            XCTAssertThrowsError(try model.receiveTerminalAcknowledgement(session:7,data:terminalAck(93)))
            XCTAssertFalse(model.takeTerminalSwitch(nonce:93));XCTAssertNil(model.captureTicket())
        }
    }
    func testUnretiredTerminalCancellationResumesCurrentSource() throws {
        // Switch policy OFF: the Host revokes consent without retiring the requested epoch.
        for abandon in 0..<3 {
            let model=try terminalModel();_=model.beginTerminalSwitch(nonce:95)
            _=try model.receiveState(session:7,data:state(3,1,1,.viewOnly,zero,100))
            XCTAssertFalse(model.permitsVideoSequence(101))
            switch abandon {
            case 0: model.cancelTerminalSwitch()
            case 1: XCTAssertEqual(model.suspendInput()?[1],3)
            default: XCTAssertEqual(model.setForeground(false)?[1],3);model.setForeground(true)
            }
            XCTAssertTrue(model.permitsVideoSequence(101),"unretired source is still the current presentation: \(abandon)")
            XCTAssertNil(model.captureTicket())
        }
        let model=try terminalModel();_=model.beginTerminalSwitch(nonce:95)
        _=try model.receiveState(session:7,data:state(3,1,1,.viewOnly,zero,100))
        model.cancelTerminalSwitch()
        XCTAssertNotNil(model.observeRendered(session:7,sequence:101),"view-only source re-acknowledges its render")
        XCTAssertTrue(model.hasPresentedCurrentSource)
    }
    func testDeadlineAfterTakenSwitchNeverFloorsHostOwnedSuccessor() throws {
        let model=try terminalModel();_=model.beginTerminalSwitch(nonce:96)
        try model.receiveTerminalAcknowledgement(session:7,data:terminalAck(96))
        _=try model.receiveState(session:7,data:state(3,2,1,.unavailable,zero))
        XCTAssertTrue(model.takeTerminalSwitch(nonce:96))
        _=try model.receiveState(session:7,data:state(4,3,2,.awaitingPresentation,zero,200))
        model.cancelTerminalSwitch() // Response deadline after the switch request was sent.
        XCTAssertTrue(model.permitsVideoSequence(200),"successor media is the Host's to present")
        XCTAssertNotNil(model.observeRendered(session:7,sequence:200))
    }
    func testCancelAfterHostRetirementStillFloorsRetiredEpoch() throws {
        let model=try terminalModel();_=model.beginTerminalSwitch(nonce:97)
        _=try model.receiveState(session:7,data:state(3,2,1,.unavailable,zero))
        model.cancelTerminalSwitch()
        XCTAssertFalse(model.permitsVideoSequence(100))
        // The Host re-presents the retained source at a newer epoch.
        _=try model.receiveState(session:7,data:state(4,3,2,.awaitingPresentation,zero,300))
        XCTAssertTrue(model.permitsVideoSequence(300))
    }
    func testTerminalBarrierCannotNegotiateFromLegacyOrChangedAdvertisement() throws {
        let model=self.model();_=try active(model)
        XCTAssertNil(model.beginTerminalSwitch(nonce:1))
        XCTAssertNil(model.helloIfAdvertised(session:7,flags:0x7000))
        XCTAssertNil(model.beginTerminalSwitch(nonce:2))
        XCTAssertEqual(model.suspendInput()?[1],3)
    }
    func testTerminalSuccessorStillRequiresFreshRenderedSource() throws {
        let model=try terminalModel();_=model.beginTerminalSwitch(nonce:94)
        try model.receiveTerminalAcknowledgement(session:7,data:terminalAck(94))
        _=try model.receiveState(session:7,data:state(3,2,1,.unavailable,zero))
        XCTAssertTrue(model.takeTerminalSwitch(nonce:94))
        _=try model.receiveState(session:7,data:state(4,3,2,.awaitingPresentation,zero,200))
        _=try model.receiveState(session:7,data:state(5,3,2,.active,MirrorToken(low:21,high:22),200))
        XCTAssertNil(model.captureTicket());XCTAssertNil(model.observeRendered(session:7,sequence:199))
        XCTAssertNotNil(model.observeRendered(session:7,sequence:200));XCTAssertNotNil(model.captureTicket())
    }
    func testMonitorCatalogueAndOpaqueSwitchRequestExactBytes() throws {
        let catalogue=try MirrorMonitorCatalogue.decode(catalogueBytes())
        XCTAssertEqual(catalogue.monitors,[MirrorMonitorChoice(id:1,label:"Panel A")])
        XCTAssertEqual(catalogue.selected,1);XCTAssertEqual(catalogue.revision,7)
        XCTAssertEqual(try catalogue.switchRequest(1),Data([1,0,0,0,0,0,0,0,7,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0]))
        XCTAssertThrowsError(try catalogue.switchRequest(2))
    }
    func testMonitorCatalogueRejectsMalformedAndDeniedSelection() throws {
        let good=catalogueBytes()
        for count in 0..<good.count {XCTAssertThrowsError(try MirrorMonitorCatalogue.decode(Data(good.prefix(count))))}
        var denied=good;denied[1]=0
        XCTAssertThrowsError(try MirrorMonitorCatalogue.decode(denied).switchRequest(1))
        var unknown=good;unknown[12]=2
        XCTAssertThrowsError(try MirrorMonitorCatalogue.decode(unknown))
        var duplicate=good;duplicate[2]=2;duplicate.append(good.suffix(17))
        XCTAssertThrowsError(try MirrorMonitorCatalogue.decode(duplicate))
        var text=good;text[30]=0
        XCTAssertThrowsError(try MirrorMonitorCatalogue.decode(text))
    }
}
