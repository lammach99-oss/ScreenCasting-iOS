import Foundation
import Network
import Security

struct MinimalSnapshot {
    var runID = ""
    var groupID = ""
    var controlID = ""
    var groupState = "idle"
    var controlState = "idle"
    var lastEvent = ""
    var replies = 0
    var complete = true
    var drops = 0
    var truncated = false
    var storageError = ""
}

final class MinimalQuicSession {
    private let queue = DispatchQueue(label: "wan.minimal.owner")
    private final class Run {
        var gate: MinimalRunGate
        let evidence: MinimalEvidence
        var group: NWConnectionGroup?
        var control: NWConnection?
        var decoder: MinimalControlProtocol.ReplyDecoder
        var sent = false
        var snapshot = MinimalSnapshot()
        init(identity: MinimalIdentity) {
            gate = MinimalRunGate(identity: identity)
            decoder = MinimalControlProtocol.ReplyDecoder(generation: identity.generation)
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Minimal-" + identity.runID.uuidString + ".jsonl")
            evidence = MinimalEvidence(identity: identity, fileURL: url)
            snapshot.runID = identity.runID.uuidString
            snapshot.groupID = identity.groupID.uuidString
            snapshot.controlID = identity.controlID.uuidString
        }
    }
    private var current: Run?
    var onSnapshot: ((MinimalSnapshot) -> Void)?
    private func accepts(_ run: Run) -> Bool { current === run && run.gate.accepts(run.gate.identity) }
    private func emit(_ run: Run, _ event: String, _ fields: [String: Any] = [:], critical: Bool = true) {
        guard current === run else { return }
        run.evidence.record(event, identity: run.gate.identity, fields: fields, critical: critical)
        run.snapshot.lastEvent = event
        run.snapshot.complete = run.evidence.captureComplete
        run.snapshot.drops = run.evidence.droppedDiagnostics
        run.snapshot.truncated = run.evidence.truncated
        run.snapshot.storageError = run.evidence.storageError ?? ""
        let snapshot = run.snapshot
        DispatchQueue.main.async { [weak self] in self?.onSnapshot?(snapshot) }
    }
    func start(host: String, port: UInt16, generation: UInt64, alpn: String, ca: Data) {
        queue.async { [self] in
            if let old = current { retire(old, reason: "replacement_start") }
            let run = Run(identity: MinimalIdentity(generation: generation))
            current = run
            emit(run, "run_started")
            emit(run, "endpoint_detail", ["host": host, "port": port, "alpn": alpn, "datagramEnabled": false])
            let bundle = Bundle.main
            emit(run, "device_runtime_detail", ["bundleID": bundle.bundleIdentifier ?? "unknown",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "architecture": Self.architecture, "deviceModel": "NOT_EXPOSED_BY_PINNED_PUBLIC_API",
                "networkFrameworkImage": "NOT_EXPOSED_BY_PINNED_PUBLIC_API",
                "sourceSHA": bundle.object(forInfoDictionaryKey: "ReproSourceSHA") as? String ?? "unknown",
                "xcode": bundle.object(forInfoDictionaryKey: "ReproXcode") as? String ?? "unknown",
                "sdk": bundle.object(forInfoDictionaryKey: "ReproSDK") as? String ?? "unknown",
                "ipaSHA256": "EXTERNAL_PACKAGE_MANIFEST"])
            guard generation == 1, port != 0, !host.isEmpty, alpn == MinimalControlProtocol.alpn,
                  let certificate = SecCertificateCreateWithData(nil, ca as CFData) else {
                retire(run, reason: "invalid_configuration"); return
            }
            let quic = NWProtocolQUIC.Options(alpn: [alpn])
            quic.direction = .bidirectional
            // Preserve the harness group capability; no DATAGRAM child is created.
            quic.maxDatagramFrameSize = 65535
            sec_protocol_options_set_tls_server_name(quic.securityProtocolOptions, host)
            sec_protocol_options_set_verify_block(quic.securityProtocolOptions, { _, securityTrust, complete in
                let trust = sec_trust_copy_ref(securityTrust).takeRetainedValue()
                let policy = SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
                let anchors = SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
                let only = SecTrustSetAnchorCertificatesOnly(trust, true)
                complete(policy == errSecSuccess && anchors == errSecSuccess && only == errSecSuccess
                    && SecTrustEvaluateWithError(trust, nil))
            }, queue)
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
            let group = NWConnectionGroup(with: NWMultiplexGroup(to: endpoint), using: NWParameters(quic: quic))
            run.group = group
            emit(run, "group_created", ["groupPath": "NOT_EXPOSED_BY_PINNED_PUBLIC_API"])
            group.newConnectionHandler = { [weak self, weak run] connection in
                guard let self, let run, self.accepts(run) else { connection.cancel(); return }
                self.emit(run, "unexpected_incoming_stream")
                connection.cancel()
                self.retire(run, reason: "unexpected_incoming_stream")
            }
            group.stateUpdateHandler = { [weak self, weak run, weak group] state in
                guard let self, let run, self.accepts(run) else { return }
                run.snapshot.groupState = String(describing: state)
                self.emit(run, "group_state_detail", Self.stateFields(state))
                switch state {
                case .ready:
                    guard let metadata = group?.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata,
                          metadata.negotiatedALPN == MinimalControlProtocol.alpn else {
                        self.retire(run, reason: "alpn_mismatch"); return
                    }
                    self.emit(run, "group_ready_exact_alpn", ["alpn": metadata.negotiatedALPN ?? ""])
                    self.openControl(run)
                case .failed: self.retire(run, reason: "group_failed")
                default: break
                }
            }
            group.start(queue: queue)
        }
    }
    private func openControl(_ run: Run) {
        guard accepts(run), run.gate.requestControl(), let group = run.group else { return }
        let options = NWProtocolQUIC.Options(alpn: [MinimalControlProtocol.alpn])
        options.direction = .bidirectional
        options.isDatagram = false
        emit(run, "control_construction_detail", ["api": "extract(connectionTo:using:)",
            "endpoint": "nil", "direction": "bidirectional", "isDatagram": false])
        guard let control = group.extract(connectionTo: nil, using: options) else {
            retire(run, reason: "control_extract_failed"); return
        }
        run.control = control
        emit(run, "control_created")
        control.pathUpdateHandler = { [weak self, weak run] path in
            guard let self, let run, self.accepts(run) else { return }
            self.emit(run, "control_path_detail", Self.pathFields(path), critical: false)
        }
        control.stateUpdateHandler = { [weak self, weak run, weak control] state in
            guard let self, let run, self.accepts(run) else { return }
            run.snapshot.controlState = String(describing: state)
            var fields = Self.stateFields(state)
            if let path = control?.currentPath { fields.merge(Self.pathFields(path)) { _, new in new } }
            if let metadata = control?.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata {
                fields["streamID"] = metadata.streamIdentifier
            }
            self.emit(run, "control_state_detail", fields)
            switch state {
            case .ready:
                guard !run.sent else { return }
                run.sent = true
                self.receive(run)
                let data = MinimalControlProtocol.request(generation: run.gate.identity.generation)
                control?.send(content: data, completion: .contentProcessed { [weak self, weak run] error in
                    guard let self, let run, self.accepts(run) else { return }
                    self.emit(run, "control_send_detail", Self.errorFields(error).merging(["bytes": data.count]) { _, new in new })
                    if error != nil { self.retire(run, reason: "control_send_failed") }
                })
            case .failed(let error):
                self.emit(run, "control_failed", Self.errorFields(error))
                self.retire(run, reason: "control_failed")
            default: break
            }
        }
        emit(run, "control_start")
        control.start(queue: queue)
    }
    private func receive(_ run: Run) {
        run.control?.receive(minimumIncompleteLength: 1, maximumLength: 4100) { [weak self, weak run] data, _, complete, error in
            guard let self, let run, self.accepts(run) else { return }
            self.emit(run, "control_receive_detail", Self.errorFields(error).merging(
                ["bytes": data?.count ?? 0, "isComplete": complete]) { _, new in new })
            do {
                if let data, try run.decoder.feed(data) {
                    run.snapshot.replies += 1
                    self.emit(run, "control_reply", ["controlReplies": run.snapshot.replies])
                }
                if complete { try run.decoder.finish() }
                if error != nil { self.retire(run, reason: "control_receive_failed") }
                else if !complete && !run.decoder.received { self.receive(run) }
            } catch { self.retire(run, reason: "control_protocol_failed") }
        }
    }
    private func retire(_ run: Run, reason: String) {
        guard accepts(run) else { return }
        emit(run, "run_retired", ["initiator": "apple", "reason": reason])
        run.gate.retire()
        run.control?.cancel()
        run.group?.cancel()
        run.control?.stateUpdateHandler = nil
        run.control?.pathUpdateHandler = nil
        run.group?.stateUpdateHandler = nil
        run.group?.newConnectionHandler = nil
    }
    func stop() { queue.async { [self] in if let run = current { retire(run, reason: "operator_retire") } } }
    func export(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [self] in
            guard let run = current else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("MinimalQuicRepro-" + run.gate.identity.runID.uuidString + ".jsonl")
            let result = Result { try run.evidence.export(to: url); return url }
            DispatchQueue.main.async { completion(result) }
        }
    }
    private static func errorFields(_ error: NWError?) -> [String: Any] {
        guard let error else { return ["errorDomain": "none", "errorCode": 0] }
        var fields: [String: Any] = ["errorDescription": String(describing: error).prefix(512).description]
        switch error {
        case .posix(let code): fields["errorDomain"] = "POSIX"; fields["errorCode"] = code.rawValue
        case .tls(let code): fields["errorDomain"] = "TLS"; fields["errorCode"] = code
        case .dns(let code): fields["errorDomain"] = "DNS"; fields["errorCode"] = code
        @unknown default: fields["errorDomain"] = "unknown"
        }
        return fields
    }
    private static func stateFields(_ state: NWConnection.State) -> [String: Any] {
        var fields: [String: Any] = ["networkState": String(describing: state).prefix(512).description]
        switch state {
        case .waiting(let error), .failed(let error): fields.merge(errorFields(error)) { _, new in new }
        default: break
        }
        return fields
    }
    private static func stateFields(_ state: NWConnectionGroup.State) -> [String: Any] {
        var fields: [String: Any] = ["networkState": String(describing: state).prefix(512).description]
        switch state {
        case .waiting(let error), .failed(let error): fields.merge(errorFields(error)) { _, new in new }
        default: break
        }
        return fields
    }
    private static func pathFields(_ path: NWPath) -> [String: Any] {
        let types: [(NWInterface.InterfaceType, String)] = [(.wifi, "wifi"), (.cellular, "cellular"),
            (.wiredEthernet, "wiredEthernet"), (.loopback, "loopback"), (.other, "other")]
        return ["pathStatus": String(describing: path.status), "isExpensive": path.isExpensive,
            "isConstrained": path.isConstrained, "supportsIPv4": path.supportsIPv4,
            "supportsIPv6": path.supportsIPv6, "interfaces": types.filter { path.usesInterfaceType($0.0) }.map { $0.1 }]
    }
    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "other"
        #endif
    }
}
