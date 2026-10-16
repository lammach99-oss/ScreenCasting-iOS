import Foundation
import Network
import Security

final class InteropSession {
    let queue = DispatchQueue(label: "wan.interop.owner")
    private var current: QuicConnectionOwner?
    func start(host: String, port: UInt16, generation: UInt64, ca: Data, alpn: String = TestProtocol.alpn) {
        queue.async { [self] in
            current?.retire(reason: "replacement_start", initiator: "start")
            guard generation > 0, let certificate = SecCertificateCreateWithData(nil, ca as CFData) else { return }
            let o = QuicConnectionOwner(generation: generation)
            o.diagnosticEndpoint = "\(host):\(port)"
            o.diagnosticALPN = alpn
            current = o
            o.trace("session_owner_detail", details: ["evidenceRunID": EventLog.snapshot().runID])
            let parameters = QuicConnectionOwner.parameters(host: host, ca: certificate, alpn: alpn)
            let descriptor = NWMultiplexGroup(to: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!))
            let group = NWConnectionGroup(with: descriptor, using: parameters)
            o.group = group
            group.newConnectionHandler = { [weak self, weak o] connection in
                guard let self, let o, self.isCurrent(o) else { connection.cancel(); return }
                // This diagnostic protocol opens exactly one client-originated stream.
                connection.cancel()
                self.fail(o, "unexpected_stream")
            }
            group.stateUpdateHandler = { [weak self, weak o] state in
                guard let self, let o, self.isCurrent(o) else { return }
                o.trace("group_state_detail", details: ["networkState": String(describing: state).prefix(512).description])
                switch state {
                case .ready:
                    guard let metadata = o.group?.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata,
                          metadata.negotiatedALPN == TestProtocol.alpn else { self.fail(o, "alpn_mismatch"); return }
                    EventLog.write("group_ready_exact_alpn", generation: generation, owner: o.id)
                    self.openLanes(o)
                case .failed(let error):
                    o.trace("group_failed_detail", details: LaneEvidence.fields(role: "group", laneID: o.id, state: "failed", error: error))
                    self.fail(o, "group_failed")
                default: break
                }
            }
            group.start(queue: queue)
        }
    }
    func stop() { queue.async { [self] in current?.retire(reason: "operator_stop", initiator: "stop"); current = nil } }
    private func isCurrent(_ o: QuicConnectionOwner) -> Bool { current === o && o.accepts(o.generation) }
    private func fail(_ o: QuicConnectionOwner, _ event: String, details: [String: Any] = [:]) {
        EventLog.write(event, generation: o.generation, owner: o.id, details: details)
        o.retire(reason: event, initiator: "InteropSession.fail")
    }
    private func openLanes(_ o: QuicConnectionOwner) {
        guard isCurrent(o), o.control == nil, o.datagrams == nil, let group = o.group else { return }
        let controlOptions = NWProtocolQUIC.Options(alpn: [TestProtocol.alpn])
        controlOptions.direction = .bidirectional
        let datagramOptions = NWProtocolQUIC.Options(alpn: [TestProtocol.alpn])
        datagramOptions.isDatagram = true
        guard let control = group.extract(connectionTo: nil, using: controlOptions),
              let datagrams = group.extract(connectionTo: nil, using: datagramOptions) else { fail(o, "extract_failed"); return }
        // Both lanes are extracted from this one multiplex group. Never create
        // a standalone NWConnection as a fallback.
        o.control = control; o.datagrams = datagrams
        for (lane, isDatagram) in [(control, false), (datagrams, true)] {
            let role = isDatagram ? "datagram" : "control"
            let laneID = isDatagram ? o.datagramLaneID : o.controlLaneID
            o.trace("lane_created_detail", details: LaneEvidence.fields(role: role, laneID: laneID, state: "extracted"))
            lane.stateUpdateHandler = { [weak self, weak o] state in
                guard let self, let o, self.isCurrent(o) else { return }
                o.trace("lane_state_detail", details: LaneEvidence.fields(role: role, laneID: laneID, state: String(describing: state).prefix(512).description))
                switch state {
                case .ready:
                    EventLog.write(isDatagram ? "datagram_same_group" : "control_same_group", generation: o.generation, owner: o.id)
                    if isDatagram { self.receiveDatagram(o) } else { self.receiveControl(o) }
                    self.probeWhenReady(o)
                case .failed(let error): self.fail(o, "lane_failed", details:
                    LaneEvidence.fields(role: role, laneID: laneID, state: "failed", error: error))
                default: break
                }
            }
            o.trace("lane_start_detail", details: LaneEvidence.fields(role: role, laneID: laneID, state: "start"))
            lane.start(queue: queue)
        }
    }
    private func send(_ o: QuicConnectionOwner, lane: NWConnection, data: Data, sequence: UInt32) {
        guard isCurrent(o), o.pendingSends < 128 else { return }
        o.pendingSends += 1
        lane.send(content: data, completion: .contentProcessed { [weak self, weak o] error in
            guard let self, let o else { return }
            o.pendingSends -= 1 // own bookkeeping even after retirement
            guard self.isCurrent(o) else { return }
            EventLog.write(error == nil ? "send_processed" : "send_rejected",
                generation: o.generation, owner: o.id, sequence: sequence, value: data.count)
        })
    }
    private func probeWhenReady(_ o: QuicConnectionOwner) {
        guard !o.probed, let control = o.control, let lane = o.datagrams,
              control.state == .ready, lane.state == .ready else { return }
        o.probed = true
        do {
            for i in 0..<16 {
                let sequence = UInt32(i)
                let r = TestProtocol.Record(opcode: 1, generation: o.generation, sequence: sequence, body: Data([0x5a]))
                send(o, lane: control, data: try TestProtocol.control(r), sequence: sequence)
            }
            try DatagramLane.probe(owner: o) { data, sequence in self.send(o, lane: lane, data: data, sequence: sequence) }
        } catch { fail(o, "probe_fault") }
    }
    private func receiveControl(_ o: QuicConnectionOwner) {
        o.control?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self, weak o] data, _, complete, error in
            guard let self, let o, self.isCurrent(o) else { return }
            do {
                if let data { for r in try o.framer.feed(data) {
                    guard r.opcode == 2, r.sequence == o.nextReply else { throw TestProtocol.Failure.invalid }
                    o.nextReply += 1
                    EventLog.write("control_reply", generation: o.generation, owner: o.id, sequence: r.sequence)
                }}
                if complete { try o.framer.finish() }
                if error != nil { self.fail(o, "control_receive_failed") }
                else if !complete { self.receiveControl(o) }
            } catch { self.fail(o, "control_protocol_fault") }
        }
    }
    private func receiveDatagram(_ o: QuicConnectionOwner) {
        o.datagrams?.receiveMessage { [weak self, weak o] data, _, _, error in
            guard let self, let o, self.isCurrent(o) else { return }
            do {
                if let data {
                    let r = try TestProtocol.decodeDatagram(data, generation: o.generation, channel: 1)
                    EventLog.write("host_datagram_received", generation: o.generation,
                        owner: o.id, sequence: r.sequence, value: data.count)
                    if r.sequence >= 10000, let lane = o.datagrams {
                        self.send(o, lane: lane, data: try TestProtocol.datagram(r, channel: 2), sequence: r.sequence)
                    }
                }
                if error != nil { self.fail(o, "datagram_receive_failed") }
                else { self.receiveDatagram(o) }
            } catch { self.fail(o, "datagram_protocol_fault") }
        }
    }
}
