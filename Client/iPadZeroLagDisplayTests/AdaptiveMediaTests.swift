import XCTest
import UIKit
@testable import iPadCasting

final class AdaptiveMediaProtocolTests: XCTestCase {
    func testCastingQualityPreferenceRoundTripsPerPairedHost() throws {
        let suite = "CastingQuality." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = Data(repeating: 1, count: 16)
        let second = Data(repeating: 2, count: 16)
        ClientStreamSettingsStore.saveAutoQuality(true, hostID: first, defaults: defaults)
        ClientStreamSettingsStore.saveAutoQuality(false, hostID: second, defaults: defaults)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertTrue(ClientStreamSettingsStore.loadAutoQuality(hostID: first, defaults: reopened))
        XCTAssertFalse(ClientStreamSettingsStore.loadAutoQuality(hostID: second, defaults: reopened))
        ClientStreamSettingsStore.saveAutoQuality(false, hostID: first, defaults: reopened)
        XCTAssertFalse(ClientStreamSettingsStore.loadAutoQuality(hostID: first, defaults: defaults))
    }

    func testRemoteQualityMigrationKeepsTheLegacyManualTargetAndCastingPreferences() throws {
        let suite = "RemoteQualityMigration." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = Data(repeating: 1, count: 16)
        let second = Data(repeating: 2, count: 16)
        let legacy = ClientStreamSettingsPreference.normalized(bitrateMbps: 31, audioEnabled: true,
                                                                adaptiveBitrateEnabled: true)
        ClientStreamSettingsStore.save(legacy, defaults: defaults)
        ClientStreamSettingsStore.migrateRemoteBitrate(defaults: defaults)
        ClientStreamSettingsStore.saveAutoQuality(true, hostID: first, defaults: defaults)
        XCTAssertFalse(ClientStreamSettingsStore.loadAutoQuality(hostID: first, remote: true, defaults: defaults))
        ClientStreamSettingsStore.save(.normalized(bitrateMbps: 12, audioEnabled: false),
                                       hostID: first, remote: true, defaults: defaults)
        XCTAssertEqual(ClientStreamSettingsStore.load(hostID: second, remote: true, defaults: defaults).bitrateMbps, 31)
        XCTAssertEqual(ClientStreamSettingsStore.load(defaults: defaults), legacy)
        XCTAssertTrue(ClientStreamSettingsStore.loadAutoQuality(hostID: first, defaults: defaults))
        XCTAssertEqual(ClientStreamSettingsStore.load(hostID: first, remote: true, defaults: defaults).bitrateMbps, 12)
    }

    func testMissingCastingQualityFieldDefaultsToManualWithoutChangingLegacySettings() throws {
        let suite = "CastingQualityMigration." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // The app-wide flag had no host identity, so it is not pairing consent.
        defaults.set(true, forKey: "ScreenCasting.client.autoQuality.v1")
        let legacy = ClientStreamSettingsPreference.normalized(bitrateMbps: 31, audioEnabled: false)
        ClientStreamSettingsStore.save(legacy, defaults: defaults)
        XCTAssertFalse(ClientStreamSettingsStore.loadAutoQuality(hostID: Data(repeating: 1, count: 16), defaults: defaults))
        XCTAssertEqual(ClientStreamSettingsStore.load(defaults: defaults), legacy)
    }

    func testCastingBitrateMigrationPreservesOldDefaultAndSeedsNewPairings() throws {
        let suite = "CastingBitrateMigration." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let existingA = Data(repeating: 1, count: 16)
        let existingB = Data(repeating: 2, count: 16)
        let newHost = Data(repeating: 3, count: 16)
        ClientStreamSettingsStore.save(.normalized(bitrateMbps: 31, audioEnabled: false), defaults: defaults)
        ClientStreamSettingsStore.migrateCastingBitrate(defaults: defaults)
        ClientStreamSettingsStore.save(.normalized(bitrateMbps: 12, audioEnabled: false), hostID: existingA, defaults: defaults)
        XCTAssertEqual(ClientStreamSettingsStore.load(defaults: defaults).bitrateMbps, 31)
        ClientStreamSettingsStore.save(.normalized(bitrateMbps: 24, audioEnabled: false), defaults: defaults)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        ClientStreamSettingsStore.migrateCastingBitrate(defaults: reopened)
        ClientStreamSettingsStore.initializeCastingBitrateForNewPairing(hostID: existingA, defaults: reopened)
        ClientStreamSettingsStore.initializeCastingBitrateForNewPairing(hostID: newHost, defaults: reopened)
        XCTAssertEqual(ClientStreamSettingsStore.load(hostID: existingA, defaults: reopened).bitrateMbps, 12)
        XCTAssertEqual(ClientStreamSettingsStore.load(hostID: existingB, defaults: reopened).bitrateMbps, 31)
        XCTAssertEqual(ClientStreamSettingsStore.load(hostID: newHost, defaults: reopened).bitrateMbps, 24)
    }

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

    private func castingTLSFixtures() throws -> [String: WireMessage] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ds8-casting-tls-golden", withExtension: "json"))
        let vectors = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        return try vectors.mapValues { hex in
            var message: WireMessage?
            let parser = WireStreamParser(generation: 1)
            parser.consume(bytes(hex), generation: 1) { event in
                if case .message(let value) = event { message = value }
            }
            return try XCTUnwrap(message)
        }
    }

    func testCastingTLSGoldenProbeAndReservedVideo() throws {
        let vectors = try castingTLSFixtures()
        XCTAssertEqual(vectors.count, 12)
        for (name, route) in [("wifiRtp", AdaptiveCastingRoute.wifiRTP), ("wifiTls", .wifiTLS), ("usbTls", .usbTLS)] {
            let ping = try XCTUnwrap(vectors[name + "Ping"])
            XCTAssertEqual(ping.header.type, .ping)
            XCTAssertEqual(ping.header.flags, AdaptiveMediaProtocol.probeFlag)
            XCTAssertEqual(ping.header.sequence, route.rawValue)
            var probe = AdaptiveMediaProbe()
            XCTAssertTrue(probe.begin(ping.payload, now: 0, castingRoute: route))
            let pong = try XCTUnwrap(vectors[route == .wifiRTP ? "wifiTlsPong" : name + "Pong"])
            if route != .wifiRTP {
                XCTAssertFalse(probe.accept(pong.payload, flags: pong.header.flags, sequence: 0, now: 0.25))
                XCTAssertEqual(probe.phase, .waiting)
            }
            XCTAssertTrue(probe.accept(pong.payload, flags: pong.header.flags, sequence: pong.header.sequence, now: 0.5))
        }
        for (name, phase) in [("usbTlsBackoffPong", AdaptiveMediaProbe.Phase.backoff), ("legacyPong", .legacy)] {
            let pong = try XCTUnwrap(vectors[name])
            var probe = AdaptiveMediaProbe()
            XCTAssertTrue(probe.begin(pong.payload, now: 0, castingRoute: .usbTLS))
            XCTAssertFalse(probe.accept(pong.payload, flags: pong.header.flags, sequence: pong.header.sequence, now: 1))
            XCTAssertEqual(probe.phase, phase)
        }

        let configuration = try XCTUnwrap(vectors["configuration"])
        let value = try XCTUnwrap(AdaptiveMediaProtocol.decode(type: 98, data: configuration.payload)?.effective)
        var runtimePayload = configuration.payload
        runtimePayload.storeLittleEndian(UInt32(8_000_000), at: 84)
        let runtimeValue = try XCTUnwrap(AdaptiveMediaProtocol.decode(type: 98, data: runtimePayload)?.effective)
        let reserved = try XCTUnwrap(vectors["video"])
        let control = try XCTUnwrap(vectors["interleavedPong"])
        var caps = bytes(try XCTUnwrap(try fixtures()["94"]))
        caps[51] = 0
        caps.storeLittleEndian(UInt32(3_000_000), at: 28)
        func session() throws -> AdaptiveMediaSession {
            var session = AdaptiveMediaSession(owner: 1, nonce: 4, castingRoute: .wifiTLS)
            XCTAssertTrue(session.acceptCapabilities(try XCTUnwrap(AdaptiveMediaProtocol.decode(type: 94, data: caps))))
            var baseline = try manualBaselineState(owner: 1)
            baseline.storeLittleEndian(value.identity.source, at: 16)
            XCTAssertTrue(session.receiveState(try XCTUnwrap(AdaptiveMediaProtocol.decode(type: 96, data: baseline)?.effective)))
            return session
        }
        var good = try session()
        XCTAssertFalse(good.configure(runtimeValue, controlSequence: configuration.header.sequence + 1))
        XCTAssertTrue(good.configure(runtimeValue, controlSequence: configuration.header.sequence))
        XCTAssertEqual(AdaptiveMediaProtocol.ack(value, status: 0).encoded, vectors["ready"]?.payload)
        XCTAssertNil(good.presented(sequence: reserved.header.sequence))
        XCTAssertEqual(control.header.type, .pong)
        XCTAssertTrue(control.header.sequence > reserved.header.sequence)
        guard case .cutover = good.admitCastingTLS(sequence: reserved.header.sequence, isIDR: true, hasParameterSets: true) else {
            return XCTFail("The reserved IDR must satisfy the barrier")
        }
        XCTAssertTrue(good.admit(sequence: reserved.header.sequence, isIDR: true))
        XCTAssertNil(good.presented(sequence: control.header.sequence))
        XCTAssertEqual(good.presented(sequence: reserved.header.sequence)?.encoded, vectors["presented"]?.payload)
        XCTAssertNil(good.presented(sequence: reserved.header.sequence))
        for (sequence, sets) in [(reserved.header.sequence, false), (reserved.header.sequence - 1, true), (reserved.header.sequence + 1, true)] {
            var bad = try session()
            XCTAssertTrue(bad.configure(runtimeValue, controlSequence: configuration.header.sequence))
            guard case .missingFirstFrame = bad.admitCastingTLS(sequence: sequence, isIDR: true, hasParameterSets: sets) else {
                return XCTFail("Invalid Video must fail the reserved frame barrier")
            }
        }
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

    func testGoldenBackoffPongRequiresTimelyExactEchoAndStaysLegacy() throws {
        let frame = bytes(try XCTUnwrap(try fixtures()["probeBackoffPong"]))
        let parser = WireStreamParser(generation: 1)
        var response: WireMessage?
        parser.consume(frame, generation: 1) { event in
            if case .message(let message) = event { response = message }
        }
        let pong = try XCTUnwrap(response)
        XCTAssertEqual(pong.header.type, .pong)
        XCTAssertEqual(pong.header.flags, 0x0040)
        var probe = AdaptiveMediaProbe()
        XCTAssertTrue(probe.begin(pong.payload, now: 10))
        var wrong = pong.payload
        wrong[0] ^= 1
        XCTAssertFalse(probe.accept(wrong, flags: pong.header.flags, now: 10.1))
        XCTAssertFalse(probe.accept(pong.payload, flags: 0x0240, now: 10.2))
        XCTAssertEqual(probe.phase, .waiting)
        XCTAssertFalse(probe.accept(pong.payload, flags: pong.header.flags, now: 11.999))
        XCTAssertEqual(probe.phase, .backoff)
        XCTAssertFalse(probe.begin(pong.payload, now: 50))
        XCTAssertFalse(probe.accept(pong.payload, flags: 0x0200, now: 50))
        XCTAssertEqual(probe.phase, .backoff)

        var late = AdaptiveMediaProbe()
        XCTAssertTrue(late.begin(pong.payload, now: 10))
        XCTAssertFalse(late.accept(pong.payload, flags: pong.header.flags, now: 12))
        XCTAssertEqual(late.phase, .legacy)

        var independentFlags = AdaptiveMediaProbe()
        XCTAssertTrue(independentFlags.begin(pong.payload, now: 10))
        XCTAssertFalse(independentFlags.accept(pong.payload, flags: 0x00C0, now: 11))
        XCTAssertEqual(independentFlags.phase, .backoff)
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

    func testFeedbackCountsReorderedFramesOnceAcrossWindowBoundaries() throws {
        var window = AdaptiveMediaWindow(started: 0)
        let identity = AdaptiveMediaIdentity(owner: 1, source: 2, media: 3)
        window.received(frame: 11, bytes: 200, now: 0.25, receiveUs: 300)
        window.received(frame: 10, bytes: 100, now: 0.50, receiveUs: 200)
        window.decoded(frame: 11, queueUs: 10, decodeUs: 300)
        window.decoded(frame: 10, queueUs: 20, decodeUs: 600)
        window.presented(frame: 11, now: 0.5)
        let first = try XCTUnwrap(window.sample(identity: identity, now: 1.125, activity: 3))
        XCTAssertEqual(first.u32(40), 1_125_000)
        XCTAssertEqual(first.u64(48), 300)
        XCTAssertEqual(first.u64(56), 2)
        XCTAssertEqual(first.u64(64), 2)
        XCTAssertEqual(first.u64(72), 1)
        XCTAssertEqual(first.u32(96), 500)
        XCTAssertEqual(first.u32(104), 600)
        XCTAssertEqual(first.u32(108), 250_000)
        for offset in [120, 128, 136] { XCTAssertEqual(first.u64(offset), 11) }
        XCTAssertNil(window.sample(identity: identity, now: 1.25, activity: 3))

        window.received(frame: 10, bytes: 100, now: 1.5, receiveUs: 200)
        window.decoded(frame: 10, queueUs: 20, decodeUs: 600)
        window.presented(frame: 11, now: 1.5)
        let second = try XCTUnwrap(window.sample(identity: identity, now: 2.25, activity: 3))
        XCTAssertEqual(second.u64(32), first.u64(32) &+ 1)
        for offset in [48, 56, 64, 72] { XCTAssertEqual(second.u64(offset), 0) }
        XCTAssertEqual(second.u32(44) & 7, 0)
    }

    func testFeedbackWithPartialReceiveTimingDoesNotReportValidGoodput() throws {
        var window = AdaptiveMediaWindow(started: 0)
        let identity = AdaptiveMediaIdentity(owner: 1, source: 2, media: 3)
        window.received(frame: 1, bytes: 100, now: 0.25, receiveUs: 100)
        window.received(frame: 2, bytes: 200, now: 0.5, receiveUs: nil)
        let partial = try XCTUnwrap(window.sample(identity: identity, now: 1, activity: 3))
        XCTAssertEqual(partial.u64(48), 300)
        XCTAssertEqual(partial.u64(56), 2)
        XCTAssertEqual(partial.u32(44) & 1, 0)
        XCTAssertEqual(partial.u32(96), 0)

        window.received(frame: 3, bytes: 100, now: 1.25, receiveUs: 0)
        let zero = try XCTUnwrap(window.sample(identity: identity, now: 2, activity: 3))
        XCTAssertEqual(zero.u32(44) & 1, 0)
        XCTAssertEqual(zero.u32(96), 0)
    }

    func testFeedbackReportsAgeOfLastFreshPresentation() throws {
        var window = AdaptiveMediaWindow(started: 0)
        let identity = AdaptiveMediaIdentity(owner: 1, source: 2, media: 3)
        window.received(frame: 1, bytes: 100, now: 0.125, receiveUs: 100)
        window.presented(frame: 1, now: 0.625)
        window.received(frame: 2, bytes: 100, now: 0.75, receiveUs: 100)
        window.presented(frame: 2, now: 0.875)
        let feedback = try XCTUnwrap(window.sample(identity: identity, now: 1, activity: 3))
        XCTAssertEqual(feedback.u32(44) & 4, 4)
        XCTAssertEqual(feedback.u32(108), 125_000)
        XCTAssertEqual(feedback.u64(136), 2)
    }

    func testFeedbackDiscardsOversizedWindowAndStartsFresh() throws {
        var window = AdaptiveMediaWindow(started: 0)
        let identity = AdaptiveMediaIdentity(owner: 1, source: 2, media: 3)
        window.received(frame: 1, bytes: 500, now: 0.5, receiveUs: 100)
        XCTAssertNil(window.sample(identity: identity, now: 20, activity: 3))
        window.received(frame: 2, bytes: 100, now: 20.25, receiveUs: 100)
        let fresh = try XCTUnwrap(window.sample(identity: identity, now: 21, activity: 3))
        XCTAssertEqual(fresh.u32(40), 1_000_000)
        XCTAssertEqual(fresh.u64(48), 100)
        XCTAssertEqual(fresh.u64(56), 1)
        XCTAssertEqual(fresh.u32(44) & 1, 1)
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
    private func manualBaselineState(owner: UInt64) throws -> Data {
        var baseline = bytes(try XCTUnwrap(try fixtures()["96"]))
        baseline.storeLittleEndian(owner, at: 8)
        baseline.storeLittleEndian(UInt64(1), at: 24)
        baseline.storeLittleEndian(UInt32(0), at: 32)
        baseline.storeLittleEndian(UInt32(1), at: 36)
        baseline.storeLittleEndian(UInt32(1), at: 40)
        baseline[45] = 0; baseline[46] = 0; baseline[47] = 0
        let width = baseline.loadLittleEndian(UInt32.self, at: 48)
        let height = baseline.loadLittleEndian(UInt32.self, at: 52)
        baseline.storeLittleEndian(width, at: 56)
        baseline.storeLittleEndian(height, at: 60)
        baseline.storeLittleEndian(UInt32(0), at: 64)
        baseline.storeLittleEndian(UInt32(0), at: 68)
        baseline.storeLittleEndian(width, at: 72)
        baseline.storeLittleEndian(height, at: 76)
        baseline.storeLittleEndian(UInt16(600), at: 80)
        baseline.storeLittleEndian(UInt16(10000), at: 82)
        baseline.storeLittleEndian(UInt32(27_000_000), at: 84)
        baseline.storeLittleEndian(UInt64(0), at: 88)
        baseline.storeLittleEndian(UInt32(0), at: 96)
        return baseline
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
    @MainActor func testCastingTLSRequiresARenderedIDRAndDeclinesToSavedManual() async throws {
        let video = try XCTUnwrap(try castingTLSFixtures()["video"])
        for tag: UInt32 in [1, 2] {
            for backoff in [false, true] {
                let suite = "CastingTLSDecline." + UUID().uuidString
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let host = Data(repeating: 1, count: 16)
                ClientStreamSettingsStore.saveAutoQuality(true, hostID: host, defaults: defaults)
                ClientStreamSettingsStore.save(.normalized(bitrateMbps: 12, audioEnabled: false, adaptiveBitrateEnabled: true),
                                               hostID: host, defaults: defaults)
                let network = NetworkManager(userDefaults: defaults)
                defer { network.stopForTesting() }
                var writes: [Data] = []
                var decoded: [UInt32] = []
                network.adaptiveMediaClockForTesting = { 1 }
                network.realtimeAudioPlaybackForTesting = { enabled in XCTAssertFalse(enabled) }
                network.captureTargetDecodeForTesting = { _, sequence, _ in decoded.append(sequence) }
                network.controlSendForAudioTesting = { data, done in writes.append(data); done(nil) }
                let peer = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
                network.setAdaptiveHostForTesting(host, usb: tag == 2)
                network.beginTransferWriterForTesting()
                network.reconnectAttemptForTesting = 3
                func receive(_ type: WireMessageType, _ payload: Data, flags: UInt16 = 0, sequence: UInt32 = 0) {
                    network.receiveCaptureTargetWireForTesting(type: type, payload: payload, flags: flags, sequence: sequence,
                                                               generation: peer.generation, connection: peer.connection)
                }
                func probes() -> [Data] {
                    network.networkQueueForTesting.sync {
                        writes.filter { $0[5] == 6 && $0.loadLittleEndian(UInt16.self, at: 6) == AdaptiveMediaProtocol.probeFlag }
                    }
                }
                network.beginAdaptiveMediaForTesting()
                receive(.video, video.payload, flags: video.header.flags, sequence: 10)
                XCTAssertEqual(network.networkQueueForTesting.sync { decoded }, [10])
                let decoder = network.decoder.currentSessionGeneration
                network.recordCapturePresentation(sequence: 10, generation: decoder &- 1)
                network.recordCapturePresentation(sequence: 11, generation: decoder)
                XCTAssertTrue(probes().isEmpty)
                network.recordCapturePresentation(sequence: 10, generation: decoder)
                network.recordCapturePresentation(sequence: 10, generation: decoder)
                await drainCastingQuality(network)
                XCTAssertEqual(probes().count, 1)
                let probe = try XCTUnwrap(probes().first)
                XCTAssertEqual(probe.loadLittleEndian(UInt32.self, at: 12), tag)
                let challenge = Data(probe.suffix(16))
                receive(.pong, challenge, flags: backoff ? 0x0040 : 0, sequence: backoff ? tag : 67)
                receive(.pong, challenge, flags: 0x0200, sequence: tag)
                var settings = Data(count: 24)
                settings[0] = 1; settings[3] = 1
                settings.storeLittleEndian(UInt64(7), at: 8)
                settings.storeLittleEndian(UInt32(27_000_000), at: 16)
                receive(.settingsState, settings)
                await drainCastingQuality(network)
                let sent = network.networkQueueForTesting.sync { writes }
                XCTAssertFalse(sent.contains { (93...99).contains($0[5]) })
                let update = try XCTUnwrap(sent.last { $0[5] == WireMessageType.settingsUpdate.rawValue })
                XCTAssertEqual(update[19], 0)
                XCTAssertEqual(update.loadLittleEndian(UInt32.self, at: 32), 12_000_000)
                XCTAssertEqual(probes().count, 1)
                XCTAssertFalse(network.adaptiveQualityAvailable)
                XCTAssertEqual(network.adaptiveQualityBackoffActive, backoff)
                XCTAssertTrue(network.legacyAutomaticBitrateUnavailable)
                XCTAssertTrue(ClientStreamSettingsStore.loadAutoQuality(hostID: host, defaults: defaults))
                if backoff { XCTAssertEqual(network.reconnectAttemptForTesting, 3) }
            }
        }
    }

    @MainActor func testCastingFallbackAndUSBRebindFenceQualityOwnerAndReservedPresentation() async throws {
        let vectors = try castingTLSFixtures()
        let video = try XCTUnwrap(vectors["video"])
        let suite = "CastingTLSCutover." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = Data(repeating: 1, count: 16)
        ClientStreamSettingsStore.save(.normalized(bitrateMbps: 27, audioEnabled: false), defaults: defaults)
        ClientStreamSettingsStore.saveAutoQuality(true, hostID: host, defaults: defaults)
        let network = NetworkManager(userDefaults: defaults)
        defer { network.stopForTesting() }
        var writes: [Data] = []
        var decoded: [UInt32] = []
        var now = 1.0
        network.adaptiveMediaClockForTesting = { now }
        network.realtimeAudioPlaybackForTesting = { enabled in XCTAssertFalse(enabled) }
        network.captureTargetScheduleForTesting = { _, _ in }
        network.captureTargetDecodeForTesting = { _, sequence, _ in decoded.append(sequence) }
        network.decoder.installAdaptiveMediaRenderer { _ in true }
        network.controlSendForAudioTesting = { data, done in writes.append(data); done(nil) }
        var peer = network.simulateCommittedWifiSessionForTesting()
        network.setAdaptiveHostForTesting(host)
        network.beginTransferWriterForTesting()
        func packets(_ type: WireMessageType) -> [Data] {
            network.networkQueueForTesting.sync { writes.filter { $0[5] == type.rawValue } }
        }
        func probes() -> [Data] {
            packets(.ping).filter { $0.loadLittleEndian(UInt16.self, at: 6) == AdaptiveMediaProtocol.probeFlag }
        }
        func receive(_ type: WireMessageType, _ payload: Data, flags: UInt16 = 0, sequence: UInt32 = 0) {
            network.receiveCaptureTargetWireForTesting(type: type, payload: payload, flags: flags, sequence: sequence,
                                                       generation: peer.generation, connection: peer.connection)
        }
        func renderBaseline(_ sequence: UInt32) async {
            receive(.video, video.payload, flags: video.header.flags, sequence: sequence)
            network.recordCapturePresentation(sequence: sequence, generation: network.decoder.currentSessionGeneration)
            await drainCastingQuality(network)
        }
        func reply(_ probe: Data) async throws -> UInt64 {
            let tag = probe.loadLittleEndian(UInt32.self, at: 12)
            receive(.pong, Data(probe.suffix(16)), flags: 0x0200, sequence: tag)
            await drainCastingQuality(network)
            let hello = try XCTUnwrap(packets(.qualityHello).last)
            let owner = hello.loadLittleEndian(UInt64.self, at: 40)
            var caps = bytes(try XCTUnwrap(try fixtures()["94"]))
            caps.storeLittleEndian(hello.loadLittleEndian(UInt64.self, at: 32), at: 8)
            caps.storeLittleEndian(owner, at: 16)
            caps.storeLittleEndian(UInt32(3_000_000), at: 28)
            caps[51] = 0
            receive(.qualityCapabilities, caps)
            await drainCastingQuality(network)
            return owner
        }
        network.beginAdaptiveMediaForTesting(baselinePresented: true)
        await drainCastingQuality(network)
        let rtpProbe = try XCTUnwrap(probes().last)
        let rtpOwner = try await reply(rtpProbe)
        let retiredDecoder = network.decoder.currentSessionGeneration
        XCTAssertTrue(network.networkQueueForTesting.sync {
            network.fallbackCommittedWifiToLegacy(generation: peer.generation)
        })
        XCTAssertNotEqual(network.decoder.currentSessionGeneration, retiredDecoder)
        network.recordCapturePresentation(sequence: 10, generation: retiredDecoder)
        await drainCastingQuality(network)
        XCTAssertEqual(probes().count, 1)
        await renderBaseline(10)
        let tlsProbe = try XCTUnwrap(probes().last)
        XCTAssertEqual(tlsProbe.loadLittleEndian(UInt32.self, at: 12), 1)
        XCTAssertNotEqual(tlsProbe.suffix(16), rtpProbe.suffix(16))
        receive(.pong, Data(rtpProbe.suffix(16)), flags: 0x0200, sequence: 1)
        receive(.pong, Data(tlsProbe.suffix(16)), flags: 0x0200, sequence: 0)
        await drainCastingQuality(network)
        XCTAssertEqual(packets(.qualityHello).count, 1)
        let tlsOwner = try await reply(tlsProbe)
        XCTAssertNotEqual(tlsOwner, rtpOwner)
        XCTAssertTrue(packets(.qualityPolicySet).isEmpty)

        var baseline = try manualBaselineState(owner: tlsOwner)
        baseline.storeLittleEndian(UInt64(2), at: 16)
        receive(.qualityState, baseline)
        receive(.qualityState, baseline)
        await drainCastingQuality(network)
        XCTAssertEqual(packets(.qualityPolicySet).count, 1)
        XCTAssertTrue(network.adaptiveQualityAvailable)
        let configuration = try XCTUnwrap(vectors["configuration"])
        var cutover = configuration.payload
        cutover.storeLittleEndian(tlsOwner, at: 8)
        cutover.storeLittleEndian(UInt32(8_000_000), at: 84)
        var missingSets = cutover
        missingSets.storeLittleEndian(UInt64(2), at: 24)
        missingSets.storeLittleEndian(UInt64(39), at: 88)
        receive(.qualityConfiguration, missingSets, sequence: 38)
        receive(.video, Data(video.payload.suffix(7)), flags: video.header.flags, sequence: 39)
        await drainCastingQuality(network)
        XCTAssertEqual(packets(.qualityConfigurationAck).map { $0[60] }, [0, 2])
        XCTAssertEqual(network.networkQueueForTesting.sync { decoded }, [10])
        receive(.qualityConfiguration, cutover, sequence: configuration.header.sequence)
        let control = try XCTUnwrap(vectors["interleavedPong"])
        receive(.pong, control.payload, flags: control.header.flags, sequence: control.header.sequence)
        receive(.video, video.payload, flags: video.header.flags, sequence: video.header.sequence)
        XCTAssertEqual(network.networkQueueForTesting.sync { decoded }, [10, 41])
        let tlsDecoder = network.decoder.currentSessionGeneration
        network.recordCapturePresentation(sequence: video.header.sequence, generation: retiredDecoder)
        network.recordCapturePresentation(sequence: control.header.sequence, generation: tlsDecoder)
        await drainCastingQuality(network)
        XCTAssertEqual(packets(.qualityConfigurationAck).map { $0[60] }, [0, 2, 0])
        network.recordCapturePresentation(sequence: video.header.sequence, generation: tlsDecoder)
        await drainCastingQuality(network)
        let acknowledgements = packets(.qualityConfigurationAck)
        XCTAssertEqual(acknowledgements.map { $0[60] }, [0, 2, 0, 1])
        XCTAssertEqual(acknowledgements.map { $0.loadLittleEndian(UInt64.self, at: 64) }, [39, 39, 41, 41])
        var applied = cutover
        applied[44] = 0
        applied.storeLittleEndian(UInt64(0), at: 88)
        receive(.qualityState, applied)
        await drainCastingQuality(network)
        XCTAssertEqual(network.adaptiveDesktopSize, CGSize(width: 3840, height: 2160))
        XCTAssertTrue(network.effectiveQualitySummary?.contains("text sharpness reduced") == true)

        receive(.video, video.payload, flags: video.header.flags, sequence: 43)
        receive(.video, video.payload, flags: video.header.flags, sequence: 43)
        network.decoder.onAdaptiveDecoded?(43, tlsDecoder, 150, 300)
        network.recordCapturePresentation(sequence: 43, generation: tlsDecoder)
        network.networkQueueForTesting.sync { now += 1.1 }
        network.sendAdaptiveFeedbackForTesting()
        await drainCastingQuality(network)
        let feedback = try XCTUnwrap(packets(.qualityFeedback).last)
        XCTAssertEqual(feedback.loadLittleEndian(UInt64.self, at: 24), tlsOwner)
        XCTAssertEqual(feedback.loadLittleEndian(UInt64.self, at: 64), UInt64(video.payload.count * 2))
        XCTAssertEqual(feedback.loadLittleEndian(UInt64.self, at: 72), 2)
        XCTAssertEqual(feedback.loadLittleEndian(UInt64.self, at: 80), 1)
        XCTAssertEqual(feedback.loadLittleEndian(UInt64.self, at: 88), 2)
        XCTAssertEqual(feedback.loadLittleEndian(UInt32.self, at: 96), 0)
        XCTAssertEqual(feedback.loadLittleEndian(UInt32.self, at: 120), 300)

        peer = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        network.setAdaptiveHostForTesting(host, usb: true)
        network.beginTransferWriterForTesting()
        network.recordCapturePresentation(sequence: 41, generation: tlsDecoder)
        await renderBaseline(10)
        let usbProbe = try XCTUnwrap(probes().last)
        XCTAssertEqual(usbProbe.loadLittleEndian(UInt32.self, at: 12), 2)
        XCTAssertNotEqual(usbProbe.suffix(16), tlsProbe.suffix(16))
        let usbOwner = try await reply(usbProbe)
        XCTAssertNotEqual(usbOwner, tlsOwner)
        baseline.storeLittleEndian(usbOwner, at: 8)
        receive(.qualityState, baseline)
        await drainCastingQuality(network)
        XCTAssertEqual(packets(.qualityPolicySet).count, 2)
        XCTAssertEqual(packets(.qualityConfigurationAck), acknowledgements)
        network.networkQueueForTesting.sync { now += 1.1 }
        network.sendAdaptiveFeedbackForTesting()
        await drainCastingQuality(network)
        let usbFeedback = try XCTUnwrap(packets(.qualityFeedback).last)
        XCTAssertEqual(usbFeedback.loadLittleEndian(UInt64.self, at: 24), usbOwner)
        XCTAssertEqual(usbFeedback.loadLittleEndian(UInt64.self, at: 48), 0)
        XCTAssertEqual(usbFeedback.loadLittleEndian(UInt64.self, at: 64), 0)

        let usbGeneration = peer.generation
        let usbDecoder = network.decoder.currentSessionGeneration
        peer = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        network.setAdaptiveHostForTesting(host)
        network.beginTransferWriterForTesting()
        XCTAssertNotEqual(peer.generation, usbGeneration)
        network.recordCapturePresentation(sequence: 10, generation: usbDecoder)
        await drainCastingQuality(network)
        XCTAssertEqual(probes().count, 3)
        await renderBaseline(10)
        let wifiProbe = try XCTUnwrap(probes().last)
        XCTAssertEqual(wifiProbe.loadLittleEndian(UInt32.self, at: 12), 1)
        XCTAssertNotEqual(wifiProbe.suffix(16), usbProbe.suffix(16))
        let wifiOwner = try await reply(wifiProbe)
        XCTAssertNotEqual(wifiOwner, usbOwner)
    }

    @MainActor private func drainCastingQuality(_ network: NetworkManager) async {
        for _ in 0..<4 {
            let drained = expectation(description: "casting quality writer and UI")
            network.networkQueueForTesting.async { DispatchQueue.main.async { drained.fulfill() } }
            await fulfillment(of: [drained], timeout: 2)
        }
    }

    @MainActor func testCastingFallbackDropsQualityHelloQueuedBehindAnInFlightWrite() async throws {
        let suite = "CastingTLSQueuedWrite." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        ClientStreamSettingsStore.save(.normalized(bitrateMbps: 27, audioEnabled: false), defaults: defaults)
        let network = NetworkManager(userDefaults: defaults)
        defer { network.stopForTesting() }
        let peer = network.simulateCommittedWifiSessionForTesting()
        network.adaptiveMediaClockForTesting = { 1 }
        network.realtimeAudioPlaybackForTesting = { enabled in XCTAssertFalse(enabled) }
        var writes: [Data] = []
        var finishPong: (() -> Void)?
        network.controlSendForAudioTesting = { frame, done in
            writes.append(frame)
            if frame[5] == WireMessageType.pong.rawValue, frame.loadLittleEndian(UInt32.self, at: 12) == 17 {
                finishPong = { done(nil) }
            } else { done(nil) }
        }
        network.beginTransferWriterForTesting()
        network.beginAdaptiveMediaForTesting(baselinePresented: true)
        await drainCastingQuality(network)
        let probe = try XCTUnwrap(network.networkQueueForTesting.sync {
            writes.first { $0[5] == WireMessageType.ping.rawValue && $0.loadLittleEndian(UInt16.self, at: 6) == 0x0200 }
        })
        network.receiveCaptureTargetWireForTesting(type: .ping, payload: Data(count: 16), sequence: 17,
            generation: peer.generation, connection: peer.connection)
        await drainCastingQuality(network)
        XCTAssertTrue(network.networkQueueForTesting.sync { finishPong != nil })
        network.receiveCaptureTargetWireForTesting(type: .pong, payload: Data(probe.suffix(16)), flags: 0x0200,
            generation: peer.generation, connection: peer.connection)
        await drainCastingQuality(network)
        XCTAssertTrue(network.networkQueueForTesting.sync {
            let fellBack = network.fallbackCommittedWifiToLegacy(generation: peer.generation)
            finishPong?()
            finishPong = nil
            return fellBack
        })
        network.receiveCaptureTargetWireForTesting(type: .ping, payload: Data(count: 16), sequence: 18,
            generation: peer.generation, connection: peer.connection)
        await drainCastingQuality(network)
        let sent = network.networkQueueForTesting.sync { writes }
        XCTAssertFalse(sent.contains { $0[5] == WireMessageType.qualityHello.rawValue })
        XCTAssertTrue(sent.contains { $0[5] == WireMessageType.pong.rawValue && $0.loadLittleEndian(UInt32.self, at: 12) == 18 })
    }

    @MainActor func testManualPlaybackResetsRetryBudgetOnlyAfterSustainedFreshPresentation() async throws {
        enum Outcome: CaseIterable { case healthy, brief, duplicate, gap, cutover, failedCutover }
        for remote in [false, true] {
            for outcome in Outcome.allCases {
                let label = "\(remote ? "remote TLS" : "casting RTP"), \(outcome)"
                let suite = "ManualReconnect." + UUID().uuidString
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let network = NetworkManager(userDefaults: defaults)
                network.stopForTesting()
                defer { network.stopForTesting() }
                var now = 0.0
                var writes: [Data] = []
                var remoteBaselineFrames: [UInt32] = []
                var configurationDeadline: (() -> Void)?
                network.adaptiveMediaClockForTesting = { now }
                network.captureTargetScheduleForTesting = { _, callback in configurationDeadline = callback }
                network.captureTargetDecodeForTesting = { _, sequence, _ in remoteBaselineFrames.append(sequence) }
                network.realtimeAudioPlaybackForTesting = { enabled in XCTAssertFalse(enabled) }
                network.controlSendForAudioTesting = { bytes, done in writes.append(bytes); done(nil) }
                network.decoder.installAdaptiveMediaRenderer { _ in true }
                let peer = network.simulateCommittedWifiSessionForTesting(
                    mode: remote ? RealtimeTransportMode.legacyTLS : RealtimeTransportMode.wifiRTP, remote: remote)
                network.setAdaptiveHostForTesting(Data(repeating: 1, count: 16))
                network.reconnectAttemptForTesting = 8
                network.beginTransferWriterForTesting()
                network.beginAdaptiveMediaForTesting(baselinePresented: true)

                func lastWrite(_ type: WireMessageType) -> Data? {
                    network.networkQueueForTesting.sync { writes.last { $0[5] == type.rawValue } }
                }
                func receive(_ type: WireMessageType, _ data: Data, flags: UInt16 = 0, sequence: UInt32 = 0) {
                    if remote {
                        network.receiveRemoteQualityFrameForTesting(remoteWireFrame(type, data, flags: flags, sequence: sequence),
                            generation: peer.generation, connection: peer.connection)
                    } else {
                        network.receiveCaptureTargetWireForTesting(type: type, payload: data, flags: flags, sequence: sequence,
                            generation: peer.generation, connection: peer.connection)
                    }
                }
                let ping = try XCTUnwrap(lastWrite(.ping), label)
                receive(.pong, Data(ping.suffix(16)), flags: 0x0200)
                let hello = try XCTUnwrap(lastWrite(.qualityHello), label)
                let owner = hello.loadLittleEndian(UInt64.self, at: 40)
                var caps = bytes(try XCTUnwrap(try fixtures()["94"]))
                caps.storeLittleEndian(hello.loadLittleEndian(UInt64.self, at: 32), at: 8)
                caps.storeLittleEndian(owner, at: 16)
                caps[51] = remote ? 1 : 0
                if !remote { caps.storeLittleEndian(UInt32(3_000_000), at: 28) }
                receive(.qualityCapabilities, caps)
                let baseline = try manualBaselineState(owner: owner)
                receive(.qualityState, baseline)

                if remote {
                    let kinds: [UInt8] = [32, 33, 34, 19]
                    let idr = Data(kinds.flatMap { [0, 0, 0, 2, $0 << 1, 1] })
                    receive(.video, idr, flags: WireProtocol.videoFlagIDR | WireProtocol.videoFlagLengthPrefixed, sequence: 1)
                    XCTAssertEqual(remoteBaselineFrames, [1], label)
                }
                let decoder = network.decoder.currentSessionGeneration
                for tick in 0...(outcome == .brief ? 2 : 20) {
                    network.networkQueueForTesting.sync {
                        now = Double(tick) * 0.25 + (outcome == .gap && tick > 10 ? 4 : 0)
                    }
                    let sequence = outcome == .duplicate ? 2 : UInt32(tick + 2)
                    XCTAssertTrue(network.admitAdaptiveFrameForTesting(sequence, isIDR: tick == 0), label)
                    network.recordCapturePresentation(sequence: sequence, generation: decoder)
                    network.networkQueueForTesting.sync {}
                }
                if outcome == .cutover || outcome == .failedCutover {
                    var cutover = baseline
                    cutover.storeLittleEndian(UInt64(2), at: 24)
                    cutover.storeLittleEndian(UInt32(1), at: 32)
                    cutover.storeLittleEndian(UInt32(2), at: 40)
                    cutover[44] = 2
                    cutover.storeLittleEndian(UInt64(81), at: 88)
                    receive(.qualityConfiguration, cutover, sequence: 80)
                    let ready = try XCTUnwrap(lastWrite(.qualityConfigurationAck), label)
                    XCTAssertEqual(ready[60], 0, label)
                    if outcome == .failedCutover {
                        try network.networkQueueForTesting.sync {
                            let expire = try XCTUnwrap(configurationDeadline, label)
                            now += 3
                            expire()
                        }
                        let failed = try XCTUnwrap(lastWrite(.qualityConfigurationAck), label)
                        XCTAssertEqual(failed[60], 2, label)
                    }
                }
                network.simulateWifiControlReceiveErrorForTesting(generation: peer.generation, connection: peer.connection)
                XCTAssertNil(network.wifiSessionSnapshotForTesting().committedGeneration, label)
                XCTAssertEqual(TrustedReconnectPolicy.delay(forAttempt: network.reconnectAttemptForTesting),
                               outcome == .healthy ? 0 : 5, label)
            }
        }
    }

    @MainActor func testRemoteTLSProbeRestoresOneSavedModePerConnectionAndPreservesManualOnDecline() async throws {
        let suite = "RemoteQuality." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = Data(repeating: 1, count: 16)
        ClientStreamSettingsStore.save(.normalized(bitrateMbps: 12, audioEnabled: false), hostID: host,
                                       remote: true, defaults: defaults)
        ClientStreamSettingsStore.saveAutoQuality(true, hostID: host, remote: true, defaults: defaults)
        let network = NetworkManager(userDefaults: defaults)
        defer { network.stopForTesting() }
        var writes: [Data] = []
        var now = 0.0
        network.adaptiveMediaClockForTesting = { now }
        network.controlSendForAudioTesting = { bytes, done in writes.append(bytes); done(nil) }
        // Settings readback can reconcile playback to off.
        network.realtimeAudioPlaybackForTesting = { enabled in
            XCTAssertFalse(enabled, "Remote quality negotiation must not start audio playback")
        }
        func drain() async {
            for _ in 0..<4 {
                let barrier = expectation(description: "remote writer and UI")
                network.networkQueueForTesting.async { DispatchQueue.main.async { barrier.fulfill() } }
                await fulfillment(of: [barrier], timeout: 2)
            }
        }
        func frames(_ type: UInt8) -> [Data] {
            network.networkQueueForTesting.sync { writes.filter { $0[5] == type } }
        }
        var owners: Set<UInt64> = []
        let replies: [(UInt16, Double)] = [(0, 0), (0x0040, 0), (0x0200, 2), (0x0200, 0), (0x0200, 0)]
        for (flags, elapsed) in replies {
            network.stopForTesting()
            network.networkQueueForTesting.sync { writes.removeAll() }
            let peer = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS, remote: true)
            network.setAdaptiveHostForTesting(host)
            network.reconnectAttemptForTesting = 3
            network.beginTransferWriterForTesting()
            network.requestCurrentSettingsForTesting(generation: peer.generation)
            network.beginAdaptiveMediaForTesting(baselinePresented: true)
            await drain()
            let ping = try XCTUnwrap(frames(6).first { $0.loadLittleEndian(UInt16.self, at: 6) == 0x0200 })
            func receive(_ type: WireMessageType, _ payload: Data, flags: UInt16 = 0) {
                network.receiveRemoteQualityFrameForTesting(remoteWireFrame(type, payload, flags: flags),
                    generation: peer.generation, connection: peer.connection)
            }
            let get = try XCTUnwrap(frames(WireMessageType.settingsGet.rawValue).last)
            var settings = Data(get.dropFirst(16))
            settings.storeLittleEndian(UInt64(1), at: 8)
            settings.storeLittleEndian(UInt32(27_000_000), at: 16)
            receive(.settingsState, settings)
            XCTAssertTrue(frames(WireMessageType.settingsUpdate.rawValue).isEmpty)
            now += elapsed
            receive(.pong, Data(ping.suffix(16)), flags: flags)
            await drain()
            if flags != 0x0200 || elapsed >= 2 {
                receive(.pong, Data(ping.suffix(16)), flags: 0x0200)
                network.beginAdaptiveMediaForTesting(baselinePresented: true)
                await drain()
                XCTAssertTrue(frames(93).isEmpty)
                XCTAssertEqual(frames(6).filter { $0.loadLittleEndian(UInt16.self, at: 6) == 0x0200 }.count, 1)
                let updates = frames(WireMessageType.settingsUpdate.rawValue)
                XCTAssertEqual(updates.count, 1)
                XCTAssertEqual(updates.last?.loadLittleEndian(UInt32.self, at: 32), 12_000_000)
                XCTAssertFalse(network.adaptiveQualityAvailable)
                if flags == 0x0040 {
                    XCTAssertTrue(network.adaptiveQualityBackoffActive)
                    XCTAssertEqual(network.reconnectAttemptForTesting, 3)
                }
                XCTAssertTrue(network.savedAutoQualityEnabled)
                continue
            }
            let hello = Data(try XCTUnwrap(frames(93).last).dropFirst(16))
            let owner = hello.loadLittleEndian(UInt64.self, at: 24)
            XCTAssertTrue(owners.insert(owner).inserted)
            var caps = bytes(try XCTUnwrap(try fixtures()["94"]))
            caps.storeLittleEndian(hello.loadLittleEndian(UInt64.self, at: 16), at: 8)
            caps.storeLittleEndian(owner, at: 16)
            receive(.qualityCapabilities, caps)
            receive(.qualityState, try manualBaselineState(owner: owner))
            await drain()
            XCTAssertTrue(network.adaptiveQualityAvailable)
            let policy = try XCTUnwrap(frames(95).last)
            XCTAssertEqual(policy[56], 2)
            XCTAssertEqual(policy[58], 1)
            XCTAssertEqual(policy.loadLittleEndian(UInt32.self, at: 60), 12_000_000)
            XCTAssertEqual(policy.loadLittleEndian(UInt32.self, at: 64), 300_000)
            XCTAssertEqual(frames(95).count, 1)
            XCTAssertTrue(frames(WireMessageType.settingsUpdate.rawValue).isEmpty)
            network.simulateWifiControlReceiveErrorForTesting(generation: peer.generation, connection: peer.connection)
            XCTAssertNil(network.wifiSessionSnapshotForTesting().committedGeneration)
            XCTAssertEqual(network.reconnectAttemptForTesting, 3, "Baseline followed by retirement keeps the retry delay")
        }
        XCTAssertEqual(ClientStreamSettingsStore.load(hostID: host, remote: true, defaults: defaults).bitrateMbps, 12)
        XCTAssertNotEqual(ClientStreamSettingsStore.load(hostID: Data(repeating: 2, count: 16), remote: true,
                                                         defaults: defaults).bitrateMbps, 12)
        XCTAssertNotEqual(ClientStreamSettingsStore.load(hostID: host, defaults: defaults).bitrateMbps, 12)
    }

    private func remoteWireFrame(_ type: WireMessageType, _ payload: Data, flags: UInt16 = 0,
                                 sequence: UInt32 = 0) -> Data {
        var wire = ConnectionControlProtocol.frame(type: type.rawValue, payload: payload, sequence: sequence)
        wire.storeLittleEndian(flags, at: 6)
        return wire
    }

    @MainActor func testRemoteTLSManualPreemptsCutoverAndRollbackPresentsOnlyItsReservedIDR() async throws {
        let suite = "RemoteQualityCutover." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = Data(repeating: 1, count: 16)
        ClientStreamSettingsStore.save(.normalized(bitrateMbps: 27, audioEnabled: false),
                                       hostID: host, remote: true, defaults: defaults)
        let network = NetworkManager(userDefaults: defaults)
        defer { network.stopForTesting() }
        let peer = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS, remote: true)
        network.setAdaptiveHostForTesting(host)
        network.reconnectAttemptForTesting = 3
        var now = 0.0
        network.adaptiveMediaClockForTesting = { now }
        network.captureTargetScheduleForTesting = { _, _ in }
        var writes: [Data] = [], decoded: [UInt32] = [], geometries: [AdaptiveMediaEffective] = []
        network.controlSendForAudioTesting = { bytes, done in writes.append(bytes); done(nil) }
        network.realtimeAudioPlaybackForTesting = { enabled in XCTAssertFalse(enabled) }
        network.captureTargetDecodeForTesting = { _, sequence, _ in decoded.append(sequence) }
        network.decoder.installAdaptiveMediaRenderer { value in
            if let value { geometries.append(value) }
            return true
        }
        network.beginTransferWriterForTesting()
        network.requestCurrentSettingsForTesting(generation: peer.generation)
        network.beginAdaptiveMediaForTesting(baselinePresented: true)
        func drain() async {
            for _ in 0..<4 {
                let barrier = expectation(description: "remote quality")
                network.networkQueueForTesting.async { DispatchQueue.main.async { barrier.fulfill() } }
                await fulfillment(of: [barrier], timeout: 2)
            }
        }
        func frames(_ type: UInt8) -> [Data] {
            network.networkQueueForTesting.sync { writes.filter { $0[5] == type } }
        }
        func receive(_ type: WireMessageType, _ payload: Data, flags: UInt16 = 0, sequence: UInt32 = 0) {
            network.receiveRemoteQualityFrameForTesting(remoteWireFrame(type, payload, flags: flags, sequence: sequence),
                generation: peer.generation, connection: peer.connection)
        }
        await drain()
        let ping = try XCTUnwrap(frames(6).last)
        receive(.pong, Data(ping.suffix(16)), flags: 0x0200)
        await drain()
        let hello = Data(try XCTUnwrap(frames(93).last).dropFirst(16))
        let owner = hello.loadLittleEndian(UInt64.self, at: 24)
        var caps = bytes(try XCTUnwrap(try fixtures()["94"]))
        caps.storeLittleEndian(hello.loadLittleEndian(UInt64.self, at: 16), at: 8)
        caps.storeLittleEndian(owner, at: 16)
        receive(.qualityCapabilities, caps)
        let baseline = try manualBaselineState(owner: owner)
        receive(.qualityState, baseline)
        let get = try XCTUnwrap(frames(WireMessageType.settingsGet.rawValue).last)
        var settings = Data(get.dropFirst(16))
        settings.storeLittleEndian(UInt64(1), at: 8)
        settings.storeLittleEndian(UInt32(27_000_000), at: 16)
        receive(.settingsState, settings)
        await drain()
        network.setAutoQualityEnabled(true)
        await drain()
        let policy = Data(try XCTUnwrap(frames(95).last).dropFirst(16))
        let request = policy.loadLittleEndian(UInt32.self, at: 32)
        var cutover = bytes(try XCTUnwrap(try fixtures()["98"]))
        cutover.storeLittleEndian(owner, at: 8)
        cutover.storeLittleEndian(UInt64(2), at: 24)
        cutover.storeLittleEndian(request, at: 32)
        cutover.storeLittleEndian(UInt32(2), at: 36)
        cutover.storeLittleEndian(UInt32(2), at: 40)
        cutover[44] = 2
        cutover.storeLittleEndian(UInt64(11), at: 88)
        receive(.qualityConfiguration, cutover, sequence: 9)
        await drain()
        XCTAssertTrue(frames(99).isEmpty, "FirstFrame must equal the Configuration sequence plus one")
        receive(.qualityConfiguration, cutover, sequence: 10)
        await drain()
        XCTAssertEqual(geometries.last?.identity.media, 1)
        XCTAssertEqual(frames(99).map { $0[60] }, [0])

        network.setAutoQualityEnabled(false)
        await drain()
        let manual = try XCTUnwrap(frames(WireMessageType.settingsUpdate.rawValue).last)
        XCTAssertEqual(manual.loadLittleEndian(UInt32.self, at: 32), 27_000_000)
        XCTAssertEqual(frames(95).count, 1, "Manual preempts through v1 SettingsUpdate")
        XCTAssertFalse(ClientStreamSettingsStore.loadAutoQuality(hostID: host, remote: true, defaults: defaults))
        var rollback = baseline
        rollback.storeLittleEndian(UInt64(3), at: 24)
        rollback.storeLittleEndian(request, at: 32)
        rollback.storeLittleEndian(cutover.loadLittleEndian(UInt32.self, at: 40), at: 40)
        rollback[44] = 2; rollback[47] = 1
        rollback.storeLittleEndian(UInt64(21), at: 88)
        receive(.qualityConfiguration, rollback, sequence: 20)
        let flags = WireProtocol.videoFlagIDR | WireProtocol.videoFlagLengthPrefixed
        let nalKinds: [UInt8] = [32, 33, 34, 19]
        let idr = Data(nalKinds.flatMap { [0, 0, 0, 2, $0 << 1, 1] })
        receive(.video, idr, flags: flags, sequence: 11)
        XCTAssertTrue(decoded.isEmpty)
        XCTAssertEqual(geometries.last?.identity.media, 1)
        let before = network.decoder.invalidateCountForTesting
        receive(.video, idr, flags: flags, sequence: 21)
        XCTAssertEqual(network.decoder.invalidateCountForTesting, before + 1)
        XCTAssertEqual(decoded, [21])
        XCTAssertEqual(geometries.last?.identity.media, 3)
        XCTAssertEqual(frames(99).map { $0[60] }, [0, 0])
        network.recordCapturePresentation(sequence: 21, generation: network.decoder.currentSessionGeneration)
        await drain()
        XCTAssertEqual(frames(99).map { $0[60] }, [0, 0, 1])
        rollback[44] = 1
        receive(.qualityState, rollback)
        await drain()
        XCTAssertEqual(network.reconnectAttemptForTesting, 3)
        XCTAssertFalse(network.autoQualityEnabled)

        receive(.settingsApplied, Data(manual.dropFirst(16)))
        network.setAutoQualityEnabled(true)
        await drain()
        let nextPolicy = Data(try XCTUnwrap(frames(95).last).dropFirst(16))
        XCTAssertEqual(frames(95).count, 2, "A new opt-in is allowed after the Manual reply")
        cutover.storeLittleEndian(nextPolicy.loadLittleEndian(UInt32.self, at: 32), at: 32)
        cutover.storeLittleEndian(UInt64(4), at: 24)
        cutover.storeLittleEndian(UInt32(3), at: 40)
        cutover.storeLittleEndian(UInt64(31), at: 88)
        receive(.qualityConfiguration, cutover, sequence: 30)
        receive(.video, idr, flags: flags, sequence: 31)
        XCTAssertEqual(decoded, [21, 31])
        network.recordCapturePresentation(sequence: 31, generation: network.decoder.currentSessionGeneration)
        await drain()
        XCTAssertEqual(frames(99).map { $0[60] }, [0, 0, 1, 0, 1])
        cutover[44] = 0
        receive(.qualityState, cutover)
        await drain()
        XCTAssertEqual(network.reconnectAttemptForTesting, 0)
        XCTAssertTrue(network.effectiveQualitySummary?.contains("text sharpness reduced") == true)
        now = 0.9
        network.sendAdaptiveFeedbackForTesting()
        network.sendAdaptiveFeedbackForTesting()
        await drain()
        let windows = frames(97)
        XCTAssertEqual(windows.count, 1)
        let feedback = Data(try XCTUnwrap(windows.first).dropFirst(16))
        XCTAssertEqual(feedback.loadLittleEndian(UInt64.self, at: 24), 4)
        XCTAssertEqual(feedback.loadLittleEndian(UInt32.self, at: 40), 900_000)
        XCTAssertEqual(feedback[144] & 8, 0)

        cutover[44] = 2
        cutover.storeLittleEndian(UInt64(5), at: 24)
        cutover.storeLittleEndian(UInt32(4), at: 40)
        cutover.storeLittleEndian(UInt64(41), at: 88)
        receive(.qualityConfiguration, cutover, sequence: 40)
        let idrWithoutParameterSets = Data([0, 0, 0, 2, 38, 1])
        receive(.video, idrWithoutParameterSets, flags: flags, sequence: 41)
        await drain()
        XCTAssertEqual(Array(frames(99).suffix(2)).map { $0[60] }, [0, 2])
        XCTAssertEqual(decoded, [21, 31])
        XCTAssertEqual(geometries.last?.identity.media, 4)
    }

    func testRemoteTLSFeedbackUsesServiceWindowWithoutChangingCastingCadence() throws {
        let identity = AdaptiveMediaIdentity(owner: 1, source: 1, media: 1)
        var window = AdaptiveMediaWindow(started: 0)
        XCTAssertNil(window.sample(identity: identity, now: 0.74, activity: 3, remote: true))
        let packet = try XCTUnwrap(window.sample(identity: identity, now: 0.9, activity: 3, remote: true))
        XCTAssertEqual(packet.u32(40), 900_000)
        XCTAssertEqual(packet.encoded[144], 3)
        XCTAssertNil(window.sample(identity: identity, now: 2, activity: 3, remote: true))
        XCTAssertNil(window.sample(identity: identity, now: 2.5, activity: 3))
    }

    @MainActor func testRemoteScaledMediaKeepsTouchPencilAndMouseDragInDesktopCoordinates() throws {
        let container = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let engine = IPadInputEngine(clock: { 0 })
        engine.enabled = true; engine.directAvailable = true
        var events: [IPadInputEvent] = []
        engine.emit = { events.append($0) }
        var priorViewport: VideoContentViewport?
        let scales: [UInt16] = [7500, 5000]
        for scale in scales {
            var payload = bytes(try XCTUnwrap(try fixtures()["96"]))
            let width = UInt32(3840) * UInt32(scale) / 10000
            let height = UInt32(2160) * UInt32(scale) / 10000
            payload.storeLittleEndian(width, at: 56)
            payload.storeLittleEndian(height, at: 60)
            payload.storeLittleEndian(width, at: 72)
            payload.storeLittleEndian(height, at: 76)
            payload.storeLittleEndian(scale, at: 82)
            payload.storeLittleEndian(UInt32(scale == 5000 ? 1 : 0), at: 96)
            let state = try XCTUnwrap(AdaptiveMediaProtocol.decode(type: 96, data: payload)?.effective)
            XCTAssertTrue(state.displaySummary(remote: true).contains("text sharpness reduced"))
            let viewport = try XCTUnwrap(Renderer.contentViewport(forDrawableSize: container.size, videoSize: state.desktopSize))
            XCTAssertNil(viewport.normalizedPoint(for: CGPoint(x: 600, y: 0), in: container), "Padding remains noninteractive")
            if let priorViewport { XCTAssertEqual(viewport, priorViewport) }
            let center = CGPoint(x: 600, y: 400)
            let normalized = try XCTUnwrap(viewport.normalizedPoint(for: center, in: container))
            XCTAssertEqual(normalized, CGPoint(x: 0.5, y: 0.5))
            if priorViewport == nil {
                engine.begin(id: 1, pencil: false, point: center, normalized: normalized)
                XCTAssertTrue(events.contains(.touch(.down, 1, normalized, 255)))
                engine.end(id: 1, point: center, normalized: normalized, cancelled: false)
                engine.pencilHover(at: normalized)
                XCTAssertTrue(events.contains(.pointer(0, 0, 32768, 32768)))
                engine.pencilHover(at: nil)
                engine.external(point: center, normalized: normalized, buttons: 1)
            } else {
                engine.external(point: center, normalized: normalized, buttons: 1)
                engine.external(point: center, normalized: normalized, buttons: 0)
            }
            priorViewport = viewport
        }
        let buttonActions: [UInt8] = events.compactMap {
            if case .button(1, let action, _) = $0 { return action }
            return nil
        }
        XCTAssertEqual(buttonActions, [0, 1], "The same held mouse drag crosses the media change")
    }

    @MainActor func testBackoffPongUsesSavedManualForThisConnectionAndFreshConnectionProbesAgain() async throws {
        let suite = "CastingQualityBackoff." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = Data(repeating: 1, count: 16)
        ClientStreamSettingsStore.save(.normalized(bitrateMbps: 27, audioEnabled: false), defaults: defaults)
        ClientStreamSettingsStore.save(.normalized(bitrateMbps: 12, audioEnabled: false, adaptiveBitrateEnabled: true),
                                       hostID: host, defaults: defaults)
        let network = NetworkManager(userDefaults: defaults)
        defer { network.stopForTesting() }
        var now = 0.0
        var writes: [Data] = []
        network.adaptiveMediaClockForTesting = { now }
        network.realtimeAudioPlaybackForTesting = { enabled in XCTAssertFalse(enabled) }
        network.controlSendForAudioTesting = { data, done in writes.append(data); done(nil) }
        func drain() async {
            for _ in 0..<4 {
                let ready = expectation(description: "control and publication barrier")
                network.networkQueueForTesting.async { DispatchQueue.main.async { ready.fulfill() } }
                await fulfillment(of: [ready], timeout: 2)
            }
        }
        func sentProbes() -> [Data] {
            network.networkQueueForTesting.sync {
                writes.filter { $0[5] == WireMessageType.ping.rawValue && $0.loadLittleEndian(UInt16.self, at: 6) == 0x0200 }
            }
        }

        for savedAuto in [true, false] {
            network.stopForTesting()
            ClientStreamSettingsStore.saveAutoQuality(savedAuto, hostID: host, defaults: defaults)
            let peer = network.simulateCommittedWifiSessionForTesting()
            network.setAdaptiveHostForTesting(host)
            network.reconnectAttemptForTesting = 3
            network.beginTransferWriterForTesting()
            network.requestCurrentSettingsForTesting(generation: peer.generation)
            let priorProbeCount = sentProbes().count
            network.beginAdaptiveMediaForTesting(baselinePresented: true)
            await drain()
            XCTAssertEqual(sentProbes().count, priorProbeCount + 1)
            let probe = try XCTUnwrap(sentProbes().last)
            func receive(_ type: WireMessageType, _ payload: Data, flags: UInt16 = 0) {
                network.receiveCaptureTargetWireForTesting(type: type, payload: payload, flags: flags,
                    generation: peer.generation, connection: peer.connection)
            }
            func reportLegacyAutomaticBitrate() {
                var state = Data(count: 24)
                state[0] = 1; state[3] = 1
                state.storeLittleEndian(UInt64(7), at: 8)
                state.storeLittleEndian(UInt32(12_000_000), at: 16)
                receive(.settingsState, state)
            }
            // The older AutoBitrate path is in sync before the decline. After
            // it, a fresh read of that same revision must reconcile to Manual.
            if !savedAuto { reportLegacyAutomaticBitrate(); await drain() }
            let beforePong = network.networkQueueForTesting.sync { writes.count }
            now += 1
            receive(.pong, Data(probe.suffix(16)), flags: 0x0040)
            receive(.pong, Data(probe.suffix(16)), flags: 0x0200)
            network.beginAdaptiveMediaForTesting(baselinePresented: true)
            reportLegacyAutomaticBitrate()
            await drain()
            let afterPong = network.networkQueueForTesting.sync { Array(writes.dropFirst(beforePong)) }
            let update = try XCTUnwrap(afterPong.last { $0[5] == WireMessageType.settingsUpdate.rawValue })
            XCTAssertEqual(update[19], 0)
            XCTAssertEqual(update.loadLittleEndian(UInt32.self, at: 32), 12_000_000)
            XCTAssertFalse(afterPong.contains { (93...99).contains($0[5]) })
            XCTAssertEqual(sentProbes().count, priorProbeCount + 1)
            XCTAssertEqual(network.adaptiveQualityUnavailableReason, "Auto temporarily unavailable after a failed quality switch")
            XCTAssertFalse(network.adaptiveQualityAvailable)
            XCTAssertFalse(network.autoQualityEnabled)
            XCTAssertEqual(network.savedAutoQualityEnabled, savedAuto)
            XCTAssertEqual(ClientStreamSettingsStore.loadAutoQuality(hostID: host, defaults: defaults), savedAuto)
            XCTAssertTrue(network.wifiSessionSnapshotForTesting().connection === peer.connection)
            XCTAssertEqual(network.wifiSessionSnapshotForTesting().committedGeneration, peer.generation)
            XCTAssertEqual(network.reconnectAttemptForTesting, 3)
        }

        network.stopForTesting()
        let next = network.simulateCommittedWifiSessionForTesting()
        network.setAdaptiveHostForTesting(host)
        network.beginTransferWriterForTesting()
        network.beginAdaptiveMediaForTesting(baselinePresented: true)
        await drain()
        XCTAssertEqual(sentProbes().count, 3)
        let probe = try XCTUnwrap(sentProbes().last)
        network.receiveCaptureTargetWireForTesting(type: .pong, payload: Data(probe.suffix(16)), flags: 0x0200,
            generation: next.generation, connection: next.connection)
        await drain()
        XCTAssertTrue(network.networkQueueForTesting.sync { writes.contains { $0[5] == 93 } })
        XCTAssertNotEqual(network.adaptiveQualityUnavailableReason, "Auto temporarily unavailable after a failed quality switch")
    }

    @MainActor func testRealWriterNeverSendsDS2BeforeExactPongOrForRemote() async throws {
        for remote in [false,true] {
            let network=NetworkManager(); network.adaptiveMediaClockForTesting={ 0 }; var writes:[Data]=[]
            network.controlSendForAudioTesting={ data,done in writes.append(data); done(nil) }
            network.realtimeAudioPlaybackForTesting={ _ in XCTFail("No audio in DS2 tests") }
            let peer=network.simulateCommittedWifiSessionForTesting(mode:RealtimeTransportMode.wifiRTP,remote:remote)
            defer { network.stopForTesting() }; network.beginTransferWriterForTesting()
            network.beginAdaptiveMediaForTesting(baselinePresented: true)
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
    @MainActor func testSourceRequestLetsRollbackPresentAndKeepsOldVideoAfterBusy() async throws {
        do {
            let mode = RealtimeTransportMode.wifiRTP
            let network = NetworkManager()
            network.adaptiveMediaClockForTesting = { 0 }
            network.captureTargetScheduleForTesting = { _, _ in }
            network.realtimeAudioPlaybackForTesting = { _ in XCTFail("No audio in DS2 tests") }
            var writes: [Data] = [], decodes: [(UInt32, UInt64)] = []
            network.controlSendForAudioTesting = { bytes, done in writes.append(bytes); done(nil) }
            network.captureTargetDecodeForTesting = { _, sequence, generation in decodes.append((sequence, generation)) }
            let peer = network.simulateCommittedWifiSessionForTesting(mode: mode)
            defer { network.stopForTesting() }
            network.beginTransferWriterForTesting()
            network.decoder.onAdaptiveMedia = { _ in true }
            network.beginAdaptiveMediaForTesting(baselinePresented: true)
            func drain() async {
                for _ in 0..<4 {
                    network.networkQueueForTesting.sync {}
                    let ready = expectation(description: "source and rollback publication")
                    DispatchQueue.main.async { ready.fulfill() }
                    await fulfillment(of: [ready], timeout: 2)
                }
                network.networkQueueForTesting.sync {}
            }
            func receive(_ type: WireMessageType, _ data: Data, flags: UInt16 = 0, sequence: UInt32 = 0) {
                network.receiveCaptureTargetWireForTesting(type: type, payload: data, flags: flags, sequence: sequence,
                    generation: peer.generation, connection: peer.connection)
            }
            func video(_ sequence: UInt32, isIDR: Bool) {
                network.receiveCaptureTargetVideoForTesting(Data([1]), sequence: sequence, isIDR: isIDR,
                    generation: peer.generation, connection: peer.connection)
            }

            await drain()
            let ping = try XCTUnwrap(writes.first { $0[5] == WireMessageType.ping.rawValue && $0[7] & 2 != 0 })
            receive(.pong, Data(ping.suffix(16)), flags: AdaptiveMediaProtocol.probeFlag)
            await drain()
            let hello = try XCTUnwrap(writes.first { $0[5] == WireMessageType.qualityHello.rawValue })
            let owner = hello.loadLittleEndian(UInt64.self, at: 40)
            var caps = bytes(try XCTUnwrap(try fixtures()["94"]))
            caps.storeLittleEndian(hello.loadLittleEndian(UInt64.self, at: 32), at: 8)
            caps.storeLittleEndian(owner, at: 16); caps[51] = 0
            caps.storeLittleEndian(UInt32(3_000_000), at: 28)
            receive(.qualityCapabilities, caps)
            var baseline = try effective().packet.encoded
            baseline.storeLittleEndian(owner, at: 8)
            receive(.qualityState, baseline)
            var proposed = try effective(98, media: 4, first: 80).packet.encoded
            proposed.storeLittleEndian(owner, at: 8); proposed[44] = 2
            receive(.qualityConfiguration, proposed)
            receive(.displayCapabilities, CaptureTargetIntegrationTests.modes, flags: 0x7c00)
            receive(.mirrorState, try CaptureTargetIntegrationTests.mode(revision: 1, epoch: 2, physical: false))
            receive(.sourceCatalogue, CaptureTargetIntegrationTests.catalogue(revision: 3, current: 1))
            await drain()
            network.requestCaptureTarget(4, catalogue: try XCTUnwrap(network.captureTargetState.catalogue))
            await drain()
            XCTAssertTrue(network.captureTargetState.inputBlocked)
            XCTAssertEqual(writes.filter { $0[5] == WireMessageType.sourceSwitchRequest.rawValue }.count, 1)
            XCTAssertEqual(writes.filter { $0[5] == WireMessageType.qualityConfigurationAck.rawValue }.map { $0[60] }, [0])

            var rollback = proposed
            rollback.storeLittleEndian(UInt64(5), at: 24)
            rollback.storeLittleEndian(UInt32(8), at: 40)
            rollback.storeLittleEndian(UInt64(90), at: 88)
            receive(.qualityConfiguration, rollback) // Ordinary adaptation still loses to selection.
            var otherSource = rollback
            otherSource[47] = 7
            otherSource.storeLittleEndian(UInt64(3), at: 16)
            receive(.qualityConfiguration, otherSource)
            rollback[47] = 7
            receive(.qualityConfiguration, rollback)
            video(89, isIDR: true); video(90, isIDR: false); video(90, isIDR: true)
            await drain()
            XCTAssertEqual(decodes.map { $0.0 }, [90])
            let decoder = try XCTUnwrap(decodes.first?.1)
            network.recordCapturePresentation(sequence: 90, generation: decoder)
            await drain()
            let acks = writes.filter { $0[5] == WireMessageType.qualityConfigurationAck.rawValue }
            XCTAssertEqual(acks.map { $0[60] }, [0, 0, 1])
            XCTAssertEqual(acks.suffix(2).map { $0.loadLittleEndian(UInt64.self, at: 40) }, [5, 5])
            XCTAssertNotNil(network.captureTargetState.pending)
            XCTAssertTrue(network.captureTargetState.inputBlocked)

            rollback[44] = 0
            rollback.storeLittleEndian(UInt64(0), at: 88)
            receive(.qualityState, rollback)
            receive(.sourceCatalogue, CaptureTargetIntegrationTests.catalogue(revision: 4, current: 1))
            receive(.sourceSwitchResult, CaptureTargetIntegrationTests.result(status: 5, current: 1))
            video(91, isIDR: false)
            await drain()
            XCTAssertNil(network.captureTargetState.pending)
            XCTAssertEqual(network.captureTargetState.issue, .busy)
            XCTAssertEqual(decodes.map { $0.0 }, [90, 91])
            XCTAssertTrue(decodes.allSatisfy { $0.1 == decoder })
            XCTAssertEqual(writes.filter { $0[5] == WireMessageType.sourceSwitchRequest.rawValue }.count, 1)
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
        let hostID = Data(repeating: 1, count: 16)
        let peer=network.simulateCommittedWifiSessionForTesting(mode:RealtimeTransportMode.wifiRTP)
        network.setAdaptiveHostForTesting(hostID)
        defer { network.stopForTesting() }; network.beginTransferWriterForTesting()
        network.decoder.onAdaptiveMedia={ _ in true }
        network.beginAdaptiveMediaForTesting(baselinePresented: true)
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
        network.reconnectAttemptForTesting = 3
        receive(.qualityState,baseline); await drain()
        XCTAssertEqual(network.reconnectAttemptForTesting, 3, "Baseline quality does not prove a structural cutover")
        XCTAssertTrue(network.adaptiveQualityAvailable); XCTAssertFalse(network.autoQualityEnabled)
        XCTAssertFalse(writes.contains { $0[5] == 95 },"Negotiation alone is not opt-in")
        now = 1
        network.sendAdaptiveFeedbackForTesting(); await drain()
        let baselineWindow = Data(try XCTUnwrap(writes.last { $0[5] == 97 }).dropFirst(16))
        XCTAssertTrue(network.admitAdaptiveFrameForTesting(79, isIDR: true))
        network.setAutoQualityEnabled(true); await drain()
        XCTAssertTrue(ClientStreamSettingsStore.loadAutoQuality(hostID: hostID, defaults: defaults))
        XCTAssertEqual(writes.filter { $0[5] == 95 }.count,1)
        var configuration=try effective(98,media:4,first:80).packet.encoded; configuration.storeLittleEndian(owner,at:8)
        configuration.storeLittleEndian(UInt32(1),at:32)
        receive(.qualityConfiguration,configuration); await drain()
        XCTAssertEqual(writes.filter { $0[5] == 99 }.map { $0[16+44] },[0])
        now = 1.99
        network.sendAdaptiveFeedbackForTesting(); await drain()
        XCTAssertEqual(writes.filter { $0[5] == 97 }.count, 1)
        now = 2.125
        network.sendAdaptiveFeedbackForTesting(); await drain()
        let cutoverWindow = Data(try XCTUnwrap(writes.last { $0[5] == 97 }).dropFirst(16))
        XCTAssertEqual(cutoverWindow.loadLittleEndian(UInt64.self,at:24),4)
        XCTAssertEqual(cutoverWindow.loadLittleEndian(UInt64.self,at:32),baselineWindow.loadLittleEndian(UInt64.self,at:32) &+ 1)
        XCTAssertEqual(cutoverWindow.loadLittleEndian(UInt64.self,at:56),0, "Discard unsent receive counts from the old epoch")
        XCTAssertEqual(cutoverWindow.loadLittleEndian(UInt64.self,at:120),0)
        XCTAssertEqual(cutoverWindow[144] & 0x0C, 4, "Recovery is active during a cutover; saturation is host-derived")
        XCTAssertFalse(network.admitAdaptiveFrameForTesting(79,isIDR:true))
        let frameBytes = 25_000
        let frameReceiveUs: UInt32 = 4_000
        XCTAssertTrue(network.admitAdaptiveFrameForTesting(80,isIDR:true,bytes:frameBytes,receiveUs:frameReceiveUs))
        network.decoder.onAdaptiveDecoded?(80,network.decoder.currentSessionGeneration,200,300)
        network.recordCapturePresentation(sequence:80,generation:network.decoder.currentSessionGeneration)
        await drain()
        XCTAssertEqual(writes.filter { $0[5] == 99 }.map { $0[16+44] },[0,1])
        XCTAssertEqual(network.reconnectAttemptForTesting, 3, "Wait for the host's Applied state after Presented")
        var applied=configuration; applied.storeLittleEndian(UInt64(0),at:88)
        receive(.qualityState,applied); await drain()
        XCTAssertEqual(network.reconnectAttemptForTesting, 0)
        XCTAssertTrue(network.effectiveQualitySummary?.contains("text sharpness reduced") == true)
        XCTAssertFalse(network.admitAdaptiveFrameForTesting(79,isIDR:true))
        network.decoder.installAdaptiveMediaRenderer { _ in true }
        for frame in UInt32(81)..<110 {
            XCTAssertTrue(network.admitAdaptiveFrameForTesting(frame, isIDR: false, bytes: frameBytes, receiveUs: frameReceiveUs))
            network.decoder.onAdaptiveDecoded?(frame, network.decoder.currentSessionGeneration, 200, 300)
            network.recordCapturePresentation(sequence: frame, generation: network.decoder.currentSessionGeneration)
        }
        now=3.25; network.sendAdaptiveFeedbackForTesting(); await drain()
        let feedback=Data(try XCTUnwrap(writes.last { $0[5] == 97 }).dropFirst(16))
        XCTAssertEqual(feedback[144], 3)
        XCTAssertEqual(feedback.loadLittleEndian(UInt32.self,at:40),1_125_000)
        XCTAssertEqual(feedback.loadLittleEndian(UInt32.self,at:44) & 7,7)
        XCTAssertEqual(feedback.loadLittleEndian(UInt32.self,at:96),120_000)
        XCTAssertEqual(feedback.loadLittleEndian(UInt64.self,at:48),750_000)
        for offset in [56,64,72] {
            XCTAssertEqual(feedback.loadLittleEndian(UInt64.self,at:offset),30)
        }
        let sentWindows = writes.filter { $0[5] == 97 }.count
        network.sendAdaptiveFeedbackForTesting(); await drain()
        XCTAssertEqual(writes.filter { $0[5] == 97 }.count, sentWindows)
        network.setAutoQualityEnabled(false); await drain()
        receive(.qualityState,applied); await drain()
        let policies=writes.filter { $0[5] == 95 }
        XCTAssertEqual(policies.count,2); XCTAssertEqual(policies.last?[16+40],0)
        XCTAssertFalse(ClientStreamSettingsStore.loadAutoQuality(hostID: hostID, defaults: defaults))
        XCTAssertEqual(policies.last?.loadLittleEndian(UInt32.self,at:16+44),UInt32(network.desiredBitrateMbps*1_000_000))
    }

    @MainActor func testRollbackConnectionLossDropsOldEpochBeforeReconnecting() async throws {
        let suite = "AdaptiveMediaReconnect." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let network = NetworkManager(userDefaults: defaults)
        defer { network.stopForTesting() }
        network.stopForTesting()
        var now = 0.0
        var writes: [Data] = []
        network.adaptiveMediaClockForTesting = { now }
        network.captureTargetScheduleForTesting = { _, _ in }
        network.controlSendForAudioTesting = { data, done in writes.append(data); done(nil) }
        network.realtimeAudioPlaybackForTesting = { _ in XCTFail("No audio in DS2 tests") }
        var decoderGeometry: [AdaptiveMediaIdentity?] = []
        network.decoder.installAdaptiveMediaRenderer { decoderGeometry.append($0?.identity); return true }
        func drain() async {
            for _ in 0..<4 {
                let ready = expectation(description: "control queue barrier")
                network.networkQueueForTesting.async { ready.fulfill() }
                await fulfillment(of: [ready], timeout: 2)
            }
        }
        var peer = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.wifiRTP)
        func receive(_ type: WireMessageType, _ data: Data, flags: UInt16 = 0) {
            network.receiveCaptureTargetWireForTesting(type: type, payload: data, flags: flags,
                                                       generation: peer.generation, connection: peer.connection)
        }
        func negotiate() async throws -> UInt64 {
            network.beginTransferWriterForTesting()
            network.beginAdaptiveMediaForTesting(baselinePresented: true)
            await drain()
            let probe = try XCTUnwrap(writes.last { $0[5] == 6 && $0.loadLittleEndian(UInt16.self, at: 6) & 0x0200 != 0 })
            receive(.pong, Data(probe.suffix(16)), flags: 0x0200)
            await drain()
            let hello = Data(try XCTUnwrap(writes.last { $0[5] == 93 }).dropFirst(16))
            let owner = hello.loadLittleEndian(UInt64.self, at: 24)
            var caps = bytes(try XCTUnwrap(try fixtures()["94"]))
            caps.storeLittleEndian(hello.loadLittleEndian(UInt64.self, at: 16), at: 8)
            caps.storeLittleEndian(owner, at: 16)
            caps[51] = 0
            caps.storeLittleEndian(UInt32(3_000_000), at: 28)
            receive(.qualityCapabilities, caps)
            var baseline = try effective().packet.encoded
            baseline.storeLittleEndian(owner, at: 8)
            receive(.qualityState, baseline)
            return owner
        }
        let oldOwner = try await negotiate()
        let oldDecoder = network.decoder.currentSessionGeneration
        var rollback = try effective(98, media: 4, first: 80).packet.encoded
        rollback.storeLittleEndian(oldOwner, at: 8)
        rollback[44] = 2
        rollback[47] = 7
        receive(.qualityConfiguration, rollback)
        await drain()
        XCTAssertTrue(writes.contains { $0[5] == 99 && $0[16+44] == 0 })
        XCTAssertEqual(decoderGeometry.last.flatMap { $0 }?.media, 4)
        XCTAssertTrue(network.admitAdaptiveFrameForTesting(80, isIDR: true))

        let invalidations = network.decoder.invalidateCountForTesting
        network.reconnectAttemptForTesting = 3
        network.simulateWifiControlReceiveErrorForTesting(generation: peer.generation, connection: peer.connection)
        XCTAssertEqual(network.reconnectAttemptForTesting, 3)
        XCTAssertGreaterThan(network.decoder.invalidateCountForTesting, invalidations)
        XCTAssertNil(decoderGeometry.last.flatMap { $0 })
        peer = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.wifiRTP)
        let newOwner = try await negotiate()
        XCTAssertEqual(network.reconnectAttemptForTesting, 3, "A fresh owner and baseline retain the existing retry delay")
        XCTAssertNotEqual(newOwner, oldOwner)
        XCTAssertNotEqual(network.decoder.currentSessionGeneration, oldDecoder)
        receive(.qualityConfiguration, rollback)
        network.decoder.onAdaptiveDecoded?(80, oldDecoder, 100, 100)
        network.recordCapturePresentation(sequence: 80, generation: oldDecoder)
        now = 1
        network.sendAdaptiveFeedbackForTesting()
        await drain()
        XCTAssertEqual(decoderGeometry.last.flatMap { $0 }?.owner, newOwner)
        XCTAssertEqual(writes.filter { $0[5] == 99 }.count, 1, "Late rollback cannot affect the replacement")
        let feedback = Data(try XCTUnwrap(writes.last { $0[5] == 97 }).dropFirst(16))
        XCTAssertEqual(feedback.loadLittleEndian(UInt64.self, at: 8), newOwner)
        XCTAssertEqual(feedback.loadLittleEndian(UInt64.self, at: 24), 3)
        XCTAssertEqual(feedback.loadLittleEndian(UInt64.self, at: 32), 0)
        for offset in [48, 56, 64, 72] {
            XCTAssertEqual(feedback.loadLittleEndian(UInt64.self, at: offset), 0)
        }
        XCTAssertTrue(network.admitAdaptiveFrameForTesting(1, isIDR: true), "The retired FirstFrame floor must not survive")
    }

    @MainActor func testSavedCastingAutoReturnsOnNegotiatedConnectionsAndReappliesOnce() async throws {
        let suite = "CastingQualityConnections." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hostID = Data(repeating: 1, count: 16)
        let otherHostID = Data(repeating: 2, count: 16)
        ClientStreamSettingsStore.saveAutoQuality(true, hostID: hostID, defaults: defaults)
        ClientStreamSettingsStore.save(.normalized(bitrateMbps: 31, audioEnabled: false, adaptiveBitrateEnabled: true),
                                       defaults: defaults)
        let network = NetworkManager(userDefaults: defaults)
        network.realtimeAudioPlaybackForTesting = { enabled in XCTAssertFalse(enabled) }
        network.controlSendForAudioTesting = { _, done in done(nil) }
        for (editedHost, bitrate) in [(hostID, 12.0), (otherHostID, 27.0)] {
            _ = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
            network.setAdaptiveHostForTesting(editedHost)
            network.beginTransferWriterForTesting()
            network.setDesiredStreamSettings(bitrateMbps: bitrate, audioEnabled: false, adaptiveBitrateEnabled: true)
            network.networkQueueForTesting.sync {}
            network.stopForTesting()
        }
        XCTAssertEqual(ClientStreamSettingsStore.load(defaults: defaults).bitrateMbps, 31)
        var now = 0.0
        var priorOwner: UInt64?
        for (mode, usb, oldHost, pairedHost) in [
            (RealtimeTransportMode.wifiRTP, false, false, hostID),
            (RealtimeTransportMode.legacyTLS, false, false, hostID),
            (RealtimeTransportMode.legacyTLS, true, false, hostID),
            (RealtimeTransportMode.wifiRTP, false, true, hostID),
            (RealtimeTransportMode.wifiRTP, false, false, otherHostID),
            (RealtimeTransportMode.wifiRTP, false, false, hostID)
        ] {
            defer { network.stopForTesting() }
            var writes: [Data] = []
            network.adaptiveMediaClockForTesting = { now }
            network.controlSendForAudioTesting = { data, done in writes.append(data); done(nil) }
            let peer = network.simulateCommittedWifiSessionForTesting(mode: mode)
            let latePairing = priorOwner == nil
            if !latePairing { network.setAdaptiveHostForTesting(pairedHost, usb: usb) }
            network.beginTransferWriterForTesting()
            network.requestCurrentSettingsForTesting(generation: peer.generation)
            network.beginAdaptiveMediaForTesting(baselinePresented: mode == RealtimeTransportMode.wifiRTP)
            func drain() async {
                for _ in 0..<3 {
                    network.networkQueueForTesting.sync {}
                    let ready = expectation(description: "settings publication")
                    DispatchQueue.main.async { ready.fulfill() }
                    await fulfillment(of: [ready], timeout: 2)
                }
            }
            func receive(_ type: WireMessageType, _ data: Data, flags: UInt16 = 0) {
                network.receiveCaptureTargetWireForTesting(type: type, payload: data, flags: flags,
                                                           generation: peer.generation, connection: peer.connection)
            }
            func reportLegacyAutoBitrate() {
                var state = Data(count: 24)
                state[0] = 1; state[3] = 1
                state.storeLittleEndian(UInt64(7), at: 8)
                state.storeLittleEndian(UInt32(31_000_000), at: 16)
                receive(.settingsState, state)
            }
            await drain()
            let probe = writes.first { $0[5] == WireMessageType.ping.rawValue && $0.loadLittleEndian(UInt16.self, at: 6) == 0x0200 }
            if mode == RealtimeTransportMode.legacyTLS {
                XCTAssertNil(probe)
            } else if oldHost {
                let echo = Data(try XCTUnwrap(probe).suffix(16))
                receive(.pong, echo)
                now += 3
                receive(.pong, echo, flags: 0x0200)
                await drain()
            } else {
                let echo = Data(try XCTUnwrap(probe).suffix(16))
                receive(.pong, echo, flags: 0x0200)
                await drain()
                let hello = try XCTUnwrap(writes.first { $0[5] == 93 })
                let owner = hello.loadLittleEndian(UInt64.self, at: 40)
                var caps = bytes(try XCTUnwrap(try fixtures()["94"]))
                caps.storeLittleEndian(hello.loadLittleEndian(UInt64.self, at: 32), at: 8)
                caps.storeLittleEndian(owner, at: 16)
                caps[51] = 0
                caps.storeLittleEndian(UInt32(3_000_000), at: 28)
                receive(.qualityCapabilities, caps)
                await drain()
                XCTAssertFalse(writes.contains { $0[5] == 95 }, "Wait for the current owner and policy revision")
                var baseline = try effective().packet.encoded
                baseline.storeLittleEndian(owner, at: 8)
                receive(.qualityState, baseline)
                receive(.qualityState, baseline)
                await drain()
                if latePairing {
                    XCTAssertFalse(network.adaptiveQualityAvailable)
                    XCTAssertFalse(writes.contains { $0[5] == 95 })
                    network.setAdaptiveHostForTesting(pairedHost)
                    await drain()
                }
                let policy = writes.filter { $0[5] == 95 }
                if pairedHost == hostID {
                    XCTAssertEqual(policy.map { $0[56] }, [2])
                    XCTAssertEqual(policy.first?.loadLittleEndian(UInt32.self, at: 60), 12_000_000)
                    if let priorOwner {
                        XCTAssertNotEqual(owner, priorOwner)
                    } else {
                        XCTAssertTrue(network.adaptiveQualityAvailable)
                        XCTAssertTrue(network.autoQualityEnabled)
                        let beforeFallback = writes.count
                        XCTAssertTrue(network.networkQueueForTesting.sync {
                            network.fallbackCommittedWifiToLegacy(generation: peer.generation)
                        })
                        receive(.qualityState, baseline)
                        reportLegacyAutoBitrate()
                        await drain()
                        XCTAssertFalse(network.adaptiveQualityAvailable)
                        XCTAssertFalse(network.autoQualityEnabled)
                        XCTAssertTrue(network.savedAutoQualityEnabled)
                        XCTAssertTrue(writes.dropFirst(beforeFallback).allSatisfy { !(93...99).contains($0[5]) })
                        XCTAssertTrue(writes.dropFirst(beforeFallback).contains { $0[5] == WireMessageType.settingsGet.rawValue })
                        let update = try XCTUnwrap(writes.last { $0[5] == WireMessageType.settingsUpdate.rawValue })
                        XCTAssertEqual(update[19], 0)
                        XCTAssertEqual(update.loadLittleEndian(UInt32.self, at: 32), 12_000_000)
                        priorOwner = owner
                        continue
                    }
                } else {
                    XCTAssertTrue(policy.isEmpty)
                }
                XCTAssertEqual(network.desiredBitrateMbps, pairedHost == hostID ? 12 : 27)
                XCTAssertTrue(network.adaptiveQualityAvailable)
                XCTAssertEqual(network.autoQualityEnabled, pairedHost == hostID)
                if pairedHost == otherHostID {
                    let beforeFallback = writes.count
                    XCTAssertTrue(network.networkQueueForTesting.sync {
                        network.fallbackCommittedWifiToLegacy(generation: peer.generation)
                    })
                    reportLegacyAutoBitrate()
                    await drain()
                    let fallback = writes.dropFirst(beforeFallback)
                    XCTAssertTrue(fallback.contains { $0[5] == WireMessageType.settingsGet.rawValue })
                    let update = try XCTUnwrap(fallback.last { $0[5] == WireMessageType.settingsUpdate.rawValue })
                    XCTAssertEqual(update.loadLittleEndian(UInt32.self, at: 32), 27_000_000)
                }
                continue
            }
            network.setAutoQualityEnabled(false)
            reportLegacyAutoBitrate()
            await drain()
            XCTAssertFalse(network.adaptiveQualityAvailable)
            XCTAssertFalse(network.autoQualityEnabled)
            XCTAssertTrue(network.savedAutoQualityEnabled)
            XCTAssertTrue(writes.allSatisfy { !(93...99).contains($0[5]) })
            let update = try XCTUnwrap(writes.last { $0[5] == WireMessageType.settingsUpdate.rawValue })
            XCTAssertEqual(update[19], 0, "Fallback sends Manual, even with legacy Automatic bitrate saved")
            XCTAssertEqual(update.loadLittleEndian(UInt32.self, at: 32), 12_000_000)
            XCTAssertTrue(ClientStreamSettingsStore.loadAutoQuality(hostID: hostID, defaults: defaults))
        }
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
