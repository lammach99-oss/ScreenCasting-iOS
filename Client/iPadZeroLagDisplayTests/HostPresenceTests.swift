import XCTest
@testable import iPadCasting

final class HostPresenceTests: XCTestCase {
    @MainActor private final class Fake {
        var calls: [RemoteHostAddress] = []
        var replies: [@MainActor (Bool) -> Void] = []
        var cancellations = 0

        func probe(_ host: RemoteHostAddress, _ reply: @escaping @MainActor (Bool) -> Void) -> () -> Void {
            calls.append(host)
            replies.append(reply)
            return { self.cancellations += 1 }
        }
    }

    @MainActor func testDebounceAndDiscovery() throws {
        let fake = Fake()
        let monitor = HostPresenceMonitor(prober: fake.probe)
        let host = try XCTUnwrap(RemoteHostAddress.parse("192.0.2.1"))
        monitor.track([host])
        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(monitor.states[host], .checking)
        fake.replies[0](false)
        XCTAssertEqual(monitor.states[host], .offline)
        monitor.tick()
        fake.replies[1](true)
        XCTAssertEqual(monitor.states[host], .online)
        monitor.tick()
        fake.replies[2](false)
        XCTAssertEqual(monitor.states[host], .online)
        monitor.tick()
        monitor.markSeen(host)
        fake.replies[3](false)
        XCTAssertEqual(monitor.states[host], .online)
        monitor.tick()
        fake.replies[4](false)
        XCTAssertEqual(monitor.states[host], .online)
        monitor.tick()
        fake.replies[5](false)
        XCTAssertEqual(monitor.states[host], .offline)
    }

    @MainActor func testCapacityExclusionCancellationAndStaleReplies() throws {
        let hosts = try (1...7).map { try XCTUnwrap(RemoteHostAddress.parse("192.0.2.\($0)")) }
        let fake = Fake()
        let monitor = HostPresenceMonitor(prober: fake.probe)
        monitor.track(hosts, excluding: [hosts[0]])
        monitor.start()
        XCTAssertEqual(fake.calls, Array(hosts[1...4]))
        monitor.tick()
        XCTAssertEqual(fake.calls.count, 4)
        fake.replies[0](true)
        XCTAssertEqual(fake.calls.last, hosts[5])
        monitor.track([hosts[2]])
        XCTAssertEqual(fake.cancellations, 4)
        fake.replies[1](true)
        XCTAssertEqual(monitor.states[hosts[2]], .checking)
        monitor.stop()
        XCTAssertEqual(fake.cancellations, 5)
        monitor.start()
        fake.replies[5](true)
        XCTAssertEqual(monitor.states[hosts[2]], .checking)
        fake.replies[6](true)
        XCTAssertEqual(monitor.states[hosts[2]], .online)
        monitor.stop()
    }
}
