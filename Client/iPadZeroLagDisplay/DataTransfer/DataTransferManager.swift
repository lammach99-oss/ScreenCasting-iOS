import Foundation
import CryptoKit

final class DataTransferManager {
    enum Phase: String { case idle = "Connect to your PC first.", offering = "Waiting for approval", awaitingDecision = "Incoming files", sending = "Sending", receiving = "Receiving", verifying = "Verifying", awaitingAck = "Waiting for confirmation", completed = "Completed", rejected = "Rejected", cancelled = "Cancelled", failed = "Failed", retired = "Disconnected" }
    struct Snapshot {
        var phase: Phase = .idle
        var count = 0, index = 0, published = 0
        var bytes: UInt64 = 0, total: UInt64 = 0
        var name = ""
        var received: [URL] = []
    }
    typealias Sender = (TransferPacket, @escaping (Bool) -> Void) -> Void
    private final class Owner {
        let id: UUID, generation: UInt64, outgoing: Bool, files: [TransferFile]
        var sources: [URL] = [], scoped: [URL] = []
        var accepted = false, index = 0, published = 0
        var bytes: UInt64 = 0, offset: UInt64 = 0, chunk: UInt64 = 0
        var handle: FileHandle?, store: TransferStore?
        var hash = SHA256()
        var initialDate: Date?
        var lastProgress: TimeInterval = 0
        var waiting: TransferKind?
        var received: [URL] = []
        init(id: UUID, generation: UInt64, outgoing: Bool, files: [TransferFile]) { self.id=id;self.generation=generation;self.outgoing=outgoing;self.files=files }
        func close() { try? handle?.close();handle=nil;store?.retire();store=nil;for url in scoped {url.stopAccessingSecurityScopedResource()};scoped=[] }
        deinit { close() }
    }
    private let queue = DispatchQueue(label: "ScreenCasting.DataTransfer.IO", qos: .utility)
    private let admission = NSLock()
    private var pending = 0
    private let generation: UInt64, directory: URL, sender: Sender
    private var owner: Owner?, retired = false
    private var snapshot = Snapshot()
    private var retiredIDs: [UUID] = []
    private var peerGeneration: UInt64?
    var changed: ((Snapshot) -> Void)?
    init(generation: UInt64, directory: URL, sender: @escaping Sender) {
        self.generation=generation;self.directory=directory;self.sender=sender
        queue.async {
            let files=(try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix(".scdt-") && file.pathExtension == "part" {try? FileManager.default.removeItem(at:file)}
        }
    }
    @discardableResult func post(_ packet: TransferPacket) -> Bool {
        admission.lock();guard pending < 2 else {admission.unlock();cancel(failed: true);return false};pending += 1;admission.unlock()
        queue.async { [weak self] in
            guard let self else {return}
            defer {self.admission.lock();self.pending -= 1;self.admission.unlock()}
            do {try self.receive(packet)} catch {self.fail()}
        }
        return true
    }
    func sendFiles(_ urls: [URL]) {
        queue.async { [weak self] in
            guard let self, !self.retired, self.owner == nil else {return}
            var scoped: [URL] = []
            do {
                let files = try urls.map { url -> TransferFile in
                    if url.startAccessingSecurityScopedResource() {scoped.append(url)}
                    let values = try url.resourceValues(forKeys: [.fileSizeKey,.isRegularFileKey])
                    guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {throw TransferProtocol.Failure.invalid}
                    return TransferFile(name: url.lastPathComponent,length: UInt64(size))
                }
                _ = try TransferProtocol.validate(files)
                let active=Owner(id: UUID(),generation: self.generation,outgoing: true,files: files)
                active.sources=urls;active.scoped=scoped;self.owner=active;active.waiting = .response
                self.publish(.offering);self.send(active,.offer) { _ in }
            } catch {for url in scoped {url.stopAccessingSecurityScopedResource()};self.publish(.failed)}
        }
    }
    func decide(_ accepted: Bool) {
        queue.async { [weak self] in
            guard let self, let active=self.owner, !active.outgoing, !active.accepted else {return}
            do {
                if accepted {
                    try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                    let values=try self.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    let total=try TransferProtocol.validate(active.files)
                    let retained=(try? FileManager.default.contentsOfDirectory(at:self.directory,includingPropertiesForKeys:[.fileSizeKey])) ?? []
                    let retainedBytes=retained.reduce(UInt64(0)){sum,url in sum+UInt64(max(0,(try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0))}
                    guard retained.count+active.files.count<=256,retainedBytes<=8*1024*1024*1024,total<=8*1024*1024*1024-retainedBytes else {throw CocoaError(.fileWriteOutOfSpace)}
                    if let free=values.volumeAvailableCapacityForImportantUsage, free < 0 || UInt64(free)<total+64*1024*1024 {throw CocoaError(.fileWriteOutOfSpace)}
                    active.store=try TransferStore(directory:self.directory,metadata:active.files[0],id:active.id)
                    active.accepted=true;self.publish(.receiving)
                    var response=self.packet(active,.response);response.accepted=true;self.write(active,response) { _ in }
                } else {
                    var response=self.packet(active,.response);response.reason = .userRejected
                    self.write(active,response) { [weak self] ok in if ok {self?.finish(.rejected)} }
                }
            } catch {self.fail()}
        }
    }
    func cancel(failed: Bool = false) {queue.async { [weak self] in self?.fail(phase: failed ? .failed : .cancelled) } }
    func retire() {queue.async { [weak self] in guard let self else{return};self.retired=true;self.finish(.retired)} }
    private func packet(_ active: Owner,_ kind: TransferKind) -> TransferPacket {TransferPacket(kind:kind,generation:active.generation,id:active.id)}
    private func current(_ active: Owner) -> Bool {!retired && owner === active}
    private func publish(_ phase: Phase) {
        snapshot.phase=phase
        if let active=owner {snapshot.count=active.files.count;snapshot.index=active.index;snapshot.published=active.published;snapshot.bytes=active.bytes;snapshot.total=active.files.reduce(0){$0+$1.length};snapshot.name=active.index<active.files.count ? active.files[active.index].name : "";snapshot.received=active.received}
        let value=snapshot;changed?(value)
    }
    private func progress(_ active: Owner, bytes: UInt64) {
        let now=ProcessInfo.processInfo.systemUptime
        guard now-active.lastProgress>=0.1 else{return};active.lastProgress=now
        snapshot.bytes=bytes;snapshot.phase=active.outgoing ? .sending : .receiving;changed?(snapshot)
    }
    private func finish(_ phase: Phase) {publish(phase);if let active=owner {retiredIDs.append(active.id);if retiredIDs.count>256 {retiredIDs.removeFirst()}};owner?.close();owner=nil}
    private func fail(phase: Phase = .failed) {
        guard let active=owner else {return}
        var cancel=packet(active,.cancel);cancel.reason = .cancelled;sender(cancel){_ in};finish(phase)
    }
    private func write(_ active: Owner,_ packet: TransferPacket,_ done: @escaping (Bool)->Void) {
        guard current(active) else {return}
        sender(packet) { [weak self,weak active] ok in
            guard let self,let active else{return}
            self.queue.async {guard self.current(active) else{return};if !ok {self.fail();return};done(ok)}
        }
    }
    private func send(_ active: Owner,_ kind: TransferKind,_ done: @escaping (Bool)->Void) {
        var p=packet(active,kind);if kind == .offer {p.files=active.files};write(active,p,done)
    }
    private func receive(_ p: TransferPacket) throws {
        guard !retired else {return}
        if p.kind == .offer {
            guard !retiredIDs.contains(p.id), peerGeneration == nil || peerGeneration == p.generation else {return}
            peerGeneration = p.generation
            guard owner == nil else {var busy=TransferPacket(kind:.response,generation:p.generation,id:p.id);busy.reason = .busy;sender(busy){_ in};return}
            _ = try TransferProtocol.validate(p.files);owner=Owner(id:p.id,generation:p.generation,outgoing:false,files:p.files);snapshot.received=[];publish(.awaitingDecision);return
        }
        guard let active=owner, active.id==p.id, active.generation==p.generation else {return}
        if p.kind == .cancel {finish(.cancelled);return}
        if active.outgoing {
            guard active.waiting == p.kind else {throw TransferProtocol.Failure.invalid}
            if p.kind == .response {guard p.accepted else {finish(.rejected);return};active.waiting=nil;try openNext(active);return}
            if p.kind == .fileAck {
                guard p.reason == .ok, p.fileIndex==active.index else {throw TransferProtocol.Failure.invalid}
                active.bytes+=active.files[active.index].length;active.published+=1;active.index+=1;active.waiting=nil
                if active.index==active.files.count {active.waiting = .ack;publish(.awaitingAck);send(active,.end){_ in}} else {try openNext(active)}
                return
            }
            guard p.kind == .ack,p.reason == .ok else {throw TransferProtocol.Failure.invalid};finish(.completed);return
        }
        guard active.accepted else {throw TransferProtocol.Failure.invalid}
        switch p.kind {
        case .chunk:
            guard p.fileIndex==active.index,let store=active.store else {throw TransferProtocol.Failure.invalid}
            try store.append(chunk:p.chunkIndex,offset:p.offset,bytes:p.bytes)
            progress(active,bytes:active.bytes+store.written)
        case .fileEnd:
            guard p.fileIndex==active.index,let store=active.store else {throw TransferProtocol.Failure.invalid}
            publish(.verifying);let final=try store.publish(length:p.offset,digest:p.bytes);active.store=nil;active.received.append(final);active.bytes+=p.offset;active.published+=1;active.index+=1
            if active.index<active.files.count {active.store=try TransferStore(directory:directory,metadata:active.files[active.index],id:active.id)}
            var ack=packet(active,.fileAck);ack.fileIndex=p.fileIndex;publish(.receiving);write(active,ack){_ in}
        case .end:
            guard active.index==active.files.count,active.store==nil else {throw TransferProtocol.Failure.invalid}
            send(active,.ack){[weak self] ok in if ok {self?.finish(.completed)}}
        default:throw TransferProtocol.Failure.invalid
        }
    }
    private func openNext(_ active: Owner) throws {
        guard current(active) else {return}
        let url=active.sources[active.index],values=try url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        guard let size=values.fileSize,UInt64(size)==active.files[active.index].length else {throw TransferProtocol.Failure.invalid}
        active.initialDate=values.contentModificationDate;active.handle=try FileHandle(forReadingFrom:url);active.offset=0;active.chunk=0;active.hash=SHA256();publish(.sending);pump(active)
    }
    private func pump(_ active: Owner) {
        guard current(active) else {return}
        do {
            let length=active.files[active.index].length
            if active.offset<length {
                guard let bytes=try active.handle?.read(upToCount:Int(min(UInt64(TransferProtocol.defaultChunkBytes),length-active.offset))),!bytes.isEmpty else {throw TransferProtocol.Failure.invalid}
                active.hash.update(data:bytes);var p=packet(active,.chunk);p.fileIndex=UInt16(active.index);p.offset=active.offset;p.chunkIndex=active.chunk;p.bytes=bytes
                write(active,p){ [weak self,weak active] _ in guard let self,let active else{return};active.offset+=UInt64(bytes.count);active.chunk+=1;self.progress(active,bytes:active.bytes+active.offset);self.pump(active) }
            } else {
                let values=try active.sources[active.index].resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
                guard values.fileSize==Int(length),values.contentModificationDate==active.initialDate else {throw TransferProtocol.Failure.invalid}
                try active.handle?.close();active.handle=nil;var end=packet(active,.fileEnd);end.fileIndex=UInt16(active.index);end.offset=length;end.bytes=Data(active.hash.finalize());active.waiting = .fileAck;publish(.awaitingAck);write(active,end){_ in}
            }
        } catch {fail()}
    }
}
