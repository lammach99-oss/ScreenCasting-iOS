import XCTest
import UIKit
@testable import iPadCasting

final class AdaptiveMediaProtocolTests: XCTestCase {
    func fixtures() throws -> [String: String] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "AdaptiveMediaV1Golden", withExtension: "json"))
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }
    func bytes(_ hex: String) -> Data {
        var data = Data(); var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let next = hex.index(cursor, offsetBy: 2)
            data.append(UInt8(hex[cursor..<next], radix: 16)!); cursor = next
        }
        return data
    }
    func testAllSevenCodecsRoundTripTheSharedCSharpFixture() throws {
        let vectors = try fixtures()
        for type in UInt8(93)...99 {
            let data = bytes(try XCTUnwrap(vectors[String(type)]))
            let packet = try XCTUnwrap(AdaptiveMediaProtocol.decode(type: type, data: data))
            XCTAssertEqual(packet.encoded, data)
            XCTAssertEqual(data.count, AdaptiveMediaProtocol.size(type))
            XCTAssertNil(AdaptiveMediaProtocol.decode(type: type, data: data, flags: 1))
            XCTAssertNil(AdaptiveMediaProtocol.decode(type: type, data: Data(data.dropLast())))
            var wrong = data; wrong[0] = 2
            XCTAssertNil(AdaptiveMediaProtocol.decode(type: type, data: wrong))
            wrong = data; wrong[1] = 1
            XCTAssertNil(AdaptiveMediaProtocol.decode(type: type, data: wrong))
            XCTAssertNil(AdaptiveMediaProtocol.decode(type:type,data:data+Data([0])))
            let reserved: [UInt8:[Int]] = [93:[12],94:[52,63],95:[43,62],96:[100,111],97:[145,159],98:[100,111],99:[46,56,63]]
            for offset in reserved[type] ?? [] {
                var bad=data; bad[offset]=1
                XCTAssertNil(AdaptiveMediaProtocol.decode(type:type,data:bad))
            }
        }
    }
    func testGoldenFieldOffsetsAndOutboundFactoriesMatchCSharp() throws {
        let vectors=try fixtures()
        XCTAssertEqual(AdaptiveMediaProtocol.hello(owner:1,nonce:4).encoded,bytes(try XCTUnwrap(vectors["93"])))
        let config=try XCTUnwrap(AdaptiveMediaProtocol.decode(type:98,data:bytes(try XCTUnwrap(vectors["98"])))?.effective)
        XCTAssertEqual(config.desktopSize,CGSize(width:3840,height:2160))
        XCTAssertEqual(config.encodedSize,CGSize(width:1920,height:1080))
        XCTAssertEqual(config.content,CGRect(x:0,y:0,width:1920,height:1080))
        XCTAssertEqual(config.fps,30); XCTAssertEqual(config.scale,5000); XCTAssertEqual(config.bitrate,900_000)
        XCTAssertEqual(AdaptiveMediaProtocol.ack(config,status:1).encoded,bytes(try XCTUnwrap(vectors["99"])))
        let feedback=try XCTUnwrap(AdaptiveMediaProtocol.decode(type:97,data:bytes(try XCTUnwrap(vectors["97"]))))
        XCTAssertEqual(feedback.u64(120),11); XCTAssertEqual(feedback.u64(128),10); XCTAssertEqual(feedback.u64(136),9)
        XCTAssertEqual(feedback.u32(44),63); XCTAssertEqual(feedback.encoded[144],11)
    }
    func testMalformedEffectiveRectFlagsEnumsAndStaleAcknowledgement() throws {
        let vectors = try fixtures(), original = bytes(try XCTUnwrap(vectors["98"]))
        for offset in [44,45,46,47] {
            var bad = original; bad[offset] = 255
            XCTAssertNil(AdaptiveMediaProtocol.decode(type: 98, data: bad))
        }
        for offset in [8,16,24,36,40,72,76,88] {
            var bad = original
            let count = [8,16,24,88].contains(offset) ? 8 : 4
            bad.replaceSubrange(offset..<(offset+count), with: [UInt8](repeating: 0, count: count))
            XCTAssertNil(AdaptiveMediaProtocol.decode(type: 98, data: bad))
        }
        var bad = original; bad.storeLittleEndian(UInt32.max, at: 64)
        XCTAssertNil(AdaptiveMediaProtocol.decode(type: 98, data: bad))
        bad = original; bad.storeLittleEndian(UInt32(0), at: 96)
        XCTAssertNil(AdaptiveMediaProtocol.decode(type: 98, data: bad), "Half scale requires sharpness flag")
        let config = try XCTUnwrap(AdaptiveMediaProtocol.decode(type: 98, data: original)?.effective)
        let ack = AdaptiveMediaProtocol.ack(config, status: 1)
        XCTAssertTrue(AdaptiveMediaProtocol.matchesAcknowledgement(ack, config))
        var stale = ack.encoded; stale.storeLittleEndian(UInt64(4), at: 24)
        XCTAssertFalse(AdaptiveMediaProtocol.matchesAcknowledgement(try XCTUnwrap(AdaptiveMediaProtocol.decode(type: 99, data: stale)), config))
    }

    func testProbeExactEchoStrictDeadlineAndPermanentLegacy() {
        let ping = Data(repeating: 7, count: 16)
        var probe = AdaptiveMediaProbe()
        XCTAssertTrue(probe.begin(ping, now: 10))
        XCTAssertFalse(probe.accept(Data(repeating: 8, count: 16), flags: 0x0200, now: 10.1))
        XCTAssertTrue(probe.accept(ping, flags: 0x0200, now: 11.999))
        XCTAssertFalse(probe.accept(ping, flags: 0x0200, now: 11.999))
        var old = AdaptiveMediaProbe(); XCTAssertTrue(old.begin(ping, now: 0))
        XCTAssertFalse(old.accept(ping, flags: 0, now: 0.1))
        XCTAssertFalse(old.accept(ping, flags: 0x0200, now: 0.2))
        var late = AdaptiveMediaProbe(); XCTAssertTrue(late.begin(ping, now: 0))
        XCTAssertFalse(late.accept(ping, flags: 0x0200, now: 2))
        XCTAssertFalse(late.begin(ping, now: 3))
    }

    func testEpochFencesLateFramesAndStateCannotPublishBeforeFirstPresentation() throws {
        let vectors = try fixtures()
        var caps = bytes(try XCTUnwrap(vectors["94"])); caps[51] = 0
        caps.storeLittleEndian(UInt32(3_000_000), at: 28)
        var session = AdaptiveMediaSession(owner: 1, nonce: 4)
        XCTAssertTrue(session.acceptCapabilities(try XCTUnwrap(AdaptiveMediaProtocol.decode(type: 94, data: caps))))
        var configuration=bytes(try XCTUnwrap(vectors["98"])); configuration.storeLittleEndian(UInt32(8_000_000),at:84)
        let config = try XCTUnwrap(AdaptiveMediaProtocol.decode(type: 98, data: configuration)?.effective)
        XCTAssertTrue(session.configure(config))
        XCTAssertFalse(session.admit(sequence: 7, isIDR: true))
        XCTAssertFalse(session.admit(sequence: 8, isIDR: false))
        XCTAssertTrue(session.admit(sequence: 8, isIDR: true))
        XCTAssertFalse(session.receiveState(config), "Proposed pixels cannot become effective")
        XCTAssertNil(session.presented(sequence: 9))
        XCTAssertNotNil(session.presented(sequence: 8))
        XCTAssertTrue(session.receiveState(config))
        XCTAssertEqual(session.applied?.scale, 5000)
        XCTAssertTrue(session.applied?.summary.contains("text sharpness reduced") == true)
        XCTAssertFalse(session.configure(config), "Duplicate media epoch cannot reset the barrier")
    }

    func testTelemetryUsesFreshWindowCountsP95AndUnknownValidity() throws {
        var window = AdaptiveMediaWindow(started: 0)
        let identity = AdaptiveMediaIdentity(owner: 1, source: 2, media: 3)
        XCTAssertNil(window.sample(identity: identity, now: 0.5, activity: 3))
        window.received(frame: 1, bytes: 100, now: 0.1, receiveUs: 100)
        window.received(frame: 1, bytes: 100, now: 0.1, receiveUs: 100)
        window.decoded(frame: 1, queueUs: 200, decodeUs: 300)
        window.presented(frame: 1, now: 0.2); window.presented(frame: 1, now: 0.3)
        let first = try XCTUnwrap(window.sample(identity: identity, now: 1, activity: 3))
        XCTAssertEqual(first.u64(48), 100); XCTAssertEqual(first.u64(56), 1)
        XCTAssertEqual(first.u64(64), 1); XCTAssertEqual(first.u64(72), 1)
        XCTAssertEqual(first.u32(108), 100_000)
        XCTAssertEqual(first.u32(44) & 8, 0, "No RTT sample is unknown")
        let idle = try XCTUnwrap(window.sample(identity: identity, now: 2, activity: 0))
        XCTAssertEqual(idle.u64(72), 0, "Refresh repeats are not fresh presentations")
        XCTAssertEqual(idle.u32(44) & 7, 0, "Silence is not a healthy zero measurement")
    }

    func castingSession() throws -> AdaptiveMediaSession {
        let vectors=try fixtures(); var caps=bytes(try XCTUnwrap(vectors["94"]))
        caps[51]=0; caps.storeLittleEndian(UInt32(3_000_000),at:28)
        var session=AdaptiveMediaSession(owner:1,nonce:4)
        XCTAssertTrue(session.acceptCapabilities(try XCTUnwrap(AdaptiveMediaProtocol.decode(type:94,data:caps))))
        return session
    }
    func effective(_ type: UInt8 = 96, media: UInt64 = 3, first: UInt64 = 0) throws -> AdaptiveMediaEffective {
        let vectors=try fixtures(); var data=bytes(try XCTUnwrap(vectors[String(type)]))
        data.storeLittleEndian(media,at:24); data.storeLittleEndian(first,at:88); data.storeLittleEndian(UInt32(8_000_000),at:84)
        return try XCTUnwrap(AdaptiveMediaProtocol.decode(type:type,data:data)?.effective)
    }
    func testManualRestoreIsOnePolicyAndDoesNotOverwriteSavedTarget() throws {
        var s=try castingSession(); XCTAssertTrue(s.receiveState(try effective()))
        XCTAssertNil(s.makePolicy(auto:false,manualBps:2_000_000,game:false))
        let auto=try XCTUnwrap(s.makePolicy(auto:true,manualBps:20_000_000,game:false))
        XCTAssertEqual(auto.encoded[40],2); XCTAssertEqual(auto.u32(44),20_000_000)
        XCTAssertNil(s.makePolicy(auto:true,manualBps:20_000_000,game:false))
        XCTAssertNil(s.makePolicy(auto:false,manualBps:20_000_000,game:false),"Wait for the first policy revision before sending another")
        var accepted=try effective().packet.encoded; accepted.storeLittleEndian(auto.u32(32),at:32)
        accepted.storeLittleEndian(UInt32(7),at:36)
        XCTAssertTrue(s.receiveState(try XCTUnwrap(AdaptiveMediaProtocol.decode(type:96,data:accepted)?.effective)))
        let off=try XCTUnwrap(s.makePolicy(auto:false,manualBps:20_000_000,game:false))
        XCTAssertEqual(off.encoded[40],0); XCTAssertEqual(off.u32(44),20_000_000)
        XCTAssertGreaterThan(off.u32(32),auto.u32(32))
        XCTAssertNil(s.makePolicy(auto:false,manualBps:20_000_000,game:false))
    }
    func testAppliedStateCannotSkipCutoverAndZeroFirstFrameDoesNotEraseFloor() throws {
        var s=try castingSession(); XCTAssertTrue(s.receiveState(try effective()))
        XCTAssertFalse(s.receiveState(try effective(media:4)),"Same source needs Configuration before a new epoch")
        let c=try effective(98,media:4,first:80)
        XCTAssertTrue(s.configure(c)); XCTAssertTrue(s.admit(sequence:80,isIDR:true))
        XCTAssertNotNil(s.presented(sequence:80))
        XCTAssertTrue(s.receiveState(try effective(media:4))) // Host Snapshot carries FirstFrame=0.
        XCTAssertFalse(s.admit(sequence:79,isIDR:true)); XCTAssertTrue(s.admit(sequence:81,isIDR:false))
        XCTAssertEqual(s.frameFloor,80)
        XCTAssertEqual(AdaptiveMediaSession.frameID(0,near:UInt64(UInt32.max)+1),UInt64(UInt32.max)+1)
    }
    func testNewSourceBaselineCanRestartEffectiveRevisionAndRestoresOptInOnce() throws {
        var s=try castingSession(); XCTAssertTrue(s.receiveState(try effective()))
        XCTAssertNotNil(s.makePolicy(auto:true,manualBps:20_000_000,game:false))
        XCTAssertTrue(s.configure(try effective(98,media:4,first:80)))
        var next=try effective().packet.encoded
        next.storeLittleEndian(UInt64(3),at:16); next.storeLittleEndian(UInt32(1),at:40)
        XCTAssertTrue(s.receiveState(try XCTUnwrap(AdaptiveMediaProtocol.decode(type:96,data:next)?.effective)))
        XCTAssertNotNil(s.makePolicy(auto:true,manualBps:20_000_000,game:false))
        XCTAssertNil(s.makePolicy(auto:true,manualBps:20_000_000,game:false))
    }
    func testBaselineFrameIdentityExtendsAcrossTransportSequenceWrap() throws {
        var s=try castingSession(); XCTAssertTrue(s.receiveState(try effective()))
        for sequence in [UInt32.max-1,UInt32.max,0,1] { XCTAssertTrue(s.admit(sequence:sequence,isIDR:true)) }
        XCTAssertEqual(s.frameIdentity(1),UInt64(UInt32.max)+2)
    }
    func testSourceSelectionRetiresPendingConfigurationAndItsLateReplay() throws {
        var s=try castingSession(); XCTAssertTrue(s.receiveState(try effective()))
        let config=try effective(98,media:4,first:80)
        XCTAssertTrue(s.configure(config)); s.retirePendingConfiguration()
        XCTAssertNil(s.pending); XCTAssertNil(s.presented(sequence:80))
        XCTAssertFalse(s.configure(config),"Retired Configuration cannot regain authority")
        XCTAssertTrue(s.configure(try effective(98,media:5,first:90)))
    }
    func testFailedEpochBlocksOutputUntilANewRollbackConfiguration() throws {
        var s=try castingSession(); XCTAssertTrue(s.receiveState(try effective()))
        XCTAssertTrue(s.configure(try effective(98,media:4,first:80)))
        XCTAssertNotNil(s.failed(reason:4)); XCTAssertFalse(s.admit(sequence:81,isIDR:true))
        XCTAssertNil(s.frameIdentity(81))
        XCTAssertTrue(s.configure(try effective(98,media:5,first:90)))
        XCTAssertTrue(s.admit(sequence:90,isIDR:true))
    }
    func testDecoderFenceRetainsSessionAndRejectsOldCallbackWithoutDroppingHeldImage() throws {
        let decoder=DecoderManager(); decoder.beginSession(generation:7)
        var fences:[UInt64]=[], deliveries:[UInt32]=[]
        decoder.onCaptureFenced={ fences.append($0) }; decoder.onAdaptiveMedia={ _ in true }
        decoder.deliverCaptureOutput(sequence:79,generation:7) { deliveries.append(79) }
        XCTAssertTrue(decoder.prepareAdaptiveMedia(try effective(98,media:4,first:80)))
        decoder.deliverCaptureOutput(sequence:79,generation:7) { deliveries.append(999) }
        decoder.authorizeAdaptiveFrame(sequence:80)
        decoder.deliverCaptureOutput(sequence:80,generation:7) { deliveries.append(80) }
        XCTAssertEqual(deliveries,[79,80]); XCTAssertEqual(fences,[7])
        XCTAssertEqual(decoder.currentSessionGeneration,7)
    }
    func testInitialBaselineInstallsGeometryWithoutResettingDecodeChain() throws {
        let decoder=DecoderManager(); decoder.beginSession(generation:7)
        var fences=0; decoder.onCaptureFenced={ _ in fences+=1 }
        decoder.updateAdaptiveMedia(try effective())
        var seen:[AdaptiveMediaEffective?]=[]
        decoder.installAdaptiveMediaRenderer { seen.append($0); return true }
        XCTAssertEqual(fences,0); XCTAssertEqual(decoder.currentSessionGeneration,7)
        XCTAssertEqual(seen.count,1)
    }
    func testRendererAttachmentAfterBaselineReplaysGeometryWithoutRetiringDecoder() throws {
        let decoder=DecoderManager(); decoder.beginSession(generation:7)
        let value=try effective()
        XCTAssertFalse(decoder.prepareAdaptiveMedia(value),"No Ready without a renderer")
        var seen:[AdaptiveMediaEffective?]=[]
        decoder.installAdaptiveMediaRenderer { seen.append($0); return true }
        XCTAssertEqual(seen.count,1)
        if let first=seen.first { XCTAssertEqual(first,value) }
        decoder.clearAdaptiveMedia(); XCTAssertEqual(seen.count,2)
        if let last=seen.last { XCTAssertNil(last) }
        XCTAssertEqual(decoder.currentSessionGeneration,7)
    }
    func testParserBoundsNewControlsAndKeepsReadingLegacyMessages() {
        let parser=WireStreamParser(generation:1); var discarded=0, messages=0, failures=0
        let bad=ConnectionControlProtocol.frame(type:98,payload:Data(repeating:0,count:111))
        let legacy=ConnectionControlProtocol.frame(type:3,payload:Data(repeating:0,count:16))
        parser.consume(bad+legacy,generation:1) { event in
            switch event { case .failure: failures+=1; case .discardedFixedControl: discarded+=1; case .message: messages+=1 }
        }
        XCTAssertEqual(discarded,1); XCTAssertEqual(messages,1); XCTAssertEqual(failures,0)
    }
    @MainActor func testMediaScalingKeepsHeldDirectContactAndSourceRelativeDeltas() throws {
        let engine=IPadInputEngine(clock:{0}); engine.enabled=true; engine.directAvailable=true
        var out:[IPadInputEvent]=[]; engine.emit={out.append($0)}
        engine.begin(id:1,pencil:false,point:.zero,normalized:.zero)
        for scale in [1.0,0.75,0.5] {
            let source=CGSize(width:2400,height:1600)
            let viewport=try XCTUnwrap(VideoContentViewport.aspectFit(containerSize:CGSize(width:1200,height:800),videoSize:source))
            let rect=viewport.contentRect(in:CGRect(x:0,y:0,width:1200,height:800))
            // Renderer publishes the desktop size, regardless of this encoded size.
            let encoded=CGSize(width:source.width*CGFloat(scale),height:source.height*CGFloat(scale))
            XCTAssertLessThanOrEqual(encoded.width,source.width)
            engine.relativeScale=CGPoint(x:source.width/rect.width,y:source.height/rect.height)
            engine.move(id:1,point:CGPoint(x:600,y:400),normalized:CGPoint(x:0.5,y:0.5))
            XCTAssertEqual(engine.relativeScale,CGPoint(x:2,y:2))
            XCTAssertFalse(out.contains { if case .touch(.up,_,_,_)=$0 { return true }; if case .touch(.cancel,_,_,_)=$0 { return true }; return false })
        }
        engine.end(id:1,point:CGPoint(x:600,y:400),normalized:CGPoint(x:0.5,y:0.5),cancelled:false)
        XCTAssertEqual(out.filter { if case .touch(.down,_,_,_)=$0 { return true }; return false }.count,1)
        XCTAssertEqual(out.filter { if case .touch(.up,_,_,_)=$0 { return true }; return false }.count,1)
    }
    #if targetEnvironment(simulator)
    @MainActor func testRealWriterNeverSendsDS2BeforeExactPongOrForRemote() async throws {
        for remote in [false,true] {
            let network=NetworkManager(); network.adaptiveMediaClockForTesting={ 0 }; var writes:[Data]=[]
            network.controlSendForAudioTesting={ data,done in writes.append(data); done(nil) }
            network.realtimeAudioPlaybackForTesting={ _ in XCTFail("No audio in DS2 tests") }
            let peer=network.simulateCommittedWifiSessionForTesting(mode:RealtimeTransportMode.legacyTLS,remote:remote)
            defer { network.stopForTesting() }; network.beginTransferWriterForTesting()
            network.beginAdaptiveMediaForTesting()
            func drain() async {
                for _ in 0..<4 {
                    network.networkQueueForTesting.sync {}
                    let ready=expectation(description:"control queue barrier")
                    network.networkQueueForTesting.async { ready.fulfill() }
                    await fulfillment(of:[ready],timeout:2)
                }
            }
            await drain()
            XCTAssertTrue(writes.allSatisfy { !(93...99).contains($0[5]) })
            if remote { XCTAssertFalse(writes.contains { $0[5] == WireMessageType.ping.rawValue && $0.loadLittleEndian(UInt16.self,at:6) & 0x0200 != 0 }); continue }
            let ping=try XCTUnwrap(writes.first { $0[5] == WireMessageType.ping.rawValue && $0.loadLittleEndian(UInt16.self,at:6) & 0x0200 != 0 })
            let echo=Data(ping.suffix(16))
            network.receiveCaptureTargetWireForTesting(type:.pong,payload:Data(repeating:0,count:16),flags:0x0200,generation:peer.generation,connection:peer.connection)
            await drain(); XCTAssertFalse(writes.contains { $0[5] == 93 })
            network.receiveCaptureTargetWireForTesting(type:.pong,payload:echo,flags:0x0200,generation:peer.generation,connection:peer.connection)
            await drain(); XCTAssertEqual(writes.filter { $0[5] == 93 }.count,1)
            network.receiveCaptureTargetWireForTesting(type:.pong,payload:echo,flags:0x0200,generation:peer.generation,connection:peer.connection)
            await drain(); XCTAssertEqual(writes.filter { $0[5] == 93 }.count,1)
        }
    }
    @MainActor func testActualConfigurationAckFeedbackAndManualRestoreUseTheCurrentConnection() async throws {
        let suite="AdaptiveMedia."+UUID().uuidString
        let defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let network=NetworkManager(userDefaults:defaults); var now=0.0; var writes:[Data]=[]
        network.adaptiveMediaClockForTesting={ now }
        network.realtimeAudioPlaybackForTesting={ _ in XCTFail("No audio in DS2 tests") }
        network.captureTargetScheduleForTesting={ _,_ in }
        network.controlSendForAudioTesting={ data,done in writes.append(data); done(nil) }
        let peer=network.simulateCommittedWifiSessionForTesting(mode:RealtimeTransportMode.legacyTLS)
        defer { network.stopForTesting() }; network.beginTransferWriterForTesting()
        network.decoder.onAdaptiveMedia={ _ in true }
        network.beginAdaptiveMediaForTesting()
        func drain() async {
            for _ in 0..<4 {
                network.networkQueueForTesting.sync {}
                let ready=expectation(description:"quality publication barrier")
                DispatchQueue.main.async { ready.fulfill() }
                await fulfillment(of:[ready],timeout:2)
            }
            network.networkQueueForTesting.sync {}
        }
        func receive(_ type: WireMessageType,_ data: Data, flags: UInt16 = 0) {
            network.receiveCaptureTargetWireForTesting(type:type,payload:data,flags:flags,generation:peer.generation,connection:peer.connection)
        }
        await drain()
        let ping=try XCTUnwrap(writes.first { $0[5] == 6 && $0.loadLittleEndian(UInt16.self,at:6) & 0x0200 != 0 })
        receive(.pong,Data(ping.suffix(16)),flags:0x0200); await drain()
        let hello=Data(try XCTUnwrap(writes.first { $0[5] == 93 }).dropFirst(16))
        let owner=hello.loadLittleEndian(UInt64.self,at:24)
        var caps=bytes(try XCTUnwrap(try fixtures()["94"]))
        caps.storeLittleEndian(hello.loadLittleEndian(UInt64.self,at:16),at:8)
        caps.storeLittleEndian(owner,at:16); caps[51]=0; caps.storeLittleEndian(UInt32(3_000_000),at:28)
        receive(.qualityCapabilities,caps)
        var baseline=try effective().packet.encoded; baseline.storeLittleEndian(owner,at:8)
        receive(.qualityState,baseline); await drain()
        XCTAssertTrue(network.adaptiveQualityAvailable); XCTAssertFalse(network.autoQualityEnabled)
        XCTAssertFalse(writes.contains { $0[5] == 95 },"Negotiation alone is not opt-in")
        network.setAutoQualityEnabled(true); await drain()
        XCTAssertTrue(defaults.bool(forKey:"ScreenCasting.client.autoQuality.v1"))
        XCTAssertEqual(writes.filter { $0[5] == 95 }.count,1)
        var configuration=try effective(98,media:4,first:80).packet.encoded; configuration.storeLittleEndian(owner,at:8)
        configuration.storeLittleEndian(UInt32(1),at:32)
        receive(.qualityConfiguration,configuration); await drain()
        XCTAssertEqual(writes.filter { $0[5] == 99 }.map { $0[16+44] },[0])
        XCTAssertFalse(network.admitAdaptiveFrameForTesting(79,isIDR:true))
        XCTAssertTrue(network.admitAdaptiveFrameForTesting(80,isIDR:true))
        network.decoder.onAdaptiveDecoded?(80,network.decoder.currentSessionGeneration,200,300)
        network.recordCapturePresentation(sequence:80,generation:network.decoder.currentSessionGeneration)
        await drain()
        XCTAssertEqual(writes.filter { $0[5] == 99 }.map { $0[16+44] },[0,1])
        var applied=configuration; applied.storeLittleEndian(UInt64(0),at:88)
        receive(.qualityState,applied); await drain()
        XCTAssertTrue(network.effectiveQualitySummary?.contains("text sharpness reduced") == true)
        XCTAssertFalse(network.admitAdaptiveFrameForTesting(79,isIDR:true))
        now=1; network.sendAdaptiveFeedbackForTesting(); await drain()
        let feedback=Data(try XCTUnwrap(writes.last { $0[5] == 97 }).dropFirst(16))
        XCTAssertEqual(feedback.loadLittleEndian(UInt64.self,at:72),1)
        network.setAutoQualityEnabled(false); await drain()
        receive(.qualityState,applied); await drain()
        let policies=writes.filter { $0[5] == 95 }
        XCTAssertEqual(policies.count,2); XCTAssertEqual(policies.last?[16+40],0)
        XCTAssertEqual(policies.last?.loadLittleEndian(UInt32.self,at:16+44),UInt32(network.desiredBitrateMbps*1_000_000))
    }
    #endif

    func testSourceSpaceMappingAtEveryScalePaddingRotationAndHeldDrag() throws {
        for scale: UInt16 in [10000,7500,5000] {
            let desktop = CGSize(width: 2388, height: 1668)
            let encoded = CGSize(width: (desktop.width * CGFloat(scale)/10000).rounded(.up) + 8,
                                 height: (desktop.height * CGFloat(scale)/10000).rounded(.up) + 8)
            let content = CGRect(x: 4,y: 4,width: encoded.width-8,height: encoded.height-8)
            for container in [CGSize(width: 1200,height: 900),CGSize(width: 900,height: 1200)] {
                let viewport = try XCTUnwrap(VideoContentViewport.aspectFit(containerSize: container,videoSize: desktop))
                let rect = viewport.contentRect(in: CGRect(origin: .zero,size: container))
                for p in [CGPoint.zero,CGPoint(x: 1,y: 0),CGPoint(x: 0,y: 1),CGPoint(x: 1,y: 1),CGPoint(x: 0.5,y: 0.5)] {
                    let at = CGPoint(x: rect.minX + p.x*rect.width,y: rect.minY + p.y*rect.height)
                    let actual = try XCTUnwrap(viewport.normalizedPoint(for: at,in: CGRect(origin:.zero,size:container)))
                    XCTAssertEqual(actual.x,p.x,accuracy:0.0001); XCTAssertEqual(actual.y,p.y,accuracy:0.0001)
                    let tex = CGPoint(x: (content.minX+p.x*content.width)/encoded.width,y:(content.minY+p.y*content.height)/encoded.height)
                    XCTAssertTrue((0...1).contains(tex.x)); XCTAssertTrue((0...1).contains(tex.y))
                }
                XCTAssertEqual(desktop.width/rect.width * (rect.width/10),desktop.width/10,accuracy:0.0001)
            }
        }
    }
}
