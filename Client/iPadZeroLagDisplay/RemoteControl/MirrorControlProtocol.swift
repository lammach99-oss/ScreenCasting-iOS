import Foundation

// Candidate PMR v1 codecs. Not activated on the existing wire until both peers negotiate support.
// Frozen raw 37/38/40/41 payloads are inner records and remain byte-identical.
public enum MirrorControlError: Error { case malformed, stale, denied, sequenceExhausted }
public enum MirrorControlMode: UInt8 { case unavailable=0, viewOnly=1, awaitingPresentation=2, active=3, faulted=4, virtualDisplay=5 }
public enum MirrorInputKind: UInt8 { case pencil=1, pointer=37, keyboard=38, text=40, directTouch=41 }
public struct MirrorToken: Equatable { public let low:UInt64, high:UInt64; public var isEmpty:Bool {low==0 && high==0} }
public struct MirrorPoint: Equatable { public let x:Int32, y:Int32 }
public struct MirrorRect: Equatable { public let left:Int, top:Int, width:Int, height:Int }
public struct MirrorGeometry: Equatable {
    public let left:Int32, top:Int32, width:Int, height:Int, frameWidth:Int, frameHeight:Int
    public func content() throws -> MirrorRect {
        guard (2...32768).contains(width), (2...32768).contains(height),
              (2...8192).contains(frameWidth), (2...8192).contains(frameHeight),
              frameWidth % 2 == 0, frameHeight % 2 == 0,
              Int64(left)+Int64(width)-1 <= Int64(Int32.max),
              Int64(top)+Int64(height)-1 <= Int64(Int32.max) else { throw MirrorControlError.malformed }
        var w=frameWidth, h=frameHeight
        if Int64(frameWidth)*Int64(height) <= Int64(frameHeight)*Int64(width) { h=(height*frameWidth/width) & ~1 }
        else { w=(width*frameHeight/height) & ~1 }
        guard w>=2, h>=2 else { throw MirrorControlError.malformed }
        return MirrorRect(left:((frameWidth-w)/2) & ~1,top:((frameHeight-h)/2) & ~1,width:w,height:h)
    }
    // The already-upright desktop geometry is authoritative. Do NOT apply raw DXGI rotation again.
    public func map(x:UInt16,y:UInt16) throws -> MirrorPoint? {
        let r=try content(), px=Double(x)*Double(frameWidth-1)/65535, py=Double(y)*Double(frameHeight-1)/65535
        guard px>=Double(r.left),py>=Double(r.top),px<=Double(r.left+r.width-1),py<=Double(r.top+r.height-1) else {return nil}
        let dx=((px-Double(r.left))*Double(width-1)/Double(r.width-1)).rounded(.toNearestOrAwayFromZero)
        let dy=((py-Double(r.top))*Double(height-1)/Double(r.height-1)).rounded(.toNearestOrAwayFromZero)
        return MirrorPoint(x:left+Int32(dx),y:top+Int32(dy))
    }
}
public struct MirrorControlState: Equatable {
    public let revision:UInt64, epoch:UInt64, source:UInt64
    public let mode:MirrorControlMode, token:MirrorToken, geometry:MirrorGeometry?
    public let firstFrame:UInt32?, lastSent:UInt32?
}
public struct MirrorInputEnvelope: Equatable {
    public let epoch:UInt64, source:UInt64, token:MirrorToken, sequence:UInt64, kind:MirrorInputKind, payload:Data
}

public struct MirrorMonitorChoice: Equatable, Identifiable {
    public let id:UInt64, label:String
}
public struct MirrorMonitorCatalogue: Equatable {
    public let revision:UInt64, selected:UInt64, allowed:Bool, monitors:[MirrorMonitorChoice]
    public static func decode(_ data:Data)throws->Self {
        let b=Array(data)
        guard (20...24576).contains(b.count),b[0]==1,b[1]<=1 else {throw MirrorControlError.malformed}
        let count=Int(MirrorControlCodec.read(b,2,2)),revision=MirrorControlCodec.read(b,4,8),selected=MirrorControlCodec.read(b,12,8)
        guard count<=64,revision>0 else {throw MirrorControlError.malformed}
        var p=20,rows:[MirrorMonitorChoice]=[],ids=Set<UInt64>()
        for _ in 0..<count {
            guard p+10<=b.count else {throw MirrorControlError.malformed}
            let id=MirrorControlCodec.read(b,p,8),n=Int(MirrorControlCodec.read(b,p+8,2));p+=10
            guard id>0,ids.insert(id).inserted,(1...1024).contains(n),p+n<=b.count,
                  let label=String(bytes:b[p..<p+n],encoding:.utf8),
                  !label.unicodeScalars.contains(where:{$0.properties.generalCategory == .control}) else {throw MirrorControlError.malformed}
            rows.append(MirrorMonitorChoice(id:id,label:label));p+=n
        }
        guard p==b.count,selected==0 || ids.contains(selected) else {throw MirrorControlError.malformed}
        return Self(revision:revision,selected:selected,allowed:b[1]==1,monitors:rows)
    }
    public func switchRequest(_ id:UInt64)throws->Data {
        guard allowed,monitors.contains(where:{$0.id==id}) else {throw MirrorControlError.denied}
        var b=[UInt8](repeating:0,count:24);b[0]=1
        MirrorControlCodec.put(revision,&b,8,8);MirrorControlCodec.put(id,&b,16,8);return Data(b)
    }
}

public enum MirrorControlCodec {
    public static let helloType:UInt8=51, stateType:UInt8=52, inputType:UInt8=53, actionType:UInt8=54
    public static let advertisementFlag:UInt16=0x4000
    /// Host accepts action 7 (resend screen list) and 8 (ask to allow monitor switching).
    public static let screenPickerFlag:UInt16=0x0800
    public static let stateBytes=96, inputHeaderBytes=48, maxPayloadBytes=4099
    static func read(_ b:[UInt8],_ p:Int,_ n:Int)->UInt64 {
        var value:UInt64=0
        for i in 0..<n {value |= UInt64(b[p+i]) << UInt64(i*8)}
        return value
    }
    static func put(_ value:UInt64,_ b:inout [UInt8],_ p:Int,_ n:Int) {
        for i in 0..<n {b[p+i]=UInt8(truncatingIfNeeded:value >> UInt64(i*8))}
    }
    public static func sequenceAtOrAfter(_ value:UInt32,_ first:UInt32)->Bool { Int32(bitPattern:value &- first) >= 0 }
    public static func decodeState(_ data:Data) throws -> MirrorControlState {
        let b=Array(data)
        guard b.count==stateBytes,b[0]==1,b[2]<=1,b[3]==0,read(b,92,4)==0,
              let mode=MirrorControlMode(rawValue:b[1]) else {throw MirrorControlError.malformed}
        let revision=read(b,84,8),epoch=read(b,4,8),source=read(b,12,8)
        let token=MirrorToken(low:read(b,20,8),high:read(b,28,8)),hasAnchor=b[2]==1
        let first=UInt32(read(b,36,4)),last=UInt32(read(b,40,4))
        guard revision>0, hasAnchor || first==0 && last==0,
              mode == .active ? !token.isEmpty && hasAnchor : token.isEmpty else {throw MirrorControlError.malformed}
        var geometry:MirrorGeometry?
        if b[44..<84].contains(where:{$0 != 0}) {
            guard epoch>0,source>0 else {throw MirrorControlError.malformed}
            func i32(_ p:Int)->Int32 {Int32(bitPattern:UInt32(read(b,p,4)))}
            let g=MirrorGeometry(left:i32(44),top:i32(48),width:Int(i32(52)),height:Int(i32(56)),frameWidth:Int(i32(60)),frameHeight:Int(i32(64)))
            let expected=try g.content()
            guard expected==MirrorRect(left:Int(i32(68)),top:Int(i32(72)),width:Int(i32(76)),height:Int(i32(80))) else {throw MirrorControlError.malformed}
            geometry=g
        }
        guard mode != .active || geometry != nil,
              mode == .unavailable || mode == .faulted || mode == .virtualDisplay || geometry != nil,
              mode != .virtualDisplay || geometry == nil && source == 0 && !hasAnchor,
              !hasAnchor || sequenceAtOrAfter(last,first) else {throw MirrorControlError.malformed}
        return MirrorControlState(revision:revision,epoch:epoch,source:source,mode:mode,token:token,geometry:geometry,firstFrame:hasAnchor ? first:nil,lastSent:hasAnchor ? last:nil)
    }
    public static func encodeState(_ s:MirrorControlState) throws -> Data {
        var b=[UInt8](repeating:0,count:stateBytes)
        b[0]=1;b[1]=s.mode.rawValue;b[2]=s.firstFrame == nil ? 0:1
        put(s.epoch,&b,4,8);put(s.source,&b,12,8);put(s.token.low,&b,20,8);put(s.token.high,&b,28,8)
        put(UInt64(s.firstFrame ?? 0),&b,36,4);put(UInt64(s.lastSent ?? 0),&b,40,4);put(s.revision,&b,84,8)
        if let g=s.geometry {
            let r=try g.content()
            let numbers:[Int32]=[g.left,g.top,Int32(g.width),Int32(g.height),Int32(g.frameWidth),Int32(g.frameHeight),Int32(r.left),Int32(r.top),Int32(r.width),Int32(r.height)]
            for (i,n) in numbers.enumerated(){put(UInt64(UInt32(bitPattern:n)),&b,44+4*i,4)}
        }
        let d=Data(b);_ = try decodeState(d);return d
    }
    public static func validate(kind:MirrorInputKind,payload:Data)->Bool {
        let p=Array(payload)
        switch kind {
        case .pencil:return p.count==8 && p[0]==0x49 && p[1]==0x54 && p[2]<=3
        case .pointer:return p.count==8 && p[0]==1 && p[1]<=7 && (p[1]>4 || read(p,6,2)==0)
        case .keyboard:return p.count==4 && p[0]==1 && p[1]<=1 && read(p,2,2)>0
        case .directTouch:return p.count==16 && p[0]==1 && p[1]<=3 && p[3]==0 && read(p,4,8)>0
        case .text:
            guard (4...maxPayloadBytes).contains(p.count),p[0]==1,read(p,1,2)==UInt64(p.count-3),
                  let text=String(data:Data(p.dropFirst(3)),encoding:.utf8) else {return false}
            return !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
    }
    public static func encodeInput(_ e:MirrorInputEnvelope) throws -> Data {
        guard e.epoch>0,e.source>0,e.sequence>0,!e.token.isEmpty,validate(kind:e.kind,payload:e.payload) else {throw MirrorControlError.malformed}
        var b=[UInt8](repeating:0,count:inputHeaderBytes)
        b[0]=1;b[1]=e.kind.rawValue;put(UInt64(e.payload.count),&b,2,2);put(e.epoch,&b,4,8)
        put(e.token.low,&b,12,8);put(e.token.high,&b,20,8);put(e.sequence,&b,28,8);put(e.source,&b,36,8)
        b.append(contentsOf:e.payload);return Data(b)
    }
    public static func decodeInput(_ data:Data) throws -> MirrorInputEnvelope {
        let b=Array(data)
        guard (inputHeaderBytes...inputHeaderBytes+maxPayloadBytes).contains(b.count),b[0]==1,
              read(b,44,4)==0,Int(read(b,2,2))+inputHeaderBytes==b.count,
              let kind=MirrorInputKind(rawValue:b[1]) else {throw MirrorControlError.malformed}
        let value=MirrorInputEnvelope(epoch:read(b,4,8),source:read(b,36,8),token:MirrorToken(low:read(b,12,8),high:read(b,20,8)),sequence:read(b,28,8),kind:kind,payload:Data(b.dropFirst(inputHeaderBytes)))
        guard value.epoch>0,value.source>0,value.sequence>0,!value.token.isEmpty,validate(kind:kind,payload:value.payload) else {throw MirrorControlError.malformed}
        return value
    }
}
