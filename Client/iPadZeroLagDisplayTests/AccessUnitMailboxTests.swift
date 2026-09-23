import XCTest
@testable import iPadCasting

final class AccessUnitMailboxTests: XCTestCase {
    func testCallbackHeldFloodRetainsOnlyInFlightAndLatestPending() {
        let releases = ReleaseCounter()
        let mailbox = AccessUnitMailbox(maximumAge: 1, clock: { 0 })
        mailbox.beginSession(generation: 1)
        let held = unwrap(mailbox.publish(unit(0, idr: true, releases: releases)))

        for sequence in UInt32(1)...UInt32(256) {
            XCTAssertNil(mailbox.publish(
                unit(sequence, idr: true, releases: releases)))
            XCTAssertLessThanOrEqual(mailbox.retainedOwnerCount, 2)
        }

        let completion = mailbox.complete(held, succeeded: true)
        held.unit.owner.release()
        XCTAssertEqual(completion.disposition, .deliver)
        XCTAssertEqual(completion.next?.unit.sequence, 256)
        XCTAssertEqual(mailbox.retainedOwnerCount, 1)
        mailbox.invalidate()
        XCTAssertEqual(releases.values.count, 257)
        XCTAssertTrue(releases.values.values.allSatisfy { $0 == 1 })
    }

    func testRecoveryWaitsForSuccessfulIDRCallback() {
        var requests = 0
        var drops: [(UInt32, UInt64, AccessUnitDropReason)] = []
        let mailbox = AccessUnitMailbox(
            maximumAge: 1, clock: { 0 },
            onRecoveryNeeded: { requests += 1 },
            onDrop: { drops.append(($0, $1, $2)) })
        mailbox.beginSession(generation: 7)
        let idr = unwrap(mailbox.publish(simpleUnit(1, idr: true)))
        XCTAssertTrue(mailbox.waitingForIDR)
        XCTAssertNil(mailbox.publish(simpleUnit(2, idr: false)))
        XCTAssertEqual(mailbox.retainedOwnerCount, 2)
        XCTAssertTrue(drops.isEmpty)
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(mailbox.waitingForIDR)

        let completion = mailbox.complete(idr, succeeded: true)
        idr.unit.owner.release()
        XCTAssertEqual(completion.disposition, .deliver)
        XCTAssertEqual(completion.next?.unit.sequence, 2)
        XCTAssertFalse(mailbox.waitingForIDR)
        let dependent = unwrap(completion.next)
        XCTAssertEqual(
            mailbox.complete(dependent, succeeded: true).disposition,
            .deliver)
        dependent.unit.owner.release()
        XCTAssertNotNil(mailbox.publish(simpleUnit(3, idr: false)))
        mailbox.invalidate()
    }

    func testFailedIDRRemainsWaitingAndRequestsOncePerEpisode() {
        var requests = 0
        var drops: [(UInt32, UInt64, AccessUnitDropReason)] = []
        let mailbox = AccessUnitMailbox(
            maximumAge: 1, clock: { 0 },
            onRecoveryNeeded: { requests += 1 },
            onDrop: { drops.append(($0, $1, $2)) })
        mailbox.beginSession(generation: 1)
        let idr = unwrap(mailbox.publish(simpleUnit(10, idr: true)))
        XCTAssertNil(mailbox.publish(simpleUnit(11, idr: false)))
        XCTAssertEqual(mailbox.retainedOwnerCount, 2)
        XCTAssertEqual(mailbox.complete(idr, succeeded: false).disposition, .failed)
        idr.unit.owner.release()
        XCTAssertTrue(mailbox.waitingForIDR)
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(drops.contains {
            $0.0 == 11 && $0.1 == 1 && $0.2 == .decodeFailed
        })
        XCTAssertNil(mailbox.publish(simpleUnit(12, idr: false)))
        XCTAssertEqual(requests, 1)
        mailbox.invalidate()
    }

    func test120FpsPeriodicIDRKeepsFirstDependentAcrossCallbackOverlap() {
        var drops: [(UInt32, UInt64, AccessUnitDropReason)] = []
        var recoveryRequests = 0
        var decoded = 0
        let mailbox = AccessUnitMailbox(
            maximumAge: 1,
            clock: { 0 },
            onRecoveryNeeded: { recoveryRequests += 1 },
            onDrop: { drops.append(($0, $1, $2)) })
        mailbox.beginSession(generation: 1)

        for sequence in stride(from: UInt32(0), to: 120, by: 30) {
            let idr = unwrap(mailbox.publish(simpleUnit(sequence, idr: true)))
            XCTAssertNil(mailbox.publish(simpleUnit(sequence + 1, idr: false)))
            XCTAssertEqual(mailbox.retainedOwnerCount, 2)

            let idrCompletion = mailbox.complete(idr, succeeded: true)
            idr.unit.owner.release()
            decoded += 1
            var dependent = unwrap(idrCompletion.next)
            XCTAssertEqual(dependent.unit.sequence, sequence + 1)

            for nextSequence in (sequence + 2)..<(sequence + 30) {
                let completion = mailbox.complete(dependent, succeeded: true)
                dependent.unit.owner.release()
                decoded += 1
                XCTAssertNil(completion.next)
                dependent = unwrap(mailbox.publish(
                    simpleUnit(nextSequence, idr: false)))
            }
            _ = mailbox.complete(dependent, succeeded: true)
            dependent.unit.owner.release()
            decoded += 1
        }

        XCTAssertEqual(decoded, 120)
        XCTAssertTrue(drops.isEmpty)
        XCTAssertEqual(recoveryRequests, 0)
        mailbox.invalidate()
    }

    func testPendingIDRCannotBeReplacedByItsDependentNonIDR() {
        var drops: [(UInt32, UInt64, AccessUnitDropReason)] = []
        let mailbox = AccessUnitMailbox(
            maximumAge: 1,
            clock: { 0 },
            onDrop: { drops.append(($0, $1, $2)) })
        mailbox.beginSession(generation: 1)
        let bootstrap = unwrap(mailbox.publish(simpleUnit(1, idr: true)))
        XCTAssertEqual(mailbox.complete(bootstrap, succeeded: true).disposition, .deliver)
        bootstrap.unit.owner.release()

        let chainA = unwrap(mailbox.publish(simpleUnit(2, idr: false)))
        XCTAssertNil(mailbox.publish(simpleUnit(3, idr: true)))
        XCTAssertTrue(mailbox.waitingForIDR)
        XCTAssertNil(mailbox.publish(simpleUnit(4, idr: false)))
        XCTAssertTrue(drops.contains {
            $0.0 == 4 && $0.1 == 1 && $0.2 == .waitingForIDR
        })

        let completion = mailbox.complete(chainA, succeeded: true)
        chainA.unit.owner.release()
        XCTAssertEqual(completion.next?.unit.sequence, 3)
        XCTAssertTrue(completion.next?.unit.isIDR == true)
        XCTAssertTrue(mailbox.waitingForIDR)
        XCTAssertNil(mailbox.publish(simpleUnit(5, idr: false)))
        let candidate = unwrap(completion.next)
        let candidateCompletion = mailbox.complete(candidate, succeeded: true)
        XCTAssertEqual(candidateCompletion.disposition, .deliver)
        candidate.unit.owner.release()
        XCTAssertFalse(mailbox.waitingForIDR)
        let dependent = unwrap(candidateCompletion.next)
        XCTAssertEqual(dependent.unit.sequence, 5)
        XCTAssertEqual(
            mailbox.complete(dependent, succeeded: true).disposition,
            .deliver)
        dependent.unit.owner.release()
        XCTAssertNotNil(mailbox.publish(simpleUnit(6, idr: false)))
        mailbox.invalidate()
    }

    func testNewerIDRReplacesCandidateWhileDependentsRemainSuppressed() {
        let mailbox = AccessUnitMailbox(maximumAge: 1, clock: { 0 })
        mailbox.beginSession(generation: 1)
        let bootstrap = unwrap(mailbox.publish(simpleUnit(1, idr: true)))
        _ = mailbox.complete(bootstrap, succeeded: true)
        bootstrap.unit.owner.release()
        let chainA = unwrap(mailbox.publish(simpleUnit(2, idr: false)))

        XCTAssertNil(mailbox.publish(simpleUnit(3, idr: true)))
        XCTAssertNil(mailbox.publish(simpleUnit(4, idr: true)))
        XCTAssertNil(mailbox.publish(simpleUnit(5, idr: false)))
        let completion = mailbox.complete(chainA, succeeded: true)
        chainA.unit.owner.release()
        XCTAssertEqual(completion.next?.unit.sequence, 4)
        XCTAssertTrue(mailbox.waitingForIDR)
        mailbox.invalidate()
    }

    func testStaleEpochCallbackCannotPoisonNewReferenceChain() {
        var requests = 0
        let mailbox = AccessUnitMailbox(
            maximumAge: 1, clock: { 0 },
            onRecoveryNeeded: { requests += 1 })
        mailbox.beginSession(generation: 1)
        let old = unwrap(mailbox.publish(simpleUnit(1, idr: true)))
        mailbox.invalidate()
        mailbox.beginSession(generation: 2)
        let current = unwrap(mailbox.publish(simpleUnit(100, idr: true)))
        XCTAssertEqual(mailbox.complete(current, succeeded: true).disposition, .deliver)
        current.unit.owner.release()
        XCTAssertFalse(mailbox.waitingForIDR)

        XCTAssertEqual(mailbox.complete(old, succeeded: false).disposition, .stale)
        old.unit.owner.release()
        XCTAssertFalse(mailbox.waitingForIDR)
        XCTAssertEqual(requests, 0)
        mailbox.invalidate()
    }

    func testResetPublishRaceKeepsBoundAndStaleTicketCannotDrainNewSession() {
        let mailbox = AccessUnitMailbox(maximumAge: 1, clock: { 0 })
        mailbox.beginSession(generation: 1)
        let old = unwrap(mailbox.publish(simpleUnit(1, idr: true)))
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "mailbox.reset.publish", attributes: .concurrent)
        group.enter()
        queue.async {
            mailbox.invalidate()
            mailbox.beginSession(generation: 2)
            group.leave()
        }
        for sequence in UInt32(2)...UInt32(128) {
            group.enter()
            queue.async {
                _ = mailbox.publish(self.simpleUnit(sequence, idr: true))
                group.leave()
            }
        }
        group.wait()
        XCTAssertLessThanOrEqual(mailbox.retainedOwnerCount, 2)
        XCTAssertEqual(mailbox.complete(old, succeeded: false).disposition, .stale)
        old.unit.owner.release()
        XCTAssertLessThanOrEqual(mailbox.retainedOwnerCount, 2)
        mailbox.invalidate()
    }

    func testSessionSwapReportsDroppedUnitOriginalGeneration() {
        var drops: [(UInt32, UInt64, AccessUnitDropReason)] = []
        let mailbox = AccessUnitMailbox(
            maximumAge: 1,
            clock: { 0 },
            onDrop: { drops.append(($0, $1, $2)) })
        mailbox.beginSession(generation: 41)
        _ = mailbox.publish(simpleUnit(7, generation: 41, idr: true))

        mailbox.beginSession(generation: 42)

        XCTAssertEqual(drops.count, 1)
        XCTAssertEqual(drops[0].0, 7)
        XCTAssertEqual(drops[0].1, 41)
        XCTAssertEqual(drops[0].2, .invalidated)
        mailbox.invalidate()
    }

    func testExpiredPendingNeverBecomesNextSubmission() {
        var now: TimeInterval = 0
        var drops: [(UInt32, UInt64, AccessUnitDropReason)] = []
        let mailbox = AccessUnitMailbox(
            maximumAge: 0.01, clock: { now },
            onDrop: { drops.append(($0, $1, $2)) })
        mailbox.beginSession(generation: 1)
        let held = unwrap(mailbox.publish(simpleUnit(1, idr: true)))
        _ = mailbox.publish(simpleUnit(2, idr: true))
        now = 0.02
        let completion = mailbox.complete(held, succeeded: true)
        held.unit.owner.release()
        XCTAssertNil(completion.next)
        XCTAssertTrue(drops.contains {
            $0.0 == 2 && $0.1 == 1 && $0.2 == .expired
        })
        mailbox.invalidate()
    }

    func testAnnexBScannerReturnsInPlaceNALRanges() {
        let bytes = Data([0, 0, 0, 1, 0x40, 1, 0, 0, 1, 0x26, 2, 3])
        let ranges = AnnexBNALScanner.ranges(in: bytes)
        XCTAssertEqual(ranges, [4..<6, 9..<12])
        XCTAssertEqual(bytes[ranges[0]].first, 0x40)
        XCTAssertEqual(bytes[ranges[1]].first, 0x26)
    }

    func testAnnexBScannerTrimsSeparatorAndTrailingZeroBytes() {
        let bytes = Data([
            0, 0, 0, 1, 0x40, 1, 0, 0,
            0, 0, 1, 0x26, 2, 3, 0, 0, 0
        ])
        let ranges = AnnexBNALScanner.ranges(in: bytes)
        XCTAssertEqual(ranges, [4..<6, 11..<14])
        XCTAssertEqual(Data(bytes[ranges[0]]), Data([0x40, 1]))
        XCTAssertEqual(Data(bytes[ranges[1]]), Data([0x26, 2, 3]))
    }

    func testOwnerLivesThroughAsynchronousDecodeLifetimeSimulation() {
        var releases = 0
        var callback: (() -> Void)?
        weak var weakOwner: AccessUnitOwner?
        autoreleasepool {
            let owner = AccessUnitOwner(data: Data([1, 2, 3])) { releases += 1 }
            weakOwner = owner
            let lifetime = DecodeSubmissionLifetime(owner: owner, sequence: 77)
            callback = {
                XCTAssertEqual(lifetime.owner.data, Data([1, 2, 3]))
                lifetime.finish()
            }
        }
        XCTAssertNotNil(weakOwner)
        callback?()
        callback = nil
        XCTAssertNil(weakOwner)
        XCTAssertEqual(releases, 1)
    }

    private func simpleUnit(
        _ sequence: UInt32,
        generation: UInt64 = 1,
        idr: Bool
    ) -> AccessUnit {
        AccessUnit(
            owner: AccessUnitOwner(data: Data([1])),
            sequence: sequence,
            sessionGeneration: generation,
            isIDR: idr,
            receivedAt: 0)
    }

    private func unit(
        _ sequence: UInt32,
        idr: Bool,
        releases: ReleaseCounter
    ) -> AccessUnit {
        AccessUnit(
            owner: AccessUnitOwner(data: Data([1])) {
                releases.record(sequence)
            },
            sequence: sequence,
            sessionGeneration: 1,
            isIDR: idr,
            receivedAt: 0)
    }

    private func unwrap<T>(
        _ value: T?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> T {
        guard let value else {
            XCTFail("Expected non-nil", file: file, line: line)
            fatalError("Expected non-nil")
        }
        return value
    }
}

private final class ReleaseCounter {
    private let lock = NSLock()
    private var storage: [UInt32: Int] = [:]

    var values: [UInt32: Int] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ sequence: UInt32) {
        lock.lock()
        storage[sequence, default: 0] += 1
        lock.unlock()
    }
}

final class RenderFreshnessTrackerTests: XCTestCase {
    func testRenderCadenceCountersCaptureAndResetEveryStage() {
        var counters = RenderCadenceCounters()

        counters.record(.offered)
        counters.record(.offered)
        counters.record(.pendingReplaced)
        counters.record(.drawCallback)
        counters.record(.drawNoPending)
        counters.record(.drawableAcquired)
        counters.record(.precommitSuperseded)
        counters.record(.commandCommitted)
        counters.record(.commandCompleted)
        counters.record(.renderFailure)
        counters.record(.gameBuffered)
        counters.record(.gameBufferOverwritten)
        counters.record(.gameRePresented)

        XCTAssertEqual(
            counters.drain(),
            RenderCadenceSnapshot(
                offered: 2,
                pendingReplaced: 1,
                drawCallbacks: 1,
                drawNoPending: 1,
                drawableAcquired: 1,
                precommitSuperseded: 1,
                commandCommitted: 1,
                commandCompleted: 1,
                renderFailures: 1,
                gameBuffered: 1,
                gameBufferOverwritten: 1,
                gameRePresented: 1))
        XCTAssertEqual(counters.drain(), .zero)
    }

    func testPendingReplacementIsNotTelemetryDrop() {
        var tracker = RenderFreshnessTracker()
        tracker.beginSession(generation: 1)
        XCTAssertEqual(tracker.offer(20, generation: 1), .accepted(replaced: nil))

        let replacement = tracker.offer(21, generation: 1)
        XCTAssertEqual(replacement, .accepted(replaced: 20))
        XCTAssertNil(replacement.telemetryDropSequence(for: 21))
        XCTAssertEqual(tracker.pendingIdentity?.sequence, 21)
    }

    func testRejectedFrameRemainsTelemetryDrop() {
        var tracker = RenderFreshnessTracker()
        tracker.beginSession(generation: 1)
        _ = tracker.offer(20, generation: 1)

        let rejected = tracker.offer(19, generation: 1)
        XCTAssertEqual(rejected, .rejected)
        XCTAssertEqual(rejected.telemetryDropSequence(for: 19), 19)
    }

    func testPrecommitSupersessionIsNotTelemetryDrop() {
        var tracker = RenderFreshnessTracker()
        tracker.beginSession(generation: 1)
        _ = tracker.offer(20, generation: 1)
        let taken = tracker.takePending()!

        XCTAssertEqual(tracker.offer(21, generation: 1), .accepted(replaced: nil))
        XCTAssertEqual(
            tracker.commitDecision(for: taken),
            .superseded)
    }

    func testAcceptedWatermarkRejectsOlderFrameAfterPendingSlotIsEmpty() {
        var tracker = RenderFreshnessTracker()
        tracker.beginSession(generation: 1)
        XCTAssertEqual(tracker.offer(10, generation: 1), .accepted(replaced: nil))
        XCTAssertEqual(
            tracker.takePending(),
            RenderFrameIdentity(generation: 1, sequence: 10))
        XCTAssertEqual(tracker.offer(9, generation: 1), .rejected)
        XCTAssertNil(tracker.pendingIdentity)
    }

    func testReplacementRejectionAndPrecommitAbandonmentAreIdentified() {
        var tracker = RenderFreshnessTracker()
        tracker.beginSession(generation: 1)
        XCTAssertEqual(tracker.offer(20, generation: 1), .accepted(replaced: nil))
        let taken = tracker.takePending()!
        XCTAssertEqual(tracker.offer(21, generation: 1), .accepted(replaced: nil))
        XCTAssertFalse(tracker.shouldCommit(taken))
        XCTAssertEqual(tracker.offer(22, generation: 1), .accepted(replaced: 21))
        XCTAssertEqual(tracker.offer(21, generation: 1), .rejected)
    }

    func testPresentedWatermarkIsPersistentAndWrapSafe() {
        var tracker = RenderFreshnessTracker()
        tracker.beginSession(generation: 1)
        XCTAssertEqual(
            tracker.offer(UInt32.max, generation: 1),
            .accepted(replaced: nil))
        let maximum = tracker.takePending()!
        XCTAssertTrue(tracker.markPresented(maximum))
        XCTAssertEqual(tracker.offer(0, generation: 1), .accepted(replaced: nil))
        let zero = tracker.takePending()!
        XCTAssertTrue(tracker.shouldCommit(zero))
        XCTAssertTrue(tracker.markPresented(zero))
        XCTAssertEqual(tracker.offer(UInt32.max, generation: 1), .rejected)
        XCTAssertEqual(tracker.presentedSequence, 0)
    }

    func testReconnectResetsSequenceWatermarksAndPendingFrame() {
        var tracker = RenderFreshnessTracker()
        tracker.beginSession(generation: 10)
        XCTAssertEqual(tracker.offer(9_000, generation: 10), .accepted(replaced: nil))
        let old = tracker.takePending()!
        XCTAssertTrue(tracker.markPresented(old))

        tracker.beginSession(generation: 11)
        XCTAssertNil(tracker.acceptedSequence)
        XCTAssertNil(tracker.presentedSequence)
        XCTAssertNil(tracker.pendingIdentity)
        XCTAssertEqual(tracker.offer(1, generation: 11), .accepted(replaced: nil))
    }

    func testOldSessionCompletionCannotAdvanceNewSessionWatermark() {
        var tracker = RenderFreshnessTracker()
        tracker.beginSession(generation: 20)
        _ = tracker.offer(500, generation: 20)
        let oldCommand = tracker.takePending()!
        tracker.beginSession(generation: 21)
        XCTAssertEqual(tracker.offer(1, generation: 21), .accepted(replaced: nil))

        XCTAssertFalse(tracker.markPresented(oldCommand))
        XCTAssertNil(tracker.presentedSequence)
        XCTAssertEqual(tracker.offer(2, generation: 20), .staleSession)
        XCTAssertEqual(tracker.acceptedSequence, 1)
    }
}

final class GamePresentationHandoffTests: XCTestCase {
    private let a = RenderFrameIdentity(generation: 7, sequence: 1)
    private let b = RenderFrameIdentity(generation: 7, sequence: 2)
    private let c = RenderFrameIdentity(generation: 7, sequence: 3)

    func testSecondFrameBecomesLookAheadWithoutReplacingReady() {
        var handoff = GamePresentationHandoff()

        XCTAssertEqual(handoff.offer(a), .buffered)
        XCTAssertEqual(handoff.offer(b), .buffered)
        XCTAssertEqual(handoff.ready, a)
        XCTAssertEqual(handoff.lookAhead, b)
    }

    func testTakeShiftsLookAheadIntoReady() {
        var handoff = GamePresentationHandoff()
        _ = handoff.offer(a)
        _ = handoff.offer(b)

        XCTAssertEqual(handoff.take(currentGeneration: 7), .fresh(a))
        XCTAssertEqual(handoff.ready, b)
        XCTAssertNil(handoff.lookAhead)
    }

    func testThirdFrameOverwritesOnlyLookAhead() {
        var handoff = GamePresentationHandoff()
        _ = handoff.offer(a)
        _ = handoff.offer(b)

        XCTAssertEqual(handoff.offer(c), .overwroteLookAhead)
        XCTAssertEqual(handoff.ready, a)
        XCTAssertEqual(handoff.lookAhead, c)
    }

    func testResetClearsReadyLookAheadAndRepeatFallback() {
        var handoff = GamePresentationHandoff()
        _ = handoff.offer(a)
        _ = handoff.offer(b)
        handoff.markPresented(a, currentGeneration: 7)

        handoff.reset()

        XCTAssertNil(handoff.ready)
        XCTAssertNil(handoff.lookAhead)
        XCTAssertNil(handoff.lastPresented)
    }

    func testRepeatFallbackIsUsedOnlyWhenReadyIsEmpty() {
        var handoff = GamePresentationHandoff()
        handoff.markPresented(a, currentGeneration: 7)
        _ = handoff.offer(b)

        XCTAssertEqual(handoff.take(currentGeneration: 7), .fresh(b))
        XCTAssertEqual(handoff.take(currentGeneration: 7), .repeated(a))
    }

    func testTakenGameFrameRemainsCurrentAfterNewerFrameIsAccepted() {
        var freshness = RenderFreshnessTracker()
        freshness.beginSession(generation: 7)
        _ = freshness.offer(a.sequence, generation: 7)
        let taken = freshness.takePending()!
        _ = freshness.offer(b.sequence, generation: 7)

        XCTAssertEqual(freshness.commitDecision(for: taken), .superseded)
        XCTAssertTrue(freshness.isCurrent(taken))
    }

    func testStaleGenerationNeverUsesRepeatFallback() {
        var handoff = GamePresentationHandoff()
        handoff.markPresented(a, currentGeneration: 7)

        XCTAssertEqual(handoff.take(currentGeneration: 8), .none)
    }

    func testOneHundredOfferTakeCyclesNeverExceedTwoPendingFrames() {
        var handoff = GamePresentationHandoff()

        for sequence in UInt32(1)...100 {
            _ = handoff.offer(
                RenderFrameIdentity(generation: 7, sequence: sequence))
            XCTAssertLessThanOrEqual(handoff.pendingCount, 2)
            if sequence.isMultiple(of: 2) {
                _ = handoff.take(currentGeneration: 7)
            }
        }
    }
}

final class OfficePresentationHandoffTests: XCTestCase {
    private let a = RenderFrameIdentity(generation: 7, sequence: 1)
    private let b = RenderFrameIdentity(generation: 7, sequence: 2)
    private let c = RenderFrameIdentity(generation: 7, sequence: 3)

    func testSecondFrameBecomesLookAhead() {
        var handoff = OfficePresentationHandoff()
        XCTAssertEqual(handoff.offer(a), .buffered)
        XCTAssertEqual(handoff.offer(b), .buffered)
        XCTAssertEqual(handoff.ready, a)
        XCTAssertEqual(handoff.lookAhead, b)
        XCTAssertEqual(handoff.pendingCount, 2)
    }

    func testTakePromotesLookAheadAndDoesNotRepeat() {
        var handoff = OfficePresentationHandoff()
        _ = handoff.offer(a)
        _ = handoff.offer(b)

        XCTAssertEqual(handoff.take(currentGeneration: 7), a)
        XCTAssertEqual(handoff.ready, b)
        XCTAssertNil(handoff.lookAhead)
        XCTAssertEqual(handoff.take(currentGeneration: 7), b)
        XCTAssertNil(handoff.take(currentGeneration: 7))
    }

    func testThirdFrameOverwritesOnlyLookAhead() {
        var handoff = OfficePresentationHandoff()
        _ = handoff.offer(a)
        _ = handoff.offer(b)

        XCTAssertEqual(handoff.offer(c), .overwroteLookAhead)
        XCTAssertEqual(handoff.ready, a)
        XCTAssertEqual(handoff.lookAhead, c)
        XCTAssertEqual(handoff.pendingCount, 2)
    }

    func testStaleGenerationClearsBothSlots() {
        var handoff = OfficePresentationHandoff()
        _ = handoff.offer(a)
        _ = handoff.offer(b)

        XCTAssertNil(handoff.take(currentGeneration: 8))
        XCTAssertEqual(handoff.pendingCount, 0)
    }

    func testResetClearsPendingFrames() {
        var handoff = OfficePresentationHandoff()
        _ = handoff.offer(a)
        _ = handoff.offer(b)
        handoff.reset()

        XCTAssertNil(handoff.take(currentGeneration: 7))
        XCTAssertEqual(handoff.pendingCount, 0)
    }

    func testSelectedOfficeFrameSurvivesNewerSameGenerationOffer() {
        var freshness = RenderFreshnessTracker()
        var handoff = OfficePresentationHandoff()
        freshness.beginSession(generation: 7)
        _ = freshness.offer(a.sequence, generation: 7)
        _ = handoff.offer(freshness.takePending()!)
        let selected = handoff.take(currentGeneration: 7)!
        _ = freshness.offer(b.sequence, generation: 7)
        _ = handoff.offer(freshness.takePending()!)

        XCTAssertEqual(freshness.commitDecision(for: selected), .superseded)
        XCTAssertTrue(freshness.isCurrent(selected))
        freshness.beginSession(generation: 8)
        XCTAssertFalse(freshness.isCurrent(selected))
    }

    func testOneHundredCyclesStayWithinTwoPendingFrames() {
        var handoff = OfficePresentationHandoff()
        for sequence in UInt32(1)...100 {
            _ = handoff.offer(RenderFrameIdentity(
                generation: 7, sequence: sequence))
            XCTAssertLessThanOrEqual(handoff.pendingCount, 2)
            if sequence.isMultiple(of: 2) {
                _ = handoff.take(currentGeneration: 7)
            }
        }
    }
}

final class RendererGeometryPublishGateTests: XCTestCase {
    private let baseKey = RendererGeometryPublishKey(
        decodedFrameSize: CGSize(width: 2_388, height: 1_668),
        drawableSize: CGSize(width: 2_388, height: 1_668),
        contentViewport: VideoContentViewport(
            rect: CGRect(x: 0, y: 0, width: 1, height: 1)))

    func testUnchangedGeometryRequestSchedulesOnlyOnce() {
        var gate = RendererGeometryPublishGate()

        XCTAssertTrue(gate.shouldSchedule(baseKey))
        for _ in 0..<120 {
            XCTAssertFalse(gate.shouldSchedule(baseKey))
        }
    }

    func testDrawableSizeChangeSchedulesGeometryPublication() {
        var gate = RendererGeometryPublishGate()
        let changed = RendererGeometryPublishKey(
            decodedFrameSize: baseKey.decodedFrameSize,
            drawableSize: CGSize(width: 1_668, height: 2_388),
            contentViewport: baseKey.contentViewport)

        XCTAssertTrue(gate.shouldSchedule(baseKey))
        XCTAssertTrue(gate.shouldSchedule(changed))
    }

    func testVideoGeometryChangeSchedulesGeometryPublication() {
        var gate = RendererGeometryPublishGate()
        let changedDecodedSize = RendererGeometryPublishKey(
            decodedFrameSize: CGSize(width: 1_668, height: 2_388),
            drawableSize: baseKey.drawableSize,
            contentViewport: baseKey.contentViewport)
        let changedViewport = RendererGeometryPublishKey(
            decodedFrameSize: changedDecodedSize.decodedFrameSize,
            drawableSize: changedDecodedSize.drawableSize,
            contentViewport: VideoContentViewport(
                rect: CGRect(x: 0.1, y: 0, width: 0.8, height: 1)))

        XCTAssertTrue(gate.shouldSchedule(baseKey))
        XCTAssertTrue(gate.shouldSchedule(changedDecodedSize))
        XCTAssertTrue(gate.shouldSchedule(changedViewport))
    }

    func testForcedLayoutPublicationSchedulesEvenForSameKey() {
        var gate = RendererGeometryPublishGate()

        XCTAssertTrue(gate.shouldSchedule(baseKey))
        XCTAssertFalse(gate.shouldSchedule(baseKey))
        XCTAssertTrue(gate.shouldSchedule(baseKey, force: true))
        XCTAssertFalse(gate.shouldSchedule(baseKey))
    }

    func testGeometryPublishGateResetAllowsNewSessionPublication() {
        var gate = RendererGeometryPublishGate()

        XCTAssertTrue(gate.shouldSchedule(baseKey))
        XCTAssertFalse(gate.shouldSchedule(baseKey))
        gate.reset()
        XCTAssertTrue(gate.shouldSchedule(baseKey))
    }
}

final class PresentationCadencePolicyTests: XCTestCase {
    func testOfficeOn120HzPanelIs60() {
        let policy = PresentationCadencePolicy()

        XCTAssertEqual(
            policy.targetFPS(maximumPanelFPS: 120, mode: .office),
            60)
    }

    func testOfficeRemains60AcrossRepeatedEvaluations() {
        let policy = PresentationCadencePolicy()

        for _ in 0..<100 {
            XCTAssertEqual(
                policy.targetFPS(maximumPanelFPS: 120, mode: .office),
                60)
        }
    }

    func testOfficeOn60HzPanelIs60() {
        let policy = PresentationCadencePolicy()

        XCTAssertEqual(
            policy.targetFPS(maximumPanelFPS: 60, mode: .office),
            60)
    }

    func testGameOn120HzPanelIs120() {
        let policy = PresentationCadencePolicy()

        XCTAssertEqual(
            policy.targetFPS(maximumPanelFPS: 120, mode: .game),
            120)
    }

    func testGameOn60HzPanelIs60() {
        let policy = PresentationCadencePolicy()

        XCTAssertEqual(
            policy.targetFPS(maximumPanelFPS: 60, mode: .game),
            60)
    }

    func testGameOnHigherRefreshPanelCapsAt120() {
        let policy = PresentationCadencePolicy()

        XCTAssertEqual(
            policy.targetFPS(maximumPanelFPS: 144, mode: .game),
            120)
    }

    func testRepeatedOfficeGameEvaluationsDoNotAccumulateState() {
        let policy = PresentationCadencePolicy()

        for _ in 0..<100 {
            XCTAssertEqual(
                policy.targetFPS(maximumPanelFPS: 120, mode: .office),
                60)
            XCTAssertEqual(
                policy.targetFPS(maximumPanelFPS: 120, mode: .game),
                120)
        }
    }
}
