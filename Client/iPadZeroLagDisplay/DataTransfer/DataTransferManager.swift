import Foundation
import CryptoKit

final class DataTransferManager {
    // Serial receive backlog: <= 2 MiB of maximum-size chunk payloads.
    static let maxPendingPackets = 32
    enum Phase: String { case idle = "Connect to your PC first.", offering = "Waiting for approval", awaitingDecision = "Incoming files", sending = "Sending", receiving = "Receiving", verifying = "Verifying", awaitingAck = "Waiting for confirmation", completed = "Completed", rejected = "Rejected", cancelled = "Cancelled", failed = "Failed", retired = "Disconnected" }
    struct Consent: Equatable {
        let sessionID: UUID
        let transferID: UUID
        var slotAction: RemoteFileSlotScope.Action? = nil
    }
    private let sessionID = UUID()
    struct Snapshot {
        var slotAction: RemoteFileSlotScope.Action?
        var consent: Consent?
        var outgoing = false
        var stage = "idle"
        var transport = "Connected to PC"
        var failure: FailureDetail?
        var rejectionReason: TransferReason?
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
        var retryCount = 0
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
            else if error is TransferProtocol.Failure || error is TransferStore.VerificationFailure { reason = "INVALID_TRANSFER" }
            else { reason = ["stage_create":"STAGING_CREATE", "write":"WRITE_FAILED", "verify_publish":"VERIFY_OR_PUBLISH_FAILED", "send":"SEND_FAILED", "receipt_commit":"RECEIPT_COMMIT_FAILED"][stage] ?? "TRANSFER_FAILED" }
            return FailureDetail(reason: reason, domain: domain, code: native.code)
        }
    }
    typealias Sender = (TransferPacket, @escaping (Bool) -> Void) -> Void
    struct FileWindow: Equatable {
        let offer: UUID
        let file: UInt16
        let consumed: UInt64
        let limit: UInt64
        let chunks: UInt64
    }
    struct DownloadCredit {
        let generation: UInt64
        let window: FileWindow
        var offset: UInt64
        var chunk: UInt64

        mutating func admit(_ packet: TransferPacket) -> Bool {
            guard packet.id == window.offer, packet.generation == generation, packet.fileIndex == window.file,
                  packet.chunkIndex == chunk, packet.offset == offset, offset <= window.limit,
                  chunk < window.chunks, !packet.bytes.isEmpty,
                  packet.bytes.count <= RemoteFileProtocol.maxChunkBytes,
                  UInt64(packet.bytes.count) <= window.limit - offset else { return false }
            offset += UInt64(packet.bytes.count)
            chunk += 1
            return true
        }
    }
    private final class Owner {
        var focus = FileFocus(slot: nil, epoch: 0)
        let id: UUID, generation: UInt64, outgoing: Bool, files: [TransferFile]
        var sources: [URL] = [], scoped: [URL] = []
        var accepted = false, index = 0, published = 0
        var bytes: UInt64 = 0, offset: UInt64 = 0, chunk: UInt64 = 0
        var receivedChunks: UInt64 = 0
        var observedBytes: UInt64 = 0
        var handle: FileHandle?, store: TransferStore?
        var hash = SHA256()
        var initialDate: Date?
        var lastProgress: TimeInterval = 0
        var waiting: TransferKind?
        var credit: FileWindow?
        var sentEnds: [UInt64] = []
        var consumedChunks: UInt64 = 0
        var chunkInFlight = false
        var windowInFlight = false
        var nextWindow: (consumed: UInt64, chunks: UInt64)?
        var progressAt = ProcessInfo.processInfo.systemUptime
        var pausedAt: TimeInterval?
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
    private var remoteRetired = false
    private var remoteUploadQueued = false
    // One manager per DS5 grant. Both host versions advertise the same grant limits.
    private var remotePeerUsesWideWindows = false
    private var downloadCredit: DownloadCredit?
    private var proposedDownloadCredit: DownloadCredit?
    private var deadlineCheckQueued = false
    private let remoteWindowSender: ((FileWindow, @escaping (Bool) -> Void) -> Void)?
    private var remoteIsLive: Bool {
        admission.lock(); defer { admission.unlock() }
        return !remoteRetired
    }
    // Short admission-lock state only; no IO or callbacks while locked.
    // Single-session owners start eligible. A slot adapter closes this gate on attachment.
    private struct FileFocus: Equatable {
        let slot: SlotOrdinal?
        let epoch: UInt64

        func action(id: UUID) -> RemoteFileSlotScope.Action? {
            slot.map { RemoteFileSlotScope.Action(slot: $0, epoch: epoch, transferID: id) }
        }
    }

    private var slotFocus: FileFocus? = FileFocus(slot: nil, epoch: 0)

    func setSlotFileFocus(slot: SlotOrdinal, epoch: UInt64?) {
        admission.lock(); defer { admission.unlock() }
        slotFocus = epoch.map { FileFocus(slot: slot, epoch: $0) }
        autoAcceptRevision &+= 1
    }

    private var fileFocusTicket: FileFocus? {
        admission.lock(); defer { admission.unlock() }
        return slotFocus
    }

    var activeTransferID: UUID? {
        admission.lock(); defer { admission.unlock() }
        return wireOwner?.0
    }

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
        return slotFocus != nil && autoAcceptEnabled && token == autoAcceptRevision
    }
    private var wireOwner: (UUID,UInt64)?
    var hasActiveTransfer: Bool {
        admission.lock(); defer { admission.unlock() }
        return wireOwner != nil || pending > 0 || remoteUploadQueued
    }
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
    private var retrySources: [URL] = []
    init(generation: UInt64, directory: URL, transport: String = "Connected to PC",
         receivedLibrary: ReceivedFileLibrary? = nil, onLibraryReady: ((ReceivedFileLibrary) -> Void)? = nil,
         remoteWindowSender: ((FileWindow, @escaping (Bool) -> Void) -> Void)? = nil,
         sender: @escaping Sender) {
        self.generation=generation;self.directory=directory;self.sender=sender;self.transport=transport
        self.remoteWindowSender = remoteWindowSender
        self.receivedLibrary = receivedLibrary
        queue.async {
            if self.receivedLibrary == nil { self.receivedLibrary = try? ReceivedFileLibrary(directory: directory) }
            if let library = self.receivedLibrary {
                onLibraryReady?(library)
                // A historical filename glob is not deletion authority. Each live
                // TransferStore retires only the stage it created.
            }
            self.refreshRetainedFiles()
            self.publish(.idle)
        }
    }
    @discardableResult func post(_ packet: TransferPacket, completion: @escaping () -> Void = {}) -> Bool {
        admission.lock()
        if remoteRetired { admission.unlock(); return false }
        let focusTicket = slotFocus
        if remoteWindowSender != nil, packet.kind == .chunk {
            guard wireOwner?.0 == packet.id, wireOwner?.1 == packet.generation else {
                admission.unlock(); return false
            }
            guard downloadCredit?.admit(packet) == true else {
                downloadCredit = nil
                admission.unlock()
                queue.async { [weak self] in
                    guard let self, let active = self.owner, active.id == packet.id,
                          active.generation == packet.generation else { return }
                    self.fail(reason: .invalidChunk)
                }
                return false
            }
        }
        guard pending < Self.maxPendingPackets else {
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
            guard let focusTicket, self.fileFocusTicket == focusTicket else {
                if packet.kind == .offer {
                    var refused = TransferPacket(kind: .response, generation: packet.generation, id: packet.id)
                    refused.reason = .busy
                    self.sender(refused) { _ in }
                }
                return
            }
            do { try self.receive(packet, autoAcceptToken: policyToken, focus: focusTicket) }
            catch {
                let reason: TransferReason
                if self.remoteWindowSender != nil, let problem = error as? TransferStore.VerificationFailure {
                    switch problem {
                    case .length: reason = .lengthMismatch
                    case .digest: reason = .hashMismatch
                    }
                } else { reason = .cancelled }
                self.fail(error: error, reason: reason)
            }
        }
        return true
    }
    func postRemoteFileWindow(_ window: FileWindow, completion: @escaping () -> Void) -> Bool {
        admission.lock()
        guard remoteWindowSender != nil, !remoteRetired, pending < Self.maxPendingPackets else {
            admission.unlock(); return false
        }
        pending += 1
        admission.unlock()
        queue.async { [weak self] in
            defer { completion() }
            guard let self else { return }
            defer { self.admission.lock(); self.pending -= 1; self.admission.unlock() }
            guard let active = self.owner, self.current(active), active.outgoing,
                  window.offer == active.id else { return }
            self.applySendCredit(window, active: active)
        }
        return true
    }

    private func applySendCredit(_ window: FileWindow, active: Owner) {
        let previous = active.credit
        let consumed = active.sentEnds.prefix { $0 <= window.consumed }
        guard active.index < active.files.count, window.file == UInt16(active.index),
              active.waiting == nil || active.waiting == .fileAck,
              window.limit <= active.files[active.index].length,
              window.consumed == (consumed.last ?? previous?.consumed ?? 0),
              window.consumed >= (previous?.consumed ?? 0), window.limit >= (previous?.limit ?? 0),
              window.chunks >= (previous?.chunks ?? 0),
              window.chunks <= active.consumedChunks + UInt64(consumed.count + RemoteFileProtocol.maxPendingChunks) else {
            fail(reason: .invalidOffset)
            return
        }
        active.consumedChunks += UInt64(consumed.count)
        active.sentEnds.removeFirst(consumed.count)
        active.credit = window
        if window.chunks == active.consumedChunks + UInt64(RemoteFileProtocol.maxPendingChunks) {
            remotePeerUsesWideWindows = true
        }
        if active.waiting == nil { pump(active) }
    }

    private func grantReceiveCredit(_ active: Owner, consumed: UInt64, chunks: UInt64) {
        guard let remoteWindowSender, current(active), active.index < active.files.count else { return }
        let length = active.files[active.index].length
        guard consumed < length else { active.nextWindow = nil; return }
        if active.windowInFlight {
            active.nextWindow = (consumed, chunks)
            return
        }
        let slots = min(UInt64(remotePeerUsesWideWindows ? RemoteFileProtocol.maxPendingChunks : 1), length - consumed)
        let file = active.index
        let window = FileWindow(offer: active.id, file: UInt16(file), consumed: consumed,
                                limit: min(length, consumed + slots * UInt64(RemoteFileProtocol.maxChunkBytes)),
                                chunks: chunks + slots)
        admission.lock()
        guard !remoteRetired else { admission.unlock(); return }
        proposedDownloadCredit = DownloadCredit(generation: active.generation, window: window, offset: consumed, chunk: chunks)
        admission.unlock()
        active.windowInFlight = true
        remoteWindowSender(window) { [weak self, weak active] ok in
            guard let self, let active else { return }
            self.queue.async {
                guard self.current(active), active.index == file else { return }
                active.windowInFlight = false
                guard ok else { self.fail(); return }
                let next = active.nextWindow
                active.nextWindow = nil
                if let next {
                    self.grantReceiveCredit(active, consumed: next.consumed, chunks: next.chunks)
                }
            }
        }
    }
    func authorizeRemoteWindow(_ window: FileWindow, beginWrite: Bool) -> Bool {
        admission.lock(); defer { admission.unlock() }
        guard !remoteRetired, var credit = proposedDownloadCredit, credit.window == window else { return false }
        if beginWrite {
            // Earlier credit can admit more chunks while the replacement is queued.
            if let previous = downloadCredit, previous.window.offer == window.offer, previous.window.file == window.file {
                credit.offset = max(credit.offset, previous.offset)
                credit.chunk = max(credit.chunk, previous.chunk)
            }
            downloadCredit = credit
            proposedDownloadCredit = nil
        }
        return true
    }

    func checkRemoteDeadline(now: TimeInterval, paused: Bool) {
        admission.lock()
        guard !remoteRetired, !deadlineCheckQueued else { admission.unlock(); return }
        deadlineCheckQueued = true
        admission.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.admission.lock(); self.deadlineCheckQueued = false; self.admission.unlock() }
            guard let active = self.owner, self.current(active) else { return }
            let transferring = active.accepted || (active.outgoing && active.waiting != .response)
            if transferring && paused {
                if active.pausedAt == nil { active.pausedAt = now }
                if let start = active.pausedAt, now - start >= 300 { self.fail() }
                return
            }
            if let start = active.pausedAt {
                active.progressAt = max(now, active.progressAt)
                active.pausedAt = nil
                if now - start >= 300 { self.fail() }
                return
            }
            if now - active.progressAt >= (transferring ? 120 : 60) { self.fail() }
        }
    }
    func sendFiles(_ urls: [URL]) {
        guard let focusTicket = fileFocusTicket else { return }
        if remoteWindowSender != nil {
            admission.lock()
            guard !remoteRetired, wireOwner == nil, pending == 0, !remoteUploadQueued else { admission.unlock(); return }
            remoteUploadQueued = true
            admission.unlock()
        }
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.admission.lock(); self.remoteUploadQueued = false; self.admission.unlock() }
            guard self.fileFocusTicket == focusTicket else { return }
            self.startUpload(urls, focus: focusTicket)
        }
    }
    func retryRemoteFiles() {
        guard let focusTicket = fileFocusTicket else { return }
        queue.async { [weak self] in
            guard let self, self.fileFocusTicket == focusTicket, self.remoteWindowSender != nil, !self.retrySources.isEmpty else { return }
            self.startUpload(self.retrySources, focus: focusTicket)
        }
    }
    private func startUpload(_ urls: [URL], focus: FileFocus) {
        guard !retired, remoteIsLive, owner == nil else { return }
        retrySources = []
        snapshot.retryCount = 0
        var scoped: [URL] = []
        resetDiagnostics(outgoing: true)
        diagnosticStage = "source_open"
        do {
            if remoteWindowSender != nil, !(1...RemoteFileProtocol.maxFiles).contains(urls.count) {
                throw TransferProtocol.Failure.invalid
            }
            let files = try urls.map { url -> TransferFile in
                if url.startAccessingSecurityScopedResource() { scoped.append(url) }
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, let size = values.fileSize, size >= 0,
                      remoteWindowSender == nil || values.isSymbolicLink != true else { throw TransferProtocol.Failure.invalid }
                return TransferFile(name: url.lastPathComponent, length: UInt64(size))
            }
            _ = try TransferProtocol.validate(files)
            let active = Owner(id: UUID(), generation: generation, outgoing: true, files: files)
            active.focus = focus
            if remoteWindowSender != nil {
                var offer = packet(active, .offer)
                offer.files = files
                guard RemoteFileProtocol.validTransfer(offer) else { throw TransferProtocol.Failure.invalid }
            }
            guard remoteIsLive else { throw TransferProtocol.Failure.invalid }
            guard acquireStorage(active) else { throw CocoaError(.fileLocking) }
            active.sources = urls; active.scoped = scoped; owner = active
            admission.lock(); wireOwner = (active.id, active.generation); admission.unlock()
            active.waiting = .response
            publish(.offering)
            send(active, .offer) { _ in }
        } catch {
            for url in scoped { url.stopAccessingSecurityScopedResource() }
            snapshot.failure = FailureDetail.classify(error, stage: diagnosticStage)
            publish(.failed)
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
    func decide(_ accepted: Bool, consent: Consent) {
        guard let focusTicket = fileFocusTicket else { return }
        queue.async { [weak self] in
            guard let self, self.fileFocusTicket == focusTicket, consent.sessionID == self.sessionID,
                  consent.slotAction == focusTicket.action(id: consent.transferID) else { return }
            self.decideOnQueue(accepted, expectedTransferID: consent.transferID)
        }
    }
    #if targetEnvironment(simulator)
    // Existing IO tests capture the currently published owner before queueing a decision.
    func consentForTesting() -> Consent? {
        admission.lock(); defer { admission.unlock() }
        return wireOwner.map { Consent(sessionID: sessionID, transferID: $0.0, slotAction: slotFocus?.action(id: $0.0)) }
    }
    func decide(_ accepted: Bool) {
        guard let consent = consentForTesting() else { return }
        decide(accepted, consent: consent)
    }
    func drainRemoteIOForTesting() { queue.sync {} }
    #endif
    private func decideOnQueue(_ accepted: Bool, expectedTransferID: UUID, policyToken: UInt64? = nil) {
        guard !retired, remoteIsLive, let active=owner, !active.outgoing, !active.accepted,
              expectedTransferID == active.id else { return }
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
                var response=packet(active,.response);response.accepted=true
                write(active,response) { [weak self, weak active] _ in
                    if let self, let active, active.index == 0 {
                        self.grantReceiveCredit(active, consumed: 0, chunks: 0)
                    }
                }
            } else {
                var response=packet(active,.response);response.reason = .userRejected
                write(active,response) { [weak self] ok in if ok {self?.finish(.rejected)} }
            }
        } catch {
            let failure = error as NSError
            let storageFull = failure.domain == NSCocoaErrorDomain && failure.code == CocoaError.fileWriteOutOfSpace.rawValue
            fail(error: error, reason: remoteWindowSender != nil && storageFull ? .insufficientStorage : .cancelled)
        }
    }
    func cancel(failed: Bool = false, action: RemoteFileSlotScope.Action? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            if let action {
                guard let active = self.owner, self.current(active),
                      active.focus.action(id: active.id) == action else { return }
            }
            self.fail(phase: failed ? .failed : .cancelled)
        }
    }
    func retire() {
        setAutoAccept(false, localGeneration: generation)
        if remoteWindowSender != nil {
            admission.lock(); remoteRetired = true; downloadCredit = nil; proposedDownloadCredit = nil; admission.unlock()
        }
        queue.async { self.retired = true; self.finish(.retired) }
    }
    private func packet(_ active: Owner,_ kind: TransferKind) -> TransferPacket {TransferPacket(kind:kind,generation:active.generation,id:active.id)}
    private func current(_ active: Owner) -> Bool {!retired && owner === active && remoteIsLive && fileFocusTicket == active.focus}
    private func publish(_ phase: Phase, rejectionReason: TransferReason? = nil) {
        snapshot.slotAction = owner.flatMap { $0.focus.action(id: $0.id) }
        snapshot.consent = owner.flatMap { !$0.outgoing && !$0.accepted && phase == .awaitingDecision ? Consent(sessionID: sessionID, transferID: $0.id, slotAction: snapshot.slotAction) : nil }
        snapshot.phase=phase
        snapshot.rejectionReason = rejectionReason
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
    private func finish(_ phase: Phase, rejectionReason: TransferReason? = nil) {
        admission.lock();wireOwner=nil;downloadCredit=nil;proposedDownloadCredit=nil;admission.unlock()
        if let active=owner {
            if remoteWindowSender != nil, active.outgoing, [.failed, .cancelled, .rejected].contains(phase) {
                retrySources = Array(active.sources.dropFirst(active.index))
            }
            retiredIDs.append(active.id);if retiredIDs.count>256 {retiredIDs.removeFirst()}
            active.close() // Stage/source handles close before the one-use local lease releases.
        }
        if phase == .retired || phase == .completed { retrySources = [] }
        snapshot.retryCount = retrySources.count
        refreshRetainedFiles();publish(phase, rejectionReason: rejectionReason);owner=nil
    }
    private func fail(phase: Phase = .failed, error: Error? = nil, reason: TransferReason = .cancelled) {
        guard let active=owner else {return}
        if phase == .failed {snapshot.failure = error.map {FailureDetail.classify($0, stage: diagnosticStage)} ?? snapshot.failure ?? FailureDetail(reason:"TRANSFER_FAILED",domain:"Transfer",code:0)}
        var cancel=packet(active,.cancel);cancel.reason = reason;sender(cancel){_ in};finish(phase)
    }
    private func write(_ active: Owner,_ packet: TransferPacket,_ done: @escaping (Bool)->Void) {
        guard current(active) else {return}
        sender(packet) { [weak self,weak active] ok in
            guard let self,let active else{return}
            self.queue.async {guard self.current(active) else{return};if !ok {self.snapshot.failure=FailureDetail(reason:"SEND_FAILED",domain:"Transfer",code:0);self.event("send_failed");self.fail();return};active.progressAt=ProcessInfo.processInfo.systemUptime;if packet.kind != .chunk {self.event("send_\(packet.kind)")};done(ok)}
        }
    }
    private func send(_ active: Owner,_ kind: TransferKind,_ done: @escaping (Bool)->Void) {
        var p=packet(active,kind);if kind == .offer {p.files=active.files};write(active,p,done)
    }
    private func receive(_ p: TransferPacket, autoAcceptToken: UInt64?, focus: FileFocus) throws {
        guard !retired, remoteIsLive else {return}
        if p.kind == .offer {
            guard !retiredIDs.contains(p.id), peerGeneration == nil || peerGeneration == p.generation else {return}
            peerGeneration = p.generation
            guard owner == nil else {var busy=TransferPacket(kind:.response,generation:p.generation,id:p.id);busy.reason = .busy;sender(busy){_ in};return}
            _ = try TransferProtocol.validate(p.files)
            let active=Owner(id:p.id,generation:p.generation,outgoing:false,files:p.files)
            active.focus = focus
            // Invalid storage preserves the existing F03 manual admission failure stage.
            // An available authority must fence Clear/export before exposing pending consent.
            if receivedLibrary != nil && !acquireStorage(active) {
                var busy=TransferPacket(kind:.response,generation:p.generation,id:p.id)
                busy.reason = .busy;sender(busy){_ in};return
            }
            resetDiagnostics(outgoing:false);owner=active
            retrySources = []; snapshot.retryCount = 0
            admission.lock();wireOwner=(p.id,p.generation);admission.unlock();event("offer");publish(.awaitingDecision)
            if let token = autoAcceptToken, ownsAutoAcceptToken(token) {
                decideOnQueue(true, expectedTransferID: p.id, policyToken: token)
            }
            return
        }
        guard let active=owner, active.id==p.id, active.generation==p.generation else {return}
        active.progressAt = ProcessInfo.processInfo.systemUptime
        if p.kind != .chunk {event("receive_\(p.kind)")}
        if p.kind == .cancel {finish(.cancelled);return}
        if active.outgoing {
            guard active.waiting == p.kind else {throw TransferProtocol.Failure.invalid}
            if p.kind == .response {
                guard p.accepted else { finish(.rejected, rejectionReason: p.reason); return }
                active.waiting = nil
                try openNext(active)
                return
            }
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
            if remoteWindowSender != nil, p.bytes.count > RemoteFileProtocol.defaultChunkBytes {
                remotePeerUsesWideWindows = true
            }
            active.observedBytes += UInt64(p.bytes.count)
            active.receivedChunks += 1
            if p.chunkIndex == 0 {event("first_chunk", updateStage:false)}
            progress(active,bytes:active.bytes+store.written)
            grantReceiveCredit(active, consumed: store.written, chunks: p.chunkIndex + 1)
        case .fileEnd:
            guard p.fileIndex==active.index,let store=active.store else {throw TransferProtocol.Failure.invalid}
            event("verify_publish");publish(.verifying)
            let final = try store.publish(length: p.offset, digest: p.bytes) { link in
                if self.remoteWindowSender == nil { return link() }
                // The atomic link and revocation share an order. Hashing and sync happen outside this lock.
                self.admission.lock(); defer { self.admission.unlock() }
                guard !self.remoteRetired else { throw TransferProtocol.Failure.invalid }
                return link()
            }
            active.store = nil
            event("receipt_commit")
            do {
                guard let receivedLibrary else { throw CocoaError(.fileReadUnknown) }
                try receivedLibrary.recordPublished(final,length:p.offset,digest:p.bytes)
            } catch {
                // Published bytes survive as quota-counted legacy; no successful FileAck.
                refreshRetainedFiles();throw error
            }
            active.received.append(final);active.bytes+=p.offset;active.published+=1;active.index+=1
            active.windowInFlight = false
            active.nextWindow = nil
            admission.lock(); downloadCredit = nil; proposedDownloadCredit = nil; admission.unlock()
            refreshRetainedFiles();event("published")
            if active.index<active.files.count {active.store=try TransferStore(directory:directory,metadata:active.files[active.index],id:active.id)}
            var ack=packet(active,.fileAck);ack.fileIndex=p.fileIndex;publish(.receiving)
            let nextIndex = active.index
            write(active,ack) { [weak self, weak active] _ in
                if let self, let active, active.index == nextIndex {
                    self.grantReceiveCredit(active, consumed: 0, chunks: 0)
                }
            }
        case .end:
            guard active.index==active.files.count,active.store==nil else {throw TransferProtocol.Failure.invalid}
            send(active,.ack){[weak self] ok in if ok {self?.finish(.completed)}}
        default:throw TransferProtocol.Failure.invalid
        }
    }
    private func openNext(_ active: Owner) throws {
        guard current(active) else {return}
        let url=active.sources[active.index],values=try url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey,.isRegularFileKey,.isSymbolicLinkKey])
        guard remoteWindowSender == nil || (values.isRegularFile == true && values.isSymbolicLink != true) else { throw TransferProtocol.Failure.invalid }
        guard let size=values.fileSize,UInt64(size)==active.files[active.index].length else {throw TransferProtocol.Failure.invalid}
        active.initialDate=values.contentModificationDate;active.handle=try FileHandle(forReadingFrom:url);active.offset=0;active.chunk=0;active.hash=SHA256()
        active.credit = nil; active.sentEnds = []; active.consumedChunks = 0; active.chunkInFlight = false
        publish(.sending);pump(active)
    }
    private func pump(_ active: Owner) {
        guard current(active), !active.chunkInFlight else {return}
        do {
            let length=active.files[active.index].length
            if active.offset<length {
                var size = min(UInt64(TransferProtocol.defaultChunkBytes), length - active.offset)
                if remoteWindowSender != nil {
                    guard let credit = active.credit, active.offset < credit.limit, active.chunk < credit.chunks else { return }
                    size = min(UInt64(RemoteFileProtocol.maxChunkBytes), credit.limit - active.offset, length - active.offset)
                }
                guard let bytes=try active.handle?.read(upToCount:Int(size)),!bytes.isEmpty else {throw TransferProtocol.Failure.invalid}
                active.hash.update(data:bytes);var p=packet(active,.chunk);p.fileIndex=UInt16(active.index);p.offset=active.offset;p.chunkIndex=active.chunk;p.bytes=bytes
                active.chunkInFlight = true
                let usesCredit = remoteWindowSender != nil
                if usesCredit {
                    active.offset += UInt64(bytes.count)
                    active.chunk += 1
                    active.sentEnds.append(active.offset)
                }
                write(active, p) { [weak self, weak active] _ in
                    guard let self, let active else { return }
                    if !usesCredit {
                        active.offset += UInt64(bytes.count)
                        active.chunk += 1
                    }
                    active.chunkInFlight = false
                    active.observedBytes += UInt64(bytes.count)
                    self.progress(active, bytes: active.bytes + active.offset)
                    self.pump(active)
                }
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
        let observedBytes = active?.observedBytes ?? 0
        let expected = active?.files.reduce(UInt64(0)) {$0+$1.length} ?? snapshot.total
        diagnostic?("component=DataTransfer direction=\(snapshot.outgoing ? "IPAD_TO_PC" : "PC_TO_IPAD") local_generation=\(generation) peer_generation=\(active?.generation ?? 0) transfer_id=\(active?.id.uuidString ?? "none") stage=\(stage) file_index=\(active?.index ?? 0) file_count=\(active?.files.count ?? 0) bytes=\(observedBytes) expected=\(expected) file_offset=\(offset) chunk_count=\(active?.outgoing == true ? (active?.chunk ?? 0) : (active?.receivedChunks ?? 0)) reason=\(snapshot.failure?.reason ?? "none") error_domain=\(snapshot.failure?.domain ?? "none") error_code=\(snapshot.failure?.code ?? 0) dropped=\(droppedDiagnostics)")
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
