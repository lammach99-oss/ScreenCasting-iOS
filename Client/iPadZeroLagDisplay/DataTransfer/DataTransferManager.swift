import Foundation
import CryptoKit

final class DataTransferManager {
    enum Phase: String { case idle = "Connect to your PC first.", offering = "Waiting for approval", awaitingDecision = "Incoming files", sending = "Sending", receiving = "Receiving", verifying = "Verifying", awaitingAck = "Waiting for confirmation", completed = "Completed", rejected = "Rejected", cancelled = "Cancelled", failed = "Failed", retired = "Disconnected" }
    struct Snapshot {
        var outgoing = false
        var stage = "idle"
        var transport = "Connected to PC"
        var failure: FailureDetail?
        var retainedBytes: UInt64 = 0
        var retainedCount = 0
        var phase: Phase = .idle
        var count = 0, index = 0, published = 0
        var bytes: UInt64 = 0, total: UInt64 = 0
        var name = ""
        var received: [URL] = []
    }
    struct FailureDetail: Equatable {
        let reason: String
        let domain: String
        let code: Int
        static func classify(_ error: Error, stage: String) -> FailureDetail {
            let native = error as NSError
            let domain = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSURLErrorDomain].contains(native.domain) ? native.domain : "Transfer"
            let reason: String
            if native.domain == NSCocoaErrorDomain && native.code == CocoaError.fileWriteOutOfSpace.rawValue { reason = "STORAGE_FULL" }
            else if error is TransferProtocol.Failure { reason = "INVALID_TRANSFER" }
            else { reason = ["stage_create":"STAGING_CREATE", "write":"WRITE_FAILED", "verify_publish":"VERIFY_OR_PUBLISH_FAILED", "send":"SEND_FAILED"][stage] ?? "TRANSFER_FAILED" }
            return FailureDetail(reason: reason, domain: domain, code: native.code)
        }
    }
    typealias Sender = (TransferPacket, @escaping (Bool) -> Void) -> Void
    private final class Owner {
        let id: UUID, generation: UInt64, outgoing: Bool, files: [TransferFile]
        var sources: [URL] = [], scoped: [URL] = []
        var accepted = false, index = 0, published = 0
        var bytes: UInt64 = 0, offset: UInt64 = 0, chunk: UInt64 = 0
        var receivedChunks: UInt64 = 0
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
    private var wireOwner: (UUID,UInt64)?
    func owns(_ packet: TransferPacket) -> Bool {admission.lock();defer{admission.unlock()};return wireOwner?.0 == packet.id && wireOwner?.1 == packet.generation}
    private let generation: UInt64, directory: URL, sender: Sender
    private let transport: String
    private var owner: Owner?, retired = false
    private var snapshot = Snapshot()
    private var retiredIDs: [UUID] = []
    private var peerGeneration: UInt64?
    var changed: ((Snapshot) -> Void)?
    var diagnostic: ((String) -> Void)?
    private var diagnosticCount = 0
    private var droppedDiagnostics = 0
    private var diagnosticStage = "idle"
    private var verifiedFiles: [URL] = []
    init(generation: UInt64, directory: URL, transport: String = "Connected to PC", sender: @escaping Sender) {
        self.generation=generation;self.directory=directory;self.sender=sender;self.transport=transport
        queue.async {
            let files=(try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix(".scdt-") && file.pathExtension == "part" {try? FileManager.default.removeItem(at:file)}
            self.refreshRetainedFiles()
            self.publish(.idle)
        }
    }
    @discardableResult func post(_ packet: TransferPacket, completion: @escaping () -> Void = {}) -> Bool {
        admission.lock();guard pending < 2 else {
            admission.unlock()
            queue.async { [weak self] in
                guard let self else { return }
                self.snapshot.failure = FailureDetail(reason: "ADMISSION_FULL", domain: "Transfer", code: 0)
                self.event("admission_rejected"); self.fail()
            }
            return false
        };pending += 1;admission.unlock()
        queue.async { [weak self] in
            guard let self else {return}
            defer {self.admission.lock();self.pending -= 1;self.admission.unlock();completion()}
            do {try self.receive(packet)} catch {self.fail(error: error)}
        }
        return true
    }
    func sendFiles(_ urls: [URL]) {
        queue.async { [weak self] in
            guard let self, !self.retired, self.owner == nil else {return}
            var scoped: [URL] = []
            self.resetDiagnostics(outgoing: true)
            self.diagnosticStage = "source_open"
            do {
                let files = try urls.map { url -> TransferFile in
                    if url.startAccessingSecurityScopedResource() {scoped.append(url)}
                    let values = try url.resourceValues(forKeys: [.fileSizeKey,.isRegularFileKey])
                    guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {throw TransferProtocol.Failure.invalid}
                    return TransferFile(name: url.lastPathComponent,length: UInt64(size))
                }
                _ = try TransferProtocol.validate(files)
                let active=Owner(id: UUID(),generation: self.generation,outgoing: true,files: files)
                active.sources=urls;active.scoped=scoped;self.owner=active;self.admission.lock();self.wireOwner=(active.id,active.generation);self.admission.unlock();active.waiting = .response
                self.publish(.offering);self.send(active,.offer) { _ in }
            } catch {for url in scoped {url.stopAccessingSecurityScopedResource()};self.snapshot.failure = FailureDetail.classify(error, stage: self.diagnosticStage);self.publish(.failed)}
        }
    }
    func decide(_ accepted: Bool) {
        queue.async { [weak self] in
            guard let self, let active=self.owner, !active.outgoing, !active.accepted else {return}
            do {
                if accepted {
                    self.event("admission")
                    try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                    let values=try self.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    let total=try TransferProtocol.validate(active.files)
                    let retained=(try? FileManager.default.contentsOfDirectory(at:self.directory,includingPropertiesForKeys:[.fileSizeKey])) ?? []
                    let retainedBytes=retained.reduce(UInt64(0)){sum,url in sum+UInt64(max(0,(try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0))}
                    guard retained.count+active.files.count<=256,retainedBytes<=8*1024*1024*1024,total<=8*1024*1024*1024-retainedBytes else {throw CocoaError(.fileWriteOutOfSpace)}
                    if let free=values.volumeAvailableCapacityForImportantUsage, free < 0 || UInt64(free)<total+64*1024*1024 {throw CocoaError(.fileWriteOutOfSpace)}
                    self.event("stage_create")
                    active.store=try TransferStore(directory:self.directory,metadata:active.files[0],id:active.id)
                    active.accepted=true;self.publish(.receiving)
                    var response=self.packet(active,.response);response.accepted=true;self.write(active,response) { _ in }
                } else {
                    var response=self.packet(active,.response);response.reason = .userRejected
                    self.write(active,response) { [weak self] ok in if ok {self?.finish(.rejected)} }
                }
            } catch {self.fail(error: error)}
        }
    }
    func cancel(failed: Bool = false) {queue.async { [weak self] in self?.fail(phase: failed ? .failed : .cancelled) } }
    func retire() {queue.async { [weak self] in guard let self else{return};self.retired=true;self.finish(.retired)} }
    private func packet(_ active: Owner,_ kind: TransferKind) -> TransferPacket {TransferPacket(kind:kind,generation:active.generation,id:active.id)}
    private func current(_ active: Owner) -> Bool {!retired && owner === active}
    private func publish(_ phase: Phase) {
        snapshot.phase=phase
        snapshot.transport=transport
        snapshot.stage = diagnosticStage
        if let active=owner {snapshot.outgoing=active.outgoing;snapshot.count=active.files.count;snapshot.index=active.index;snapshot.published=active.published;snapshot.bytes=active.bytes;snapshot.total=active.files.reduce(0){$0+$1.length};snapshot.name=active.index<active.files.count ? active.files[active.index].name : snapshot.name}
        snapshot.received = verifiedFiles
        event(phase.rawValue.replacingOccurrences(of: " ", with: "_"), updateStage: false)
        let value=snapshot;changed?(value)
    }
    private func progress(_ active: Owner, bytes: UInt64) {
        let now=ProcessInfo.processInfo.systemUptime
        guard now-active.lastProgress>=0.1 else{return};active.lastProgress=now
        snapshot.bytes=bytes;snapshot.phase=active.outgoing ? .sending : .receiving;changed?(snapshot)
    }
    private func finish(_ phase: Phase) {admission.lock();wireOwner=nil;admission.unlock();publish(phase);if let active=owner {retiredIDs.append(active.id);if retiredIDs.count>256 {retiredIDs.removeFirst()}};owner?.close();owner=nil}
    private func fail(phase: Phase = .failed, error: Error? = nil) {
        guard let active=owner else {return}
        if phase == .failed {snapshot.failure = error.map {FailureDetail.classify($0, stage: diagnosticStage)} ?? snapshot.failure ?? FailureDetail(reason:"TRANSFER_FAILED",domain:"Transfer",code:0)}
        var cancel=packet(active,.cancel);cancel.reason = .cancelled;sender(cancel){_ in};finish(phase)
    }
    private func write(_ active: Owner,_ packet: TransferPacket,_ done: @escaping (Bool)->Void) {
        guard current(active) else {return}
        sender(packet) { [weak self,weak active] ok in
            guard let self,let active else{return}
            self.queue.async {guard self.current(active) else{return};if !ok {self.snapshot.failure=FailureDetail(reason:"SEND_FAILED",domain:"Transfer",code:0);self.event("send_failed");self.fail();return};if packet.kind != .chunk {self.event("send_\(packet.kind)")};done(ok)}
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
            _ = try TransferProtocol.validate(p.files);resetDiagnostics(outgoing:false);owner=Owner(id:p.id,generation:p.generation,outgoing:false,files:p.files);admission.lock();wireOwner=(p.id,p.generation);admission.unlock();event("offer");publish(.awaitingDecision);return
        }
        guard let active=owner, active.id==p.id, active.generation==p.generation else {return}
        if p.kind != .chunk {event("receive_\(p.kind)")}
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
            diagnosticStage = "write"
            guard p.fileIndex==active.index,let store=active.store else {throw TransferProtocol.Failure.invalid}
            try store.append(chunk:p.chunkIndex,offset:p.offset,bytes:p.bytes)
            active.receivedChunks += 1
            if p.chunkIndex == 0 {event("first_chunk", updateStage:false)}
            progress(active,bytes:active.bytes+store.written)
        case .fileEnd:
            guard p.fileIndex==active.index,let store=active.store else {throw TransferProtocol.Failure.invalid}
            event("verify_publish");publish(.verifying);let final=try store.publish(length:p.offset,digest:p.bytes);active.store=nil;active.received.append(final);verifiedFiles.append(final);active.bytes+=p.offset;active.published+=1;active.index+=1
            refreshRetainedFiles();event("published")
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
        } catch {fail(error:error)}
    }
    private func resetDiagnostics(outgoing: Bool) {
        diagnosticCount=0;droppedDiagnostics=0;diagnosticStage="offer"
        snapshot.failure=nil;snapshot.outgoing=outgoing
    }
    private func event(_ stage: String, updateStage: Bool = true) {
        if updateStage {diagnosticStage=stage}
        let terminal = [.completed,.failed,.cancelled,.rejected,.retired].contains(snapshot.phase) && diagnosticCount < 136
        guard diagnosticCount < 128 || terminal else {droppedDiagnostics += 1;return}
        diagnosticCount += 1
        let active=owner
        let offset = active?.outgoing == true ? (active?.offset ?? 0) : (active?.store?.written ?? 0)
        let expected = active?.files.reduce(UInt64(0)) {$0+$1.length} ?? snapshot.total
        diagnostic?("component=DataTransfer direction=\(snapshot.outgoing ? "IPAD_TO_PC" : "PC_TO_IPAD") local_generation=\(generation) peer_generation=\(active?.generation ?? 0) transfer_id=\(active?.id.uuidString ?? "none") stage=\(stage) file_index=\(active?.index ?? 0) file_count=\(active?.files.count ?? 0) bytes=\((active?.bytes ?? 0)+offset) expected=\(expected) file_offset=\(offset) chunk_count=\(active?.outgoing == true ? (active?.chunk ?? 0) : (active?.receivedChunks ?? 0)) reason=\(snapshot.failure?.reason ?? "none") error_domain=\(snapshot.failure?.domain ?? "none") error_code=\(snapshot.failure?.code ?? 0) dropped=\(droppedDiagnostics)")
    }
    private func refreshRetainedFiles() {
        let files=(try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isRegularFileKey,.fileSizeKey])) ?? []
        verifiedFiles=files.filter {
            guard !($0.lastPathComponent.hasPrefix(".scdt-") && $0.pathExtension == "part") else {return false}
            guard let values=try? $0.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]) else {return false}
            return values.isRegularFile == true && values.isSymbolicLink != true
        }.sorted {$0.lastPathComponent < $1.lastPathComponent}
        snapshot.received=verifiedFiles;snapshot.retainedCount=verifiedFiles.count
        snapshot.retainedBytes=verifiedFiles.reduce(0) {$0+UInt64(max(0,(try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0))}
    }
}
