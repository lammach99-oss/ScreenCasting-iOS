import XCTest
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
