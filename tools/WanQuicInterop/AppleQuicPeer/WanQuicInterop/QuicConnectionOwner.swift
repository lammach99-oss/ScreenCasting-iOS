import Foundation
import Network
import Security

// All mutable owner state is confined to InteropSession.queue. A retired owner
// stays separate from its replacement; delayed completions capture that owner.
final class QuicConnectionOwner {
    let id = UUID()
    let generation: UInt64
    var live = true
    var group: NWConnectionGroup?
    var control: NWConnection?
    var datagrams: NWConnection?
    let framer: ControlStreamFramer
    var nextControl: UInt32 = 0
    var nextReply: UInt32 = 0
    var pendingSends = 0
    var probed = false
    init(generation: UInt64) {
        self.generation = generation
        framer = ControlStreamFramer(generation: generation)
    }
    func accepts(_ g: UInt64) -> Bool { live && g == generation }
    func retire() {
        guard live else { return }
        live = false // before cancelling callbacks
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