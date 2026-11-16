import UIKit
import GameController

extension IPadInputSession {
    /// Snapshot every routing authority when installing the sink. A terminal is never
    /// rebound to the next source, Mirror ticket, remote token, epoch, or generation.
    func bind(_ network: NetworkManager, active: Bool) {
        engine.physicalKeyIsDown = { usage in
            GCKeyboard.coalesced?.keyboardInput?.button(forKeyCode: GCKeyCode(rawValue: Int(usage)))?.isPressed
        }
        let generation = network.remoteKeyboardGeneration
        let revision = network.mirrorInputRevision
        let ticket = network.mirrorTicketAtRegistration
        let remote = network.isRemoteControlSession
        let context = network.remoteInputContext
        let features = network.remoteInputFeatures
        let pointerV2 = network.iPadPointerV2Supported && network.iPadPointerV2Generation == generation
        let legacy = network.permitsLegacyVirtualInput
        let available = active && !network.captureInputBlocked
        let ready = context?.state == 1 && network.remoteInputReady
        let point = available && (remote ? (features & 2 == 0 ? legacy : ready) : ticket != nil || legacy)
        let type = available && (remote ? (features & 1 == 0 ? legacy : ready) : ticket != nil || legacy)
        let direct = remote ? features & 8 != 0 && ready && context?.desktop == 1 : ticket != nil || legacy
        let zoom = remote ? features & 0x12 == 0x12 && ready : pointerV2
        trackpadAvailable = remote || pointerV2
        if remote, let context { sourceSize = CGSize(width: CGFloat(context.width),height: CGFloat(context.height)) }
        else if let geometry = network.mirrorControlState?.geometry { sourceSize = CGSize(width: CGFloat(geometry.width),height: CGFloat(geometry.height)) }
        else { sourceSize = nil }
        let identity = "\(generation):\(revision):\(remote):\(network.remoteInputRevision):\(context?.token ?? 0):\(context?.desktopEpoch ?? 0):\(features):\(pointerV2)"
        let route = IPadInputRoute(generation: generation,revision: revision,remote: remote,
            features: features,context: context,ticket: ticket,pointerV2: pointerV2)
        configure(identity: identity, point: point, type: type, direct: direct, zoom: zoom,
                  reason: !available ? "Input is temporarily unavailable" : (!remote && !pointerV2 ? "Trackpad and enhanced pointer actions require an updated PC host" : nil)) { [weak self, weak network] event in
            guard let self, let network, network.remoteKeyboardGeneration == generation else { return }
            guard let packet = route.encode(event) else {
                if (remote && features & 2 == 0) || (!remote && !pointerV2) {
                    switch event {
                    case let .pointer(kind,button,a,b): self.sendLegacyPointer(network,ticket: ticket,kind: kind,button: button,a: a,b: b)
                    case let .button(button,action,_): self.sendLegacyPointer(network,ticket: ticket,kind: 2,button: button,a: Int32(action),b: 0)
                    default: break
                    }
                }
                return
            }
            if let ticket, let kind = MirrorInputKind(rawValue: packet.type.rawValue), !remote {
                network.sendMirrorInput(ticket: ticket,kind: kind,payload: packet.payload); return
            }
            switch packet.type {
            case .remoteDirectTouch:
                if let c = RemoteDirectTouchCommand.decode(packet.payload) { network.sendRemoteDirectTouch(c,expectedGeneration: generation) }
            case .remotePointer:
                if let c = RemotePointerCommand.decode(packet.payload) { network.sendRemotePointer(c,expectedGeneration: generation) }
            case .remoteScanKey:
                if let c = RemoteScanKeyCommand.decode(packet.payload) { network.sendRemoteScanKey(c,expectedGeneration: generation) }
            case .directTouchContact:
                if legacy, let c = DirectTouchContactCommand.decode(packet.payload) { network.sendDirectTouchContact(c) }
            case .iPadPointerV2:
                if legacy, let c = IPadPointerV2Command.decode(packet.payload) { network.sendIPadPointerV2(c,expectedGeneration: generation,revision: revision) }
            case .keyboardInput:
                if legacy, let c = KeyboardInputCommand.decode(packet.payload) { network.sendKeyboardInput(c) }
            default: break
            }
        }
        engine.beginConnection(generation)
        retireQueuedInput = { [weak network] in network?.retireIPadInputScope(expectedGeneration: generation) }
    }
    private static func coordinate(_ p: CGFloat) -> UInt16 { UInt16((min(1,max(0,p))*65535).rounded()) }
    private func sendLegacyPointer(_ network: NetworkManager, ticket: MirrorInputTicket?, kind: UInt8, button: UInt8, a: Int32, b: Int32) {
        guard network.isRemoteControlSession || kind != 1 else { return }
        func send(_ command: PointerInputCommand) {
            if let ticket { network.sendMirrorInput(ticket: ticket,kind: .pointer,payload: command.encode()) }
            else { network.sendPointerInput(command) }
        }
        if kind == 0 {
            accessibleLegacyPoint = CGPoint(x: CGFloat(a)/65535,y: CGFloat(b)/65535)
        } else if kind == 1 {
            accessibleLegacyPoint.x = min(1,max(0,accessibleLegacyPoint.x+CGFloat(a)/1200))
            accessibleLegacyPoint.y = min(1,max(0,accessibleLegacyPoint.y+CGFloat(b)/800))
        }
        let x = Self.coordinate(accessibleLegacyPoint.x), y = Self.coordinate(accessibleLegacyPoint.y)
        switch kind {
        case 0, 1: send(.init(action: .move,x: x,y: y,value: 0))
        case 2:
            if button == 1 { send(.init(action: a == 0 ? .leftDown : .leftUp,x: x,y: y,value: 0)) }
            else if button == 2 && a == 1 { send(.init(action: .rightClick,x: x,y: y,value: 0)) }
        case 3:
            if a != 0 { send(.init(action: .verticalWheel,x: x,y: y,value: Int16(clamping: a))) }
            if b != 0 { send(.init(action: .horizontalWheel,x: x,y: y,value: Int16(clamping: b))) }
        default: break
        }
    }
}

/// Immutable packet seam shared by production and compatibility tests. Mirror
/// packets carry inner kinds only; the caller MUST use the captured ticket's 53 envelope.
struct IPadInputRoute {
    struct Packet { let type: WireMessageType; let payload: Data }
    let generation: UInt64, revision: UInt64
    let remote: Bool
    let features: UInt64
    let context: RemoteInputContextCommand?
    let ticket: MirrorInputTicket?
    let pointerV2: Bool
    func encode(_ event: IPadInputEvent) -> Packet? {
        func packet(_ type: WireMessageType, _ data: Data?) -> Packet? {
            data.map { Packet(type: type,payload: $0) }
        }
        switch event {
        case let .touch(phase,id,p,_):
            guard id != 0, p.x.isFinite, p.y.isFinite else { return nil }
            let x = Self.coordinate(p.x), y = Self.coordinate(p.y)
            if remote {
                guard features & 8 != 0, let context, context.state == 1, context.desktop == 1 else { return nil }
                return packet(.remoteDirectTouch,RemoteDirectTouchCommand(phase: phase,token: context.token,contactID: id,x: x,y: y).encode())
            }
            return packet(.directTouchContact,DirectTouchContactCommand(phase: phase,pressure: 255,contactID: id,x: x,y: y).encode())
        case let .button(button,action,transaction):
            if remote {
                guard features & 2 != 0, let context, context.state == 1 else { return nil }
                // Message 65 retains its token and byte layout; transaction is casting-only.
                return packet(.remotePointer,RemotePointerCommand(kind: 2,button: button,token: context.token,a: Int32(action),b: 0).encode())
            }
            guard pointerV2 else { return nil }
            return packet(.iPadPointerV2,IPadPointerV2Command(kind: 2,button: button,a: Int32(action),b: 0,transaction: transaction).encode())
        case let .pointer(kind,button,a,b):
            if remote {
                guard features & 2 != 0, let context, context.state == 1, kind != 4 || features & 0x10 != 0 else { return nil }
                return packet(.remotePointer,RemotePointerCommand(kind: kind,button: button,token: context.token,a: a,b: b).encode())
            }
            guard pointerV2 else { return nil }
            return packet(.iPadPointerV2,IPadPointerV2Command(kind: kind,button: button,a: a,b: b).encode())
        case let .key(usage,action):
            if remote && features & 1 != 0 {
                guard let context, context.state == 1 else { return nil }
                let key = usage == 0x100 ? RemotePhysicalKey(scan: 0x5b,flags: 1) : RemoteHardwareKeyboard.key(forUsage: Int(usage))
                guard let key else { return nil }
                return packet(.remoteScanKey,RemoteScanKeyCommand(action: action,flags: key.flags,scan: key.scan,token: context.token).encode())
            }
            let vk: UInt16?
            if usage == 0x100 { vk = 0x5b }
            else if let hid = UIKeyboardHIDUsage(rawValue: Int(usage)) { vk = RemoteKeyboardKeyMapper.virtualKey(for: hid) }
            else { vk = nil }
            guard let vk else { return nil }
            return packet(.keyboardInput,KeyboardInputCommand(action: action == 1 ? .keyUp : .keyDown,virtualKey: vk).encode())
        }
    }
    private static func coordinate(_ p: CGFloat) -> UInt16 { UInt16((min(1,max(0,p))*65535).rounded()) }
}
