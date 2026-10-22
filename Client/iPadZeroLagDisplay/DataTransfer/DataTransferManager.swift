import Foundation
import CryptoKit

final class DataTransferManager {
    // Serial receive backlog: <= 2 MiB of maximum-size chunk payloads.
    static let maxPendingPackets = 32
    enum Phase: String { case idle = "Connect to your PC first.", offering = "Waiting for approval", awaitingDecision = "Incoming files", sending = "Sending", receiving = "Receiving", verifying = "Verifying", awaitingAck = "Waiting for confirmation", completed = "Completed", rejected = "Rejected", cancelled = "Cancelled", failed = "Failed", retired = "Disconnected" }
    struct Snapshot {
        var outgoing = false
        var stage = "idle"
        var transport = "Connected to PC"
        var failure: FailureDetail?
        var retainedBytes: UInt64 = 0
        var retainedCount = 0
        var eligibleCount = 0
        var eligibleBytes: UInt64 = 0
        var storageBusy = false
        var inventoryUnavailable = false
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
            else { reason = ["stage_create":"STAGING_CREATE", "write":"WRITE_FAILED", "verify_publish":"VERIFY_OR_PUBLISH_FAILED", "send":"SEND_FAILED", "receipt_commit":"RECEIPT_COMMIT_FAILED"][stage] ?? "TRANSFER_FAILED" }
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
        var releaseStorage: (() -> Void)?
        init(id: UUID, generation: UInt64, outgoing: Bool, files: [TransferFile]) { self.id=id;self.generation=generation;self.outgoing=outgoing;self.files=files }
        func close() {
            try? handle?.close(); handle=nil; store?.retire(); store=nil
            for url in scoped { url.stopAccessingSecurityScopedResource() }; scoped=[]
            let release = releaseStorage; releaseStorage = nil; release?()
        }
        deinit { close() }
    }
    private let queue = DispatchQueue(label: "ScreenCasting.DataTransfer.IO", qos: .utility)
    private let admission = NSLock()
    private var pending = 0
    // Short admission-lock state only; no IO or callbacks while locked.
    private var autoAcceptEnabled = false
    private var autoAcceptRevision: UInt64 = 0
    func setAutoAccept(_ enabled: Bool, localGeneration: UInt64) {
        admission.lock(); defer { admission.unlock() }
        let allowed = enabled && localGeneration == generation
        if allowed != autoAcceptEnabled { autoAcceptRevision &+= 1 }
        autoAcceptEnabled = allowed
    }
    private func currentAutoAcceptToken() -> UInt64? {
        admission.lock(); defer { admission.unlock() }
        return autoAcceptEnabled ? autoAcceptRevision : nil
    }
    private func ownsAutoAcceptToken(_ token: UInt64) -> Bool {
        admission.lock(); defer { admission.unlock() }
        return autoAcceptEnabled && token == autoAcceptRevision
    }
    private var wireOwner: (UUID,UInt64)?
    func owns(_ packet: TransferPacket) -> Bool {admission.lock();defer{admission.unlock()};return wireOwner?.0 == packet.id && wireOwner?.1 == packet.generation}
    private let generation: UInt64, directory: URL, sender: Sender
    private let transport: String
    private var receivedLibrary: ReceivedFileLibrary? // IO-queue owned; shared app-storage authority.
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
    init(generation: UInt64, directory: URL, transport: String = "Connected to PC",
         receivedLibrary: ReceivedFileLibrary? = nil, onLibraryReady: ((ReceivedFileLibrary) -> Void)? = nil,
         sender: @escaping Sender) {
        self.generation=generation;self.directory=directory;self.sender=sender;self.transport=transport
        self.receivedLibrary = receivedLibrary
        queue.async {
            if self.receivedLibrary == nil { self.receivedLibrary = try? ReceivedFileLibrary(directory: directory) }
            if let library = self.receivedLibrary {
                onLibraryReady?(library)
                // Sweep abandoned stages only while holding exclusive storage ownership.
                let sweep = UUID()
                if library.beginTransfer(owner: sweep) {
                    defer { library.endTransfer(owner: sweep) }
                    let files=(try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? []
                    for file in files where file.lastPathComponent.hasPrefix(".scdt-") && file.pathExtension == "part" {try? FileManager.default.removeItem(at:file)}
                }
            }
            self.refreshRetainedFiles()
            self.publish(.idle)
        }
    }
    @discardableResult func post(_ packet: TransferPacket, completion: @escaping () -> Void = {}) -> Bool {
        admission.lock();guard pending < Self.maxPendingPackets else {
            admission.unlock()
            queue.async { [weak self] in
                guard let self else { return }
                self.snapshot.failure = FailureDetail(reason: "ADMISSION_FULL", domain: "Transfer", code: 0)
                self.event("admission_rejected"); self.fail()
            }
            return false
        };pending += 1;admission.unlock()
        // Capture before dispatch: later ON cannot adopt an already queued Offer.
        let policyToken = packet.kind == .offer ? currentAutoAcceptToken() : nil
        queue.async { [weak self] in
            guard let self else {return}
            defer {self.admission.lock();self.pending -= 1;self.admission.unlock();completion()}
            do {try self.receive(packet, autoAcceptToken: policyToken)} catch {self.fail(error: error)}
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
                guard self.acquireStorage(active) else { throw CocoaError(.fileLocking) }
                active.sources=urls;active.scoped=scoped;self.owner=active;self.admission.lock();self.wireOwner=(active.id,active.generation);self.admission.unlock();active.waiting = .response
                self.publish(.offering);self.send(active,.offer) { _ in }
            } catch {for url in scoped {url.stopAccessingSecurityScopedResource()};self.snapshot.failure = FailureDetail.classify(error, stage: self.diagnosticStage);self.publish(.failed)}
        }
    }
    private func acquireStorage(_ active: Owner) -> Bool {
        guard let library = receivedLibrary else { return false }
        // A fresh local token fences equal peer UUIDs across generations and managers.
        let token = UUID()
        guard library.beginTransfer(owner: token) else { return false }
        active.releaseStorage = { library.endTransfer(owner: token) }
        return true
    }
    static func validateRetainedQuota(count: Int, bytes: UInt64, incomingCount: Int,
                                      incomingBytes: UInt64, availableCapacity: Int64?) throws {
        let limit: UInt64 = 8 * 1024 * 1024 * 1024
        guard count >= 0, count <= 256, incomingCount > 0, incomingCount <= 256 - count,
              bytes <= limit, incomingBytes <= limit - bytes else { throw CocoaError(.fileWriteOutOfSpace) }
        if let free = availableCapacity, free < 0 || UInt64(free) < incomingBytes + 64 * 1024 * 1024 {
            throw CocoaError(.fileWriteOutOfSpace)
        }
    }
    func decide(_ accepted: Bool) {
        queue.async { [weak self] in self?.decideOnQueue(accepted, expectedTransferID: nil) }
    }
    private func decideOnQueue(_ accepted: Bool, expectedTransferID: UUID?, policyToken: UInt64? = nil) {
        guard !retired, let active=owner, !active.outgoing, !active.accepted,
              expectedTransferID == nil || expectedTransferID == active.id else { return }
        if let policyToken, !ownsAutoAcceptToken(policyToken) { return }
        do {
            if accepted {
                event("admission")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard let receivedLibrary, active.releaseStorage != nil else { throw CocoaError(.fileReadUnknown) }
                let values=try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                let total=try TransferProtocol.validate(active.files)
                let inventory=try receivedLibrary.snapshot()
                try Self.validateRetainedQuota(count: inventory.retainedCount, bytes: inventory.retainedBytes,
                                              incomingCount: active.files.count, incomingBytes: total,
                                              availableCapacity: values.volumeAvailableCapacityForImportantUsage)
                if let policyToken, !ownsAutoAcceptToken(policyToken) { return }
                event("stage_create")
                active.store=try TransferStore(directory:directory,metadata:active.files[0],id:active.id)
                if let policyToken, !ownsAutoAcceptToken(policyToken) {
                    active.store?.retire(); active.store = nil; return
                }
                active.accepted=true;publish(.receiving)
                var response=packet(active,.response);response.accepted=true;write(active,response) { _ in }
            } else {
                var response=packet(active,.response);response.reason = .userRejected
                write(active,response) { [weak self] ok in if ok {self?.finish(.rejected)} }
            }
        } catch {fail(error: error)}
    }
    func cancel(failed: Bool = false) {queue.async { [weak self] in self?.fail(phase: failed ? .failed : .cancelled) } }
    func retire() {setAutoAccept(false, localGeneration: generation);queue.async { [weak self] in guard let self else{return};self.retired=true;self.finish(.retired)} }
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
    private func finish(_ phase: Phase) {
        admission.lock();wireOwner=nil;admission.unlock()
        if let active=owner {
            retiredIDs.append(active.id);if retiredIDs.count>256 {retiredIDs.removeFirst()}
            active.close() // Stage/source handles close before the one-use local lease releases.
        }
        refreshRetainedFiles();publish(phase);owner=nil
    }
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
    private func receive(_ p: TransferPacket, autoAcceptToken: UInt64?) throws {
        guard !retired else {return}
        if p.kind == .offer {
            guard !retiredIDs.contains(p.id), peerGeneration == nil || peerGeneration == p.generation else {return}
            peerGeneration = p.generation
            guard owner == nil else {var busy=TransferPacket(kind:.response,generation:p.generation,id:p.id);busy.reason = .busy;sender(busy){_ in};return}
            _ = try TransferProtocol.validate(p.files)
            let active=Owner(id:p.id,generation:p.generation,outgoing:false,files:p.files)
            // Invalid storage preserves the existing F03 manual admission failure stage.
            // An available authority must fence Clear/export before exposing pending consent.
            if receivedLibrary != nil && !acquireStorage(active) {
                var busy=TransferPacket(kind:.response,generation:p.generation,id:p.id)
                busy.reason = .busy;sender(busy){_ in};return
            }
            resetDiagnostics(outgoing:false);owner=active
            admission.lock();wireOwner=(p.id,p.generation);admission.unlock();event("offer");publish(.awaitingDecision)
            if let token = autoAcceptToken, ownsAutoAcceptToken(token) {
                decideOnQueue(true, expectedTransferID: p.id, policyToken: token)
            }
            return
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
            event("verify_publish");publish(.verifying)
            let final=try store.publish(length:p.offset,digest:p.bytes);active.store=nil
            event("receipt_commit")
            do {
                guard let receivedLibrary else { throw CocoaError(.fileReadUnknown) }
                try receivedLibrary.recordPublished(final,length:p.offset,digest:p.bytes)
            } catch {
                // Published bytes survive as quota-counted legacy; no successful FileAck.
                refreshRetainedFiles();throw error
            }
            active.received.append(final);active.bytes+=p.offset;active.published+=1;active.index+=1
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
        // Event-driven IO-worker work, never a per-progress hash or network/main callback.
        guard let receivedLibrary, let inventory=try? receivedLibrary.snapshot() else {
            snapshot.inventoryUnavailable=true
            return // Preserve last known values; unavailable is not an empty library.
        }
        verifiedFiles=inventory.files // Retained projection; deletion authority stays in receipts.
        snapshot.received=inventory.files;snapshot.retainedCount=inventory.retainedCount
        snapshot.retainedBytes=inventory.retainedBytes;snapshot.eligibleCount=inventory.eligibleCount
        snapshot.eligibleBytes=inventory.eligibleBytes;snapshot.storageBusy=inventory.busy
        snapshot.inventoryUnavailable=false
    }
}
