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
    private var advertised=false, helloSent=false, foreground=true, suspended=false
    private var state:MirrorControlState?
    private var rendered:UInt32?, acknowledgedEpoch:UInt64?
    private var lastAcknowledged:UInt32?
    private var transportFloor:UInt64?
    public init() {}
    private func synchronized<T>(_ body:()->T)->T { lock.lock();defer{lock.unlock()};return body() }

    public func beginSession(_ generation:UInt64) {
        synchronized {
            session=generation;revision &+= 1;ordinal=0;advertised=false;helloSent=false
            state=nil;rendered=nil;acknowledgedEpoch=nil;lastAcknowledged=nil;suspended=false;transportFloor=nil
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
            return Data([1,0,0,0,flags & 0x2000 != 0 ? 3:1,0,0,0])
        }
    }
    public var currentState:MirrorControlState? { synchronized{state} }
    /// Once PMR is advertised, absence of a descriptor is not permission to send legacy input.
    public var allowsLegacyVirtualInput:Bool { synchronized{session != 0 && foreground && (!advertised || state?.mode == .virtualDisplay)} }

    public var gestureRevision:UInt64 { synchronized{revision} }

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
        if let floor=transportFloor, next.epoch>=floor, next.mode != .active {
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
        guard transportFloor == nil,foreground,!suspended,let s=state,let first=s.firstFrame,let seen=rendered,
              s.mode == .awaitingPresentation || s.mode == .viewOnly || s.mode == .active,
              MirrorControlCodec.sequenceAtOrAfter(seen,first) else {return nil}
        guard acknowledgedEpoch != s.epoch else {return nil}
        acknowledgedEpoch=s.epoch;lastAcknowledged=seen
        return Self.action(kind:2,epoch:s.epoch,source:s.source,sequence:seen)
    }
    /// Returning foreground does NOT reuse a previously revoked token.
    @discardableResult public func setForeground(_ active:Bool)->Data? {
        synchronized {
            foreground=active
            guard !active else {return nil}
            revision &+= 1;ordinal=0;suspended=true
            guard let s=state,s.epoch>0,s.source>0 else {return nil}
            return Self.action(kind:3,epoch:s.epoch,source:s.source,sequence:0)
        }
    }
    public func suspendInput()->Data? {
        synchronized {
            revision &+= 1; ordinal=0; suspended=true
            guard let s=state,s.epoch>0,s.source>0 else {return nil}
            return Self.action(kind:3,epoch:s.epoch,source:s.source,sequence:0)
        }
    }
    /// Called before replacing an established media sequence domain on the same connection.
    public func retireTransportPresentation() {
        synchronized {
            guard advertised, let s=state, s.mode != .virtualDisplay else { return }
            revision &+= 1;ordinal=0;suspended=true;rendered=nil;acknowledgedEpoch=nil;lastAcknowledged=nil
            transportFloor=s.mode == .active ? (s.epoch == UInt64.max ? UInt64.max:s.epoch+1):s.epoch
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
    public func captureTicket()->MirrorInputTicket? {
        synchronized {
            guard transportFloor == nil,foreground,!suspended,let s=state,s.mode == .active,!s.token.isEmpty,
                  acknowledgedEpoch==s.epoch,let first=s.firstFrame,let seen=rendered,
                  MirrorControlCodec.sequenceAtOrAfter(seen,first) else {return nil}
            return MirrorInputTicket(session:session,uiRevision:revision,epoch:s.epoch,source:s.source,token:s.token)
        }
    }
    /// Invoke on the serialized control-send lane. Movement may be coalesced; terminal input must not be.
    public func encodeInput(ticket:MirrorInputTicket,kind:MirrorInputKind,payload:Data)throws->Data {
        lock.lock();defer{lock.unlock()}
        guard transportFloor == nil,foreground,!suspended,let s=state,s.mode == .active,acknowledgedEpoch==s.epoch,
              ticket.session==session,ticket.uiRevision==revision,ticket.epoch==s.epoch,
              ticket.source==s.source,ticket.token==s.token else {throw MirrorControlError.stale}
        guard ordinal != UInt64.max else {suspended=true;throw MirrorControlError.sequenceExhausted}
        ordinal+=1
        return try MirrorControlCodec.encodeInput(MirrorInputEnvelope(epoch:s.epoch,source:s.source,token:s.token,sequence:ordinal,kind:kind,payload:payload))
    }
    static func action(kind:UInt8,epoch:UInt64,source:UInt64,sequence:UInt32)->Data {
        var b=[UInt8](repeating:0,count:32);b[0]=1;b[1]=kind
        MirrorControlCodec.put(epoch,&b,4,8);MirrorControlCodec.put(source,&b,12,8);MirrorControlCodec.put(UInt64(sequence),&b,20,4)
        return Data(b)
    }
}
