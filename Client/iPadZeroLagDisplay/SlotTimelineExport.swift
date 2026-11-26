import Foundation

enum SlotTransportClass: String, Codable { case wifi, tailscale, usb }

@MainActor
final class SlotTimelineExport {
    enum Event: String, Codable {
        case tap, request, acknowledged, receivedIDR, decoded, presented, inputReady
        case transportError, unavailable, refused, stale
    }

    private struct Entry: Encodable {
        let slot: SlotOrdinal
        let route: SlotTransportClass
        let epoch: UInt64
        let event: Event
        let elapsedMs: UInt64
    }

    private let start = DispatchTime.now().uptimeNanoseconds
    private var timelines: [SlotOrdinal: [Entry]] = [:]

    func record(slot: SlotOrdinal, route: SlotTransportClass, epoch: UInt64, event: Event) {
        let elapsed = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        if timelines[slot]?.count == 256 { timelines[slot]?.removeFirst() }
        timelines[slot, default: []].append(Entry(slot: slot, route: route, epoch: epoch,
                                                  event: event, elapsedMs: elapsed))
    }

    func export(hasSecondary: Bool, singleSession: () throws -> Data) throws -> Data {
        guard hasSecondary else { return try singleSession() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode((timelines[.one] ?? []) + (timelines[.two] ?? []))
    }
}
