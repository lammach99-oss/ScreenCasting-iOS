import XCTest
import Network
@testable import iPadCasting

final class RemoteHostDirectoryTests: XCTestCase {
    func testAddressParsingAcceptsIPv4AndNormalisesDNSNames() {
        let cases: [(raw: String, host: String, kind: RemoteHostAddress.Kind)] = [
            ("100.64.0.10", "100.64.0.10", .ipv4),
            ("192.168.1.20", "192.168.1.20", .ipv4),
            (" \t192.168.1.20\n", "192.168.1.20", .ipv4),
            ("0.0.0.0", "0.0.0.0", .ipv4),
            ("255.255.255.255", "255.255.255.255", .ipv4),
            ("001.002.003.004", "001.002.003.004", .ipv4),
            ("office-pc", "office-pc", .dnsName),
            ("Office-PC.Tail1234.ts.net.", "office-pc.tail1234.ts.net", .dnsName),
            (" \tOFFICE-PC.\n", "office-pc", .dnsName),
            ("pc1.example.com", "pc1.example.com", .dnsName)
        ]
        for row in cases {
            let address = RemoteHostAddress.parse(row.raw)
            XCTAssertEqual(address?.host, row.host, row.raw)
            XCTAssertEqual(address?.kind, row.kind, row.raw)
        }
    }

    func testAddressParsingRejectsMalformedAddresses() {
        let name254 = String(repeating: "a", count: 63) + "."
            + String(repeating: "b", count: 63) + "."
            + String(repeating: "c", count: 63) + "."
            + String(repeating: "d", count: 62)
        let cases = [
            "192.168.1", "256.1.1.1", "1.2.3.4.5", "0000.1.1.1",
            "pc_name", "http://pc", "pc:27020", "-pc", "pc-", "", " \t\n",
            String(repeating: "a", count: 64), name254, "2001:db8::1", "[::1]",
            "office pc", "office\tpc", "pc..example", ".pc", "pc..", ".",
            "1.2.3.4.", "+1.2.3.4", "123", "caf\u{00e9}"
        ]
        for raw in cases {
            XCTAssertNil(RemoteHostAddress.parse(raw), raw)
        }
    }

    func testAddressParsingAcceptsDNSLengthBoundaries() {
        let cases = [
            "a",
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 63) + "."
                + String(repeating: "b", count: 63) + "."
                + String(repeating: "c", count: 63) + "."
                + String(repeating: "d", count: 61)
        ]
        for raw in cases {
            XCTAssertEqual(RemoteHostAddress.parse(raw)?.kind, .dnsName, raw)
        }
    }

    func testTailnetClassificationUsesAddressRangeAndDNSShape() throws {
        let cases: [(host: String, tailnet: Bool)] = [
            ("100.64.0.1", true),
            ("100.127.255.254", true),
            ("100.128.0.1", false),
            ("100.63.255.255", false),
            ("192.168.1.20", false),
            ("office-pc", true),
            ("localhost", false),
            ("office-pc.tail1234.ts.net", true),
            ("example.com", false),
            ("100.64.0.0", true),
            ("100.127.255.255", true),
            ("office-pc.ts.net.example.com", false)
        ]
        for row in cases {
            let address = try XCTUnwrap(RemoteHostAddress.parse(row.host), row.host)
            XCTAssertEqual(address.isTailnet, row.tailnet, row.host)
        }
    }

    func testRemoteControlPolicyRequiresAHostPortOn27020() {
        let cases: [(endpoint: NWEndpoint, remoteControl: Bool)] = [
            (.hostPort(host: "100.64.0.10", port: 27020), true),
            (.hostPort(host: "office-pc", port: 27020), true),
            (.hostPort(host: "100.64.0.10", port: 27015), false),
            (.hostPort(host: "office-pc", port: 80), false),
            (.service(name: "Office-PC", type: "_screencasting._tcp", domain: "local.", interface: nil), false)
        ]
        for row in cases {
            XCTAssertEqual(RemoteSessionPolicy.isRemoteControl(endpoint: row.endpoint), row.remoteControl)
        }
    }

    func testRecentHostPortAndIdentityIncludeTheMode() {
        let cases: [(remoteControl: Bool, port: UInt16, id: String)] = [
            (true, 27020, "office-pc|true"),
            (false, 27015, "office-pc|false")
        ]
        for row in cases {
            let entry = RecentRemoteHost(host: "office-pc", remoteControl: row.remoteControl, lastUsed: Date(timeIntervalSince1970: 100))
            XCTAssertEqual(entry.port, row.port)
            XCTAssertEqual(entry.id, row.id)
        }
    }

    func testRecentStoreMovesTheMatchingHostAndModeToTheFront() throws {
        try withDefaults { defaults in
            let cases: [(host: String, remoteControl: Bool, time: TimeInterval, ids: [String])] = [
                ("office-pc", true, 100, ["office-pc|true"]),
                ("home-pc", false, 200, ["home-pc|false", "office-pc|true"]),
                ("office-pc", false, 300, ["office-pc|false", "home-pc|false", "office-pc|true"]),
                ("office-pc", true, 400, ["office-pc|true", "office-pc|false", "home-pc|false"]),
                ("home-pc", false, 50, ["home-pc|false", "office-pc|true", "office-pc|false"])
            ]
            for row in cases {
                let entries = RecentRemoteHostStore.record(host: row.host, remoteControl: row.remoteControl,
                                                          now: Date(timeIntervalSince1970: row.time), defaults: defaults)
                XCTAssertEqual(entries.map(\.id), row.ids)
                XCTAssertEqual(entries.first?.lastUsed, Date(timeIntervalSince1970: row.time))
                XCTAssertEqual(RecentRemoteHostStore.load(defaults: defaults).map(\.id), row.ids)
            }
            XCTAssertEqual(RecentRemoteHostStore.load(defaults: defaults), [
                RecentRemoteHost(host: "home-pc", remoteControl: false, lastUsed: Date(timeIntervalSince1970: 50)),
                RecentRemoteHost(host: "office-pc", remoteControl: true, lastUsed: Date(timeIntervalSince1970: 400)),
                RecentRemoteHost(host: "office-pc", remoteControl: false, lastUsed: Date(timeIntervalSince1970: 300))
            ])
        }
    }

    func testRecentStoreNormalisesHostsBeforeDeduplication() throws {
        try withDefaults { defaults in
            RecentRemoteHostStore.record(host: " Office-PC.Tail1234.ts.net. ", remoteControl: true,
                                         now: Date(timeIntervalSince1970: 100), defaults: defaults)
            let entries = RecentRemoteHostStore.record(host: "office-pc.tail1234.ts.net", remoteControl: true,
                                                       now: Date(timeIntervalSince1970: 200), defaults: defaults)
            XCTAssertEqual(entries, [
                RecentRemoteHost(host: "office-pc.tail1234.ts.net", remoteControl: true, lastUsed: Date(timeIntervalSince1970: 200))
            ])
            XCTAssertEqual(RecentRemoteHostStore.record(host: "http://pc", remoteControl: true, defaults: defaults), entries)
            XCTAssertEqual(RecentRemoteHostStore.load(defaults: defaults), entries)
        }
    }

    func testRecentStoreDropsTheOldestWhenASixthHostIsRecorded() throws {
        try withDefaults { defaults in
            let cases: [(host: String, time: TimeInterval)] = [
                ("pc-one", 100), ("pc-two", 200), ("pc-three", 300),
                ("pc-four", 400), ("pc-five", 500), ("pc-six", 600)
            ]
            for row in cases {
                RecentRemoteHostStore.record(host: row.host, remoteControl: true,
                                             now: Date(timeIntervalSince1970: row.time), defaults: defaults)
            }
            XCTAssertEqual(RecentRemoteHostStore.load(defaults: defaults).map(\.host), [
                "pc-six", "pc-five", "pc-four", "pc-three", "pc-two"
            ])
        }
    }

    func testRecentStoreRemoveKeepsTheOtherMode() throws {
        try withDefaults { defaults in
            RecentRemoteHostStore.record(host: "office-pc", remoteControl: true,
                                         now: Date(timeIntervalSince1970: 100), defaults: defaults)
            RecentRemoteHostStore.record(host: "office-pc", remoteControl: false,
                                         now: Date(timeIntervalSince1970: 200), defaults: defaults)
            let expected = [RecentRemoteHost(host: "office-pc", remoteControl: false, lastUsed: Date(timeIntervalSince1970: 200))]
            XCTAssertEqual(RecentRemoteHostStore.remove(host: "OFFICE-PC.", remoteControl: true, defaults: defaults), expected)
            XCTAssertEqual(RecentRemoteHostStore.load(defaults: defaults), expected)
            XCTAssertEqual(RecentRemoteHostStore.remove(host: "missing-pc", remoteControl: true, defaults: defaults), expected)
            XCTAssertEqual(RecentRemoteHostStore.remove(host: "office-pc", remoteControl: false, defaults: defaults), [])
            XCTAssertEqual(RecentRemoteHostStore.load(defaults: defaults), [])
        }
    }

    func testRecentStoreLoadsRecentEntriesFromTheSpecifiedJSONKey() throws {
        try withDefaults { defaults in
            let older = RecentRemoteHost(host: "home-pc", remoteControl: false, lastUsed: Date(timeIntervalSince1970: 100))
            let newer = RecentRemoteHost(host: "office-pc", remoteControl: true, lastUsed: Date(timeIntervalSince1970: 200))
            defaults.set(try JSONEncoder().encode([newer, older]), forKey: "ScreenCasting.client.recentRemoteHosts.v1")
            XCTAssertEqual(RecentRemoteHostStore.load(defaults: defaults), [newer, older])
        }
    }

    func testRecentStoreLoadsMissingOrCorruptDataAsEmpty() throws {
        try withDefaults { defaults in
            XCTAssertEqual(RecentRemoteHostStore.load(defaults: defaults), [])
            for json in ["not-json", "{}", "[{\"host\":\"office-pc\"}]"] {
                defaults.set(Data(json.utf8), forKey: "ScreenCasting.client.recentRemoteHosts.v1")
                XCTAssertEqual(RecentRemoteHostStore.load(defaults: defaults), [], json)
            }
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "RemoteHostDirectoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
