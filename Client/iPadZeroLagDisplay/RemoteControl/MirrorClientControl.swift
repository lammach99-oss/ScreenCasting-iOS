import Foundation

public struct MirrorInputTicket: Equatable {
    public let session:UInt64, uiRevision:UInt64, epoch:UInt64, source:UInt64, token:MirrorToken
}
public struct MirrorClientTransition {
    public let retireGestures:Bool
    public let acknowledgement:Data?
    public let state:MirrorControlState
}

/// Concrete transport-independent Client state. No UIKit/network side effects.
/// Capture a ticket when installing gesture/key callbacks, NOT inside the delayed network queue.
/// On retireGestures, cancel Pencil/direct contacts/buttons/keys before rebinding new callbacks.
public final class MirrorClientControl {
    private let lock=NSLock()
    private var session:UInt64=0, revision:UInt64=0, ordinal:UInt64=0
    private var advertised=false, helloSent=false, foreground=true, suspended=false, settingsOpen=false
    private var state:MirrorControlState?
    private var rendered:UInt32?, acknowledgedEpoch:UInt64?
    private var lastAcknowledged:UInt32?
    private var transportFloor:UInt64?
    private var terminalCapable=false
    private var screenPickerCapable=false
    private var captureTargetInputBlocked=false
    private var typedSources=false
    private struct TerminalSwitch {
        let nonce:UInt64, epoch:UInt64, source:UInt64
        var retiredEpoch:UInt64?
    }
    private var terminalSwitch:TerminalSwitch?
    public init() {}
    private func synchronized<T>(_ body:() throws->T) rethrows->T { lock.lock();defer{lock.unlock()};return try body() }

    public func beginSession(_ generation:UInt64) {
        synchronized {
            session=generation;revision &+= 1;ordinal=0;advertised=false;helloSent=false
            state=nil;rendered=nil;acknowledgedEpoch=nil;lastAcknowledged=nil;suspended=false;transportFloor=nil;settingsOpen=false
            terminalCapable=false;terminalSwitch=nil;screenPickerCapable=false;captureTargetInputBlocked=false;typedSources=false
        }
    }
    public func endSession() {beginSession(0)}
    /// Call only after an authenticated DisplayCapabilities advertises PMR v1.
    public func helloIfAdvertised(session generation:UInt64,flags:UInt16)->Data? {
        synchronized {
            guard generation != 0,generation==session,flags & MirrorControlCodec.advertisementFlag != 0 else {return nil}
            advertised=true
            guard !helloSent else {return nil}
            helloSent=true
            terminalCapable=(flags & 0x7000)==0x7000
            screenPickerCapable=flags & MirrorControlCodec.screenPickerFlag != 0
            return Data([1,0,0,0,terminalCapable ? 7:(flags & 0x2000 != 0 ? 3:1),0,0,0])
        }
    }
    public var currentState:MirrorControlState? { synchronized{state} }
    public var hasPresentedCurrentSource:Bool {
        synchronized {
            guard transportFloor == nil,foreground,let s=state,let first=s.firstFrame,let seen=rendered,
                  s.mode == .awaitingPresentation || s.mode == .viewOnly || s.mode == .active else {return false}
            return acknowledgedEpoch==s.epoch && MirrorControlCodec.sequenceAtOrAfter(seen,first)
        }
    }
    /// Once PMR is advertised, absence of a descriptor is not permission to send legacy input.
    public var allowsLegacyVirtualInput:Bool { synchronized{session != 0 && foreground && (!typedSources || !settingsOpen) && !captureTargetInputBlocked && (!advertised || state?.mode == .virtualDisplay)} }

    public var gestureRevision:UInt64 { synchronized{revision} }

    public func enableTypedSources(session generation: UInt64) {
        synchronized { if generation == session && generation != 0 { typedSources=true } }
    }
    public func legacyRegistrationIsCurrent(revision captured: UInt64) -> Bool {
        synchronized { !typedSources || captured == revision && !captureTargetInputBlocked }
    }

    /// Retire registrations in either input mode without revoking the Host's attended consent.
    public func setCaptureTargetInputBlocked(_ blocked: Bool, session generation: UInt64? = nil) {
        synchronized {
            guard generation == nil || generation == session else { return }
            guard captureTargetInputBlocked != blocked else { return }
            captureTargetInputBlocked=blocked;revision &+= 1
            if blocked { rendered=nil;acknowledgedEpoch=nil;lastAcknowledged=nil }
        }
    }
    public func typedSwitchPermissionRequest(negotiated: Bool) -> Data? {
        synchronized {
            guard negotiated,advertised,screenPickerCapable,let s=state,s.epoch>0,
                  s.source>0 || s.mode == .virtualDisplay else { return nil }
            return Self.action(kind:8,epoch:s.epoch,source:s.source,sequence:0)
        }
    }

    /// Called on the network owner before assigning a decoder identity. Both TLS and RTP
    /// must reject delayed A media rather than stamping it with B's current decoder scope.
    public func permitsVideoSequence(_ sequence:UInt32)->Bool {
        synchronized {
            guard advertised else { return true }
            guard transportFloor == nil else { return false }
            guard let s=state else { return false }
            if s.mode == .virtualDisplay { return true }
            guard s.mode == .viewOnly || s.mode == .awaitingPresentation || s.mode == .active,
                  let first=s.firstFrame else { return false }
            return MirrorControlCodec.sequenceAtOrAfter(sequence,first)
        }
    }

    public func receiveState(session generation:UInt64,data:Data) throws -> MirrorClientTransition? {
        let next=try MirrorControlCodec.decodeState(data)
        lock.lock();defer{lock.unlock()}
        guard generation==session,generation != 0,advertised,helloSent else {throw MirrorControlError.denied}
        if let old=state {
            if next.revision <= old.revision {return nil}
            guard next.epoch >= old.epoch else {throw MirrorControlError.stale}
            // One epoch cannot silently acquire different content/physical geometry.
            if next.epoch==old.epoch && (next.source != old.source || next.geometry != old.geometry) {throw MirrorControlError.malformed}
        }
        let old=state
        let retire=old?.epoch != next.epoch || old?.source != next.source || old?.token != next.token || old?.mode != next.mode
        if retire {revision &+= 1;ordinal=0}
        if old?.epoch != next.epoch {acknowledgedEpoch=nil;lastAcknowledged=nil;rendered=nil}
        if old?.token != next.token || next.mode != .active {suspended=false}
        state=next
        if let floor=transportFloor, next.epoch>floor, next.mode != .active {
            transportFloor=nil
        }
        let ack=acknowledgeIfReady()
        return MirrorClientTransition(retireGestures:retire,acknowledgement:ack,state:next)
    }
    /// Call from the actual completed render callback after checking current decoder/session ownership.
    /// A queued decode, received packet or Host send completion is not a render observation.
    public func observeRendered(session generation:UInt64,sequence:UInt32)->Data? {
        synchronized {
            guard transportFloor == nil,generation != 0,generation==session,let s=state,let first=s.firstFrame,
                  MirrorControlCodec.sequenceAtOrAfter(sequence,first) else {return nil}
            if let previous=rendered,!MirrorControlCodec.sequenceAtOrAfter(sequence,previous) {return nil}
            rendered=sequence
            return acknowledgeIfReady()
        }
    }
    private func acknowledgeIfReady()->Data? {
        guard !captureTargetInputBlocked,terminalSwitch == nil,transportFloor == nil,foreground,!suspended,let s=state,let first=s.firstFrame,let seen=rendered,
              s.mode == .awaitingPresentation || s.mode == .viewOnly || s.mode == .active,
              MirrorControlCodec.sequenceAtOrAfter(seen,first) else {return nil}
        guard acknowledgedEpoch != s.epoch else {return nil}
        acknowledgedEpoch=s.epoch;lastAcknowledged=seen
        return Self.action(kind:2,epoch:s.epoch,source:s.source,sequence:seen)
    }
    /// Inactive/background is a local pause: the Host keeps its attended grant and token, and retired gestures
    /// may still deliver their releases. Returning foreground does NOT reuse a revoked token. Only a pending
    /// monitor switch is abandoned with a revoke, which lets the Host re-present its retained source.
    @discardableResult public func setForeground(_ active:Bool)->Data? {
        synchronized {
            guard foreground != active else {return nil}
            foreground=active;revision &+= 1
            guard !active,terminalSwitch != nil else {return nil}
            ordinal=0;suspended=true
            abandonTerminalSwitch()
            guard let s=state,s.epoch>0,s.source>0 else {return nil}
            return Self.action(kind:3,epoch:s.epoch,source:s.source,sequence:0)
        }
    }
    /// Settings over the stream is a local pause like background, except a monitor switch chosen there continues.
    public func setSettingsPresented(_ open:Bool) {
        synchronized {
            guard settingsOpen != open else {return}
            settingsOpen=open;revision &+= 1
        }
    }
    /// Explicit Release control: revokes the Host grant.
    public func suspendInput()->Data? {
        synchronized {
            revision &+= 1; ordinal=0; suspended=true
            abandonTerminalSwitch()
            guard let s=state,s.epoch>0,s.source>0 else {return nil}
            return Self.action(kind:3,epoch:s.epoch,source:s.source,sequence:0)
        }
    }
    /// Called before replacing an established media sequence domain on the same connection.
    public func retireTransportPresentation() {
        synchronized {
            guard advertised, let s=state, s.mode != .virtualDisplay else { return }
            revision &+= 1;ordinal=0;suspended=true;rendered=nil;acknowledgedEpoch=nil;lastAcknowledged=nil
            terminalSwitch=nil
            transportFloor=s.epoch
        }
    }
    public func presentationRecoveryRequest()->Data? {
        synchronized {
            guard transportFloor == nil,let s=state,s.firstFrame != nil,
                  s.mode == .awaitingPresentation || s.mode == .viewOnly else {return nil}
            return Self.action(kind:4,epoch:s.epoch,source:s.source,sequence:0)
        }
    }
    public func requestControl()->Data? {
        synchronized {
            guard foreground,let s=state,s.epoch>0,s.source>0 else {return nil}
            // This can only request attended Host consent, never grant itself control.
            return Self.action(kind:1,epoch:s.epoch,source:s.source,sequence:0)
        }
    }
    public var supportsTerminalSwitch:Bool {synchronized{terminalCapable}}
    public var supportsScreenPicker:Bool {synchronized{advertised && screenPickerCapable}}
    /// Asks the Host to resend its screen list. Grants nothing and never touches input.
    public func screenListRequest()->Data? {pickerAction(kind:7)}
    /// Asks the attended Host to allow monitor switching. The Host decides; nothing changes here.
    public func switchPermissionRequest()->Data? {pickerAction(kind:8)}
    private func pickerAction(kind:UInt8)->Data? {
        synchronized {
            guard advertised,screenPickerCapable,let s=state,s.epoch>0,s.source>0 else {return nil}
            return Self.action(kind:kind,epoch:s.epoch,source:s.source,sequence:0)
        }
    }
    public func beginTerminalSwitch(nonce:UInt64)->Data? {
        synchronized {
            guard terminalCapable,terminalSwitch == nil,nonce != 0,transportFloor == nil,
                  foreground,let s=state,s.epoch>0,s.source>0,
                  s.mode == .active || s.mode == .viewOnly || s.mode == .awaitingPresentation,
                  acknowledgedEpoch==s.epoch else {return nil}
            revision &+= 1;ordinal=0;suspended=true;rendered=nil;acknowledgedEpoch=nil;lastAcknowledged=nil
            transportFloor=s.epoch
            terminalSwitch=TerminalSwitch(nonce:nonce,epoch:s.epoch,source:s.source)
            var bytes=Array(Self.action(kind:3,epoch:s.epoch,source:s.source,sequence:0))
            bytes[0]=2;bytes[1]=5;MirrorControlCodec.put(nonce,&bytes,24,8)
            return Data(bytes)
        }
    }
    public func receiveTerminalAcknowledgement(session generation:UInt64,data:Data)throws {
        try synchronized {
            let b=Array(data)
            guard generation != 0,generation==session,terminalCapable,var pending=terminalSwitch else {throw MirrorControlError.stale}
            guard b.count==32,b[0]==2,b[1]==6,b[2]==0,b[3]==0,
                  MirrorControlCodec.read(b,20,4)==0,
                  MirrorControlCodec.read(b,24,8)==pending.nonce,
                  MirrorControlCodec.read(b,12,8)==pending.source,
                  MirrorControlCodec.read(b,4,8)>pending.epoch else {throw MirrorControlError.malformed}
            let epoch=MirrorControlCodec.read(b,4,8)
            guard pending.retiredEpoch == nil || pending.retiredEpoch==epoch else {throw MirrorControlError.stale}
            pending.retiredEpoch=epoch;terminalSwitch=pending
        }
    }
    public func takeTerminalSwitch(nonce:UInt64)->Bool {
        synchronized {
            guard let pending=terminalSwitch,pending.nonce==nonce,let s=state,
                  let retiredEpoch=pending.retiredEpoch,s.epoch==retiredEpoch,s.source==pending.source,
                  s.mode == .unavailable,s.token.isEmpty,s.firstFrame == nil else {return false}
            terminalSwitch=nil;suspended=true;return true
        }
    }
    /// Cancels only an unanswered request. After takeTerminalSwitch the Host owns the outcome (successor or
    /// re-presentation at a newer epoch); flooring it here would reject that media for good.
    public func cancelTerminalSwitch() {
        synchronized {
            guard terminalSwitch != nil else {return}
            abandonTerminalSwitch()
            revision &+= 1;ordinal=0;rendered=nil;acknowledgedEpoch=nil;lastAcknowledged=nil
            // A retired or still-active token is never reused; a non-active unretired source may re-acknowledge.
            suspended=transportFloor != nil || state?.mode == .active
        }
    }
    /// Caller holds the lock. Floors only an epoch the Host advanced past the request. Otherwise the requested
    /// source was never retired (switch policy off, lost request) and remains the current presentation.
    private func abandonTerminalSwitch() {
        guard let pending=terminalSwitch else {return}
        terminalSwitch=nil
        if let s=state,s.epoch>pending.epoch {transportFloor=s.epoch} else {transportFloor=nil}
    }
    public func captureTicket()->MirrorInputTicket? {
        synchronized {
            guard !captureTargetInputBlocked,terminalSwitch == nil,transportFloor == nil,foreground,!settingsOpen,!suspended,let s=state,s.mode == .active,!s.token.isEmpty,
                  acknowledgedEpoch==s.epoch,let first=s.firstFrame,let seen=rendered,
                  MirrorControlCodec.sequenceAtOrAfter(seen,first) else {return nil}
            return MirrorInputTicket(session:session,uiRevision:revision,epoch:s.epoch,source:s.source,token:s.token)
        }
    }
    /// Invoke on the serialized control-send lane. Movement may be coalesced; terminal input must not be.
    public func encodeInput(ticket:MirrorInputTicket,kind:MirrorInputKind,payload:Data)throws->Data {
        lock.lock();defer{lock.unlock()}
        guard !captureTargetInputBlocked,terminalSwitch == nil,transportFloor == nil,!suspended,let s=state,s.mode == .active,acknowledgedEpoch==s.epoch,
              ticket.session==session,ticket.epoch==s.epoch,
              ticket.source==s.source,ticket.token==s.token else {throw MirrorControlError.stale}
        // A local pause retires the gesture scope but not the Host grant: a held key, button or contact must still
        // reach the Host as its release instead of staying down on the PC.
        guard foreground && !settingsOpen && ticket.uiRevision==revision || Self.isRelease(kind:kind,payload:payload)
        else {throw MirrorControlError.stale}
        guard ordinal != UInt64.max else {suspended=true;throw MirrorControlError.sequenceExhausted}
        ordinal+=1
        return try MirrorControlCodec.encodeInput(MirrorInputEnvelope(epoch:s.epoch,source:s.source,token:s.token,sequence:ordinal,kind:kind,payload:payload))
    }
    static func isRelease(kind:MirrorInputKind,payload:Data)->Bool {
        let p=Array(payload)
        guard p.count>2 else {return false}
        switch kind {
        case .keyboard:return p[1]==KeyboardInputAction.keyUp.rawValue
        case .pointer:return p[1]==PointerInputAction.leftUp.rawValue
        case .directTouch:return p[1]==DirectTouchPhase.up.rawValue || p[1]==DirectTouchPhase.cancel.rawValue
        case .pencil:return p[2]==TouchEventType.up.rawValue
        case .text:return false
        }
    }
    static func action(kind:UInt8,epoch:UInt64,source:UInt64,sequence:UInt32)->Data {
        var b=[UInt8](repeating:0,count:32);b[0]=1;b[1]=kind
        MirrorControlCodec.put(epoch,&b,4,8);MirrorControlCodec.put(source,&b,12,8);MirrorControlCodec.put(UInt64(sequence),&b,20,4)
        return Data(b)
    }
}
