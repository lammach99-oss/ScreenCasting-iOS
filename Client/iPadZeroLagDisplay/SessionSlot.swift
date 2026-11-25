import Foundation

enum SlotOrdinal: Int, Codable {
    case one = 1, two
    var alternate: Self { self == .one ? .two : .one }
}

// Canonical SHA-256 trust-directory key. No endpoint, credential or display name.
struct TrustedPeerReference: Equatable {
    let fingerprint: String

    init?(_ fingerprint: String) {
        let groups = fingerprint.split(separator: ":", omittingEmptySubsequences: false)
        guard groups.count == 1 || (groups.count == 32 && groups.allSatisfy { $0.utf8.count == 2 }) else { return nil }
        let bytes = Array(groups.joined().utf8)
        guard bytes.count == 64,
              bytes.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { return nil }
        self.fingerprint = stride(from: 0, to: 64, by: 2).map {
            String(decoding: bytes[$0..<($0 + 2)], as: UTF8.self).uppercased()
        }.joined(separator: ":")
    }
}

enum SlotRoute { case wifi, tailscale }
enum SlotPhase { case idle, connecting, authenticated, parked, resuming, active, offline, refused }
enum SlotPreview: Equatable { case none, placeholder, thumbnail(revision: UInt64) }
enum SlotFailure { case transport, busy, refused, forgotten, identityMismatch, duplicatePeer }

struct SlotTicket: Equatable {
    let ordinal: SlotOrdinal
    let generation: UInt64
    let epoch: UInt64
}

struct SessionSlot {
    let ordinal: SlotOrdinal
    var peer: TrustedPeerReference?
    var route: SlotRoute?
    var phase: SlotPhase = .idle
    var generation: UInt64 = 0
    var epoch: UInt64 = 0
    var preview: SlotPreview = .none
    var lastError: SlotFailure?
    var retryRequested = false
    var ticket: SlotTicket { SlotTicket(ordinal: ordinal, generation: generation, epoch: epoch) }
}
