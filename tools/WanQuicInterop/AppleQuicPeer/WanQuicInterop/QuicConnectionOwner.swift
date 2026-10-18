import Foundation
import Network
import Security

enum ControlLaneExperimentMode: String, CaseIterable {
    case baselineConcurrent = "A0_baseline"
    case controlOnly = "A1_control_only"
    case serializedControlThenDatagram = "A2_serialized"
    case deferredControlOneQueueTurn = "A3_deferred_control"
}

struct ControlLaneExperiment {
    enum Action: Equatable { case concurrentLanes, controlOnly, datagramOnly, deferControl }
    let mode: ControlLaneExperimentMode
    private(set) var groupReadyOrdinal = 0
    private(set) var controlReadyOrdinal = 0
    private var started = false
    private var datagramRequested = false
    init(mode: ControlLaneExperimentMode = .baselineConcurrent) { self.mode = mode }
    mutating func groupReady() -> [Action] {
        groupReadyOrdinal += 1
        guard !started else { return [] }
        started = true
        switch mode {
        case .baselineConcurrent: return [.concurrentLanes]
        case .controlOnly, .serializedControlThenDatagram: return [.controlOnly]
        case .deferredControlOneQueueTurn: return [.deferControl]
        }
    }
    mutating func controlState(_ state: NWConnection.State) -> [Action] {
        guard started, case .ready = state else { return [] }
        controlReadyOrdinal += 1
        guard mode == .serializedControlThenDatagram, !datagramRequested else { return [] }
        datagramRequested = true
        return [.datagramOnly]
    }
    var fields: [String: Any] {
        ["experimentMode": mode.rawValue,
         "datagramEnabled": mode == .baselineConcurrent || mode == .serializedControlThenDatagram,
         "datagramStartPolicy": mode == .baselineConcurrent ? "concurrent_baseline" :
            (mode == .serializedControlThenDatagram ? "after_control_ready" : "suppressed"),
         "controlStartPolicy": mode == .deferredControlOneQueueTurn ? "one_serial_queue_turn" : "synchronous_group_ready",
         "controlConstructionAPI": "extract(connectionTo:using:)", "controlDirection": "bidirectional",
         "groupReadyOrdinal": groupReadyOrdinal, "controlReadyOrdinal": controlReadyOrdinal]
    }
}

// All mutable owner state is confined to InteropSession.queue. A retired owner
// stays separate from its replacement; delayed completions capture that owner.
final class QuicConnectionOwner {
    let evidenceIdentity: EvidenceIdentity
    var id: UUID { evidenceIdentity.ownerID }
    let generation: UInt64
    let controlLaneID = UUID()
    let datagramLaneID = UUID()
    private var diagnosticCount = 0
    private var criticalDiagnosticCount = 0
    var diagnosticEndpoint = ""
    var diagnosticALPN = ""
    var live = true
    var group: NWConnectionGroup?
    var control: NWConnection?
    var datagrams: NWConnection?
    let framer: ControlStreamFramer
    var nextControl: UInt32 = 0
    var nextReply: UInt32 = 0
    var pendingSends = 0
    var probed = false
    var experiment: ControlLaneExperiment
    init(generation: UInt64, evidenceIdentity: EvidenceIdentity, experimentMode: ControlLaneExperimentMode = .baselineConcurrent) {
        precondition(evidenceIdentity.generation == generation)
        self.evidenceIdentity = evidenceIdentity
        self.generation = generation
        experiment = ControlLaneExperiment(mode: experimentMode)
        framer = ControlStreamFramer(generation: generation)
    }
    func accepts(_ g: UInt64) -> Bool { live && g == generation }
    func trace(_ event: String, details: [String: Any]) {
        let state = details["networkState"] as? String ?? ""
        let critical = event.contains("failed") || event.contains("retired") || event.contains("cancel") ||
            event.contains("extract") || event.contains("created") || event.contains("waiting") ||
            state.contains("failed") || state.contains("cancelled") || state.contains("waiting")
        if critical {
            guard criticalDiagnosticCount < 128 else { EventLog.dropped(identity: evidenceIdentity); return }
            criticalDiagnosticCount += 1
        } else {
            guard diagnosticCount < 32 else { EventLog.dropped(identity: evidenceIdentity); return }
            diagnosticCount += 1
        }
        var fields = details
        fields["groupID"] = id.uuidString
        fields["endpoint"] = diagnosticEndpoint
        fields["alpn"] = diagnosticALPN
        fields["experimentMode"] = experiment.mode.rawValue
        EventLog.write(event, identity: evidenceIdentity, details: fields, critical: critical)
    }
    func retire(reason: String = "explicit_retire", initiator: String = "caller") {
        guard live else { return }
        EventLog.write("owner_retired_detail", identity: evidenceIdentity,
            details: ["retirementReason": reason, "initiator": initiator, "groupID": id.uuidString], critical: true)
        live = false // before cancelling callbacks
        trace("cancel_callsite_detail", details: ["controlLaneID": controlLaneID.uuidString, "datagramLaneID": datagramLaneID.uuidString, "callsite": "QuicConnectionOwner.retire", "reason": reason])
        control?.cancel()
        datagrams?.cancel()
        group?.cancel()
    }
    static func parameters(host: String, ca: SecCertificate, alpn: String) -> NWParameters {
        let quic = NWProtocolQUIC.Options(alpn: [alpn])
        quic.direction = .bidirectional
        quic.maxDatagramFrameSize = 65535
        sec_protocol_options_set_tls_server_name(quic.securityProtocolOptions, host)
        sec_protocol_options_set_verify_block(quic.securityProtocolOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            // Exact endpoint DNS/IP policy, dedicated CA, expiry validation.
            let policy = SecPolicyCreateSSL(true, host as CFString)
            let policyStatus = SecTrustSetPolicies(secTrust, policy)
            let anchorsStatus = SecTrustSetAnchorCertificates(secTrust, [ca] as CFArray)
            let onlyStatus = SecTrustSetAnchorCertificatesOnly(secTrust, true)
            complete(policyStatus == errSecSuccess && anchorsStatus == errSecSuccess
                && onlyStatus == errSecSuccess && SecTrustEvaluateWithError(secTrust, nil))
        }, DispatchQueue(label: "wan.interop.trust"))
        return NWParameters(quic: quic)
    }
}
