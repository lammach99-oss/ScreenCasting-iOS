import CryptoKit
import Darwin
import Foundation

/// App-private storage authority. All instances for the same root share leases and serialization.
final class ReceivedFileLibrary {
    struct Inventory {
        let retainedCount: Int
        let retainedBytes: UInt64
        let eligibleCount: Int
        let eligibleBytes: UInt64
        let files: [URL]
        let busy: Bool
        let eligibleNames: Set<String>
        let fileBytes: [URL: UInt64]
        let fingerprint: Data
        let revision: UInt64
    }
    struct Confirmation {
        let count: Int
        let bytes: UInt64
        fileprivate let nonce: UUID
        fileprivate let root: Identity
        fileprivate let targets: [ClearTarget]
    }
    struct ClearResult {
        let deletedCount: Int
        let failedCount: Int
        let deletedBytes: UInt64
        let journalCleanupDurable: Bool
    }
    struct Hooks {
        var beforeReceiptCommit: (() throws -> Void)?
        var beforeUnlink: ((String) throws -> Void)?
        var payloadBytesRead: ((Int) -> Void)?
    }
    fileprivate struct Identity: Codable, Equatable {
        let device: UInt64, inode: UInt64
        init(_ value: stat) { device = UInt64(value.st_dev); inode = UInt64(value.st_ino) }
    }
    fileprivate struct Receipt: Codable {
        let id: UUID
        let name: String
        let identity: Identity
        let length: UInt64
        let digest: Data
        let modifiedSeconds: Int64, modifiedNanoseconds: Int64
        let birthSeconds: Int64, birthNanoseconds: Int64
    }
    fileprivate struct ClearTarget {
        let name: String
        let identity: Identity
        let length: UInt64
        let modifiedSeconds: Int64, modifiedNanoseconds: Int64
        let birthSeconds: Int64, birthNanoseconds: Int64
        let receiptID: UUID?
        init(name: String, value: stat, receiptID: UUID?) {
            self.name = name; identity = Identity(value); length = UInt64(value.st_size)
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            birthSeconds = Int64(value.st_birthtimespec.tv_sec); birthNanoseconds = Int64(value.st_birthtimespec.tv_nsec)
            self.receiptID = receiptID
        }
    }
    private struct Journal: Codable {
        var version = 1
        let root: Identity
        var receipts: [Receipt] = []
        var confirmation: UUID?
    }
    private final class State {
        let directory: URL, identity: Identity, fd: Int32, metadata: Int32
        let lock = NSLock()
        var transfer: UUID?
        var revision: UInt64 = 0
        var exports: Set<UUID> = []
        var hooks: Hooks
        init(directory: URL, hooks: Hooks) throws {
            var original = stat()
            if lstat(directory.path, &original) != 0 {
                guard errno == ENOENT else { throw Self.error() }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard lstat(directory.path, &original) == 0 else { throw Self.error() }
            }
            guard original.st_mode & S_IFMT == S_IFDIR else { throw CocoaError(.fileReadInvalidFileName) }
            self.directory = directory.resolvingSymlinksInPath().standardizedFileURL
            fd = open(self.directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Self.error() }
            var live = stat()
            guard fstat(fd, &live) == 0, Identity(live) == Identity(original) else {
                close(fd); throw CocoaError(.fileReadUnknown)
            }
            identity = Identity(live)
            if mkdirat(fd, ReceivedFileLibrary.metadataName, 0o700) != 0 && errno != EEXIST {
                close(fd); throw Self.error()
            }
            metadata = openat(fd, ReceivedFileLibrary.metadataName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard metadata >= 0 else { close(fd); throw Self.error() }
            self.hooks = hooks
        }
        static func error() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        deinit { close(metadata); close(fd) }
    }
    static let metadataName = ".scdt-receipts-v1"
    private static let registryLock = NSLock()
    private final class WeakState { weak var value: State?; init(_ value: State) { self.value = value } }
    private static var registry: [String: WeakState] = [:]
    private let state: State
    init(directory: URL, hooks: Hooks = Hooks()) throws {
        // Reject a symlink leaf before canonicalization (including aliases to a safe root).
        var value = stat()
        if lstat(directory.path, &value) == 0, value.st_mode & S_IFMT != S_IFDIR {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let key = directory.resolvingSymlinksInPath().standardizedFileURL.path
        Self.registryLock.lock(); defer { Self.registryLock.unlock() }
        if let existing = Self.registry[key]?.value { state = existing }
        else {
            state = try State(directory: directory, hooks: hooks)
            Self.registry = Self.registry.filter { $0.value.value != nil }
            Self.registry[key] = WeakState(state)
        }
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        state.lock.lock(); defer { state.lock.unlock() }; return try body()
    }
    private func validateRoot() throws {
        var value = stat(), metadata = stat(), held = stat()
        guard lstat(state.directory.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
              Identity(value) == state.identity,
              fstatat(state.fd, Self.metadataName, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR, fstat(state.metadata, &held) == 0,
              Identity(metadata) == Identity(held) else { throw CocoaError(.fileReadUnknown) }
    }
    private func readJournal() throws -> Journal {
        try validateRoot()
        let fd = openat(state.metadata, "receipts.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            guard errno == ENOENT else { throw State.error() }
            return Journal(root: state.identity)
        }
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_nlink == 1, value.st_size >= 0, value.st_size <= 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n >= 0 else { throw State.error() }
            if n == 0 { break }
            guard data.count + n <= 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
            data.append(contentsOf: buffer.prefix(n))
        }
        let journal = try JSONDecoder().decode(Journal.self, from: data)
        guard journal.version == 1, journal.root == state.identity, journal.receipts.count <= 256,
              Set(journal.receipts.map { $0.name }).count == journal.receipts.count,
              journal.receipts.allSatisfy({ validLeaf($0.name) && $0.digest.count == 32 }) else { throw CocoaError(.fileReadCorruptFile) }
        return journal
    }
    private func commit(_ journal: Journal) throws {
        try validateRoot(); try state.hooks.beforeReceiptCommit?()
        let data = try JSONEncoder().encode(journal)
        guard data.count <= 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        let name = "transaction-" + UUID().uuidString
        let fd = openat(state.metadata, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw State.error() }
        defer { close(fd); unlinkat(state.metadata, name, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard n > 0 else { throw State.error() }; offset += n
            }
        }
        guard fsync(fd) == 0 else { throw State.error() }
        guard renameat(state.metadata, name, state.metadata, "receipts.json") == 0 else { throw State.error() }
        guard fsync(state.metadata) == 0 else { throw State.error() }
    }
    private func validLeaf(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") &&
        name != Self.metadataName && !(name.hasPrefix(".scdt-") && name.hasSuffix(".part")) && !name.utf8.contains(0)
    }
    private func leaf(_ url: URL) throws -> String {
        guard url.isFileURL, url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == state.directory,
              validLeaf(url.lastPathComponent) else { throw CocoaError(.fileReadInvalidFileName) }
        return url.lastPathComponent
    }
    private func same(_ value: stat, _ receipt: Receipt) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_nlink == 1 && value.st_size >= 0 &&
        Identity(value) == receipt.identity && UInt64(value.st_size) == receipt.length &&
        Int64(value.st_mtimespec.tv_sec) == receipt.modifiedSeconds && Int64(value.st_mtimespec.tv_nsec) == receipt.modifiedNanoseconds &&
        Int64(value.st_birthtimespec.tv_sec) == receipt.birthSeconds && Int64(value.st_birthtimespec.tv_nsec) == receipt.birthNanoseconds
    }
    private func same(_ value: stat, _ target: ClearTarget) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_nlink == 1 && value.st_size >= 0 &&
        Identity(value) == target.identity && UInt64(value.st_size) == target.length &&
        Int64(value.st_mtimespec.tv_sec) == target.modifiedSeconds && Int64(value.st_mtimespec.tv_nsec) == target.modifiedNanoseconds &&
        Int64(value.st_birthtimespec.tv_sec) == target.birthSeconds && Int64(value.st_birthtimespec.tv_nsec) == target.birthNanoseconds
    }
    private func verified(_ name: String, receipt: Receipt? = nil) throws -> (stat, Data) {
        guard validLeaf(name) else { throw CocoaError(.fileReadInvalidFileName) }
        let fd = openat(state.fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw State.error() }; defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_size >= 0, receipt.map({ same(before, $0) }) ?? true else { throw CocoaError(.fileReadUnknown) }
        var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n >= 0 else { throw State.error() }; if n == 0 { break }
            state.hooks.payloadBytesRead?(n)
            hash.update(data: Data(buffer.prefix(n)))
        }
        var after = stat(), path = stat()
        guard fstat(fd, &after) == 0, fstatat(state.fd, name, &path, AT_SYMLINK_NOFOLLOW) == 0,
              Identity(before) == Identity(after), Identity(before) == Identity(path),
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, path.st_nlink == 1,
              path.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadUnknown) }
        let digest = Data(hash.finalize())
        guard receipt.map({ digest == $0.digest && same(path, $0) }) ?? true else { throw CocoaError(.fileReadCorruptFile) }
        return (path, digest)
    }
    private func eligible(_ journal: Journal) -> [Receipt] {
        journal.receipts.filter { (try? verified($0.name, receipt: $0)) != nil }
    }
    // Inventory is advisory; destructive Clear still verifies payload digests.
    private func inventoryReceipts(_ journal: Journal) -> [Receipt] {
        journal.receipts.filter { receipt in
            var value = stat()
            return fstatat(state.fd, receipt.name, &value, AT_SYMLINK_NOFOLLOW) == 0 &&
                same(value, receipt)
        }
    }
    func snapshot() throws -> Inventory { try locked { try snapshotOnLock() } }
    private func snapshotOnLock() throws -> Inventory {
        try validateRoot()
        let receipts = (try? readJournal()).map(inventoryReceipts) ?? []
        let children = try FileManager.default.contentsOfDirectory(at: state.directory, includingPropertiesForKeys: nil)
        var files: [URL] = [], bytes: UInt64 = 0
        var fileBytes: [URL: UInt64] = [:], identities: [String] = []
        for url in children where validLeaf(url.lastPathComponent) {
            var value = stat()
            guard fstatat(state.fd, url.lastPathComponent, &value, AT_SYMLINK_NOFOLLOW) == 0,
                  value.st_mode & S_IFMT == S_IFREG, value.st_size >= 0 else { continue }
            let (sum, overflow) = bytes.addingReportingOverflow(UInt64(value.st_size))
            guard !overflow else { throw CocoaError(.fileReadUnknown) }; bytes = sum; files.append(url)
            fileBytes[url] = UInt64(value.st_size)
            identities.append("\(url.lastPathComponent.utf8.count):\(url.lastPathComponent)|\(value.st_dev)|\(value.st_ino)|\(value.st_size)|\(value.st_mtimespec.tv_sec)|\(value.st_mtimespec.tv_nsec)|\(value.st_birthtimespec.tv_sec)|\(value.st_birthtimespec.tv_nsec)")
        }
        return Inventory(retainedCount: files.count, retainedBytes: bytes, eligibleCount: receipts.count,
                         eligibleBytes: receipts.reduce(0) { $0 + $1.length },
                         files: files.sorted { $0.lastPathComponent < $1.lastPathComponent },
                         busy: state.transfer != nil || !state.exports.isEmpty,
                         eligibleNames: Set(receipts.map(\.name)), fileBytes: fileBytes,
                         fingerprint: Data(SHA256.hash(data: try JSONEncoder().encode([identities.sorted(), receipts.map { $0.id.uuidString }.sorted()]))),
                         revision: state.revision)
    }
    func recordPublished(_ url: URL, length: UInt64, digest: Data) throws { try locked {
        var journal = try readJournal(); let name = try leaf(url)
        guard digest.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
        let (value, actual) = try verified(name)
        guard UInt64(value.st_size) == length, actual == digest else { throw CocoaError(.fileReadCorruptFile) }
        let receipt = Receipt(id: UUID(), name: name, identity: Identity(value), length: length, digest: digest,
                              modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
                              birthSeconds: Int64(value.st_birthtimespec.tv_sec), birthNanoseconds: Int64(value.st_birthtimespec.tv_nsec))
        // Missing files cannot accumulate unbounded stale receipts after a crash.
        journal.receipts = inventoryReceipts(journal).filter { $0.name != name }
        guard journal.receipts.count < 256 else { throw CocoaError(.fileWriteOutOfSpace) }
        journal.receipts.append(receipt); try commit(journal); state.revision &+= 1
    } }
    func beginTransfer(owner: UUID) -> Bool { locked {
        guard state.transfer == nil, state.exports.isEmpty, (try? validateRoot()) != nil else { return false }
        state.transfer = owner; state.revision &+= 1; return true
    } }
    func endTransfer(owner: UUID) { locked { if state.transfer == owner { state.transfer = nil; state.revision &+= 1 } } }
    func beginExport(_ url: URL) throws -> UUID { try locked {
        try validateRoot(); guard state.transfer == nil else { throw CocoaError(.fileLocking) }
        let name = try leaf(url); _ = try verified(name)
        let token = UUID(); state.exports.insert(token); state.revision &+= 1; return token
    } }
    func endExport(_ token: UUID) { locked { if state.exports.remove(token) != nil { state.revision &+= 1 } } }
    func confirmClear() throws -> Confirmation { try locked {
        guard state.transfer == nil, state.exports.isEmpty else { throw CocoaError(.fileLocking) }
        // Corrupt metadata never authorizes deletion, even when the inventory remains visible.
        var journal = try readJournal()
        let receipts = Dictionary(uniqueKeysWithValues: eligible(journal).map { ($0.name, $0) })
        let children = try FileManager.default.contentsOfDirectory(at: state.directory, includingPropertiesForKeys: nil)
        var targets: [ClearTarget] = [], bytes: UInt64 = 0
        for url in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where validLeaf(url.lastPathComponent) {
            let name = url.lastPathComponent
            var value = stat()
            guard fstatat(state.fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0,
                  value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1, value.st_size >= 0 else { continue }
            let (total, overflow) = bytes.addingReportingOverflow(UInt64(value.st_size))
            guard !overflow else { throw CocoaError(.fileReadUnknown) }; bytes = total
            let receiptID = receipts[name].flatMap { same(value, $0) ? $0.id : nil }
            targets.append(ClearTarget(name: name, value: value, receiptID: receiptID))
        }
        let nonce = UUID(); journal.confirmation = nonce; try commit(journal)
        return Confirmation(count: targets.count, bytes: bytes, nonce: nonce, root: state.identity, targets: targets)
    } }
    func clear(_ confirmation: Confirmation, expectedFingerprint: Data? = nil, expectedRevision: UInt64? = nil,
               authorize: (() -> Bool)? = nil) throws -> ClearResult { try locked {
        guard state.transfer == nil, state.exports.isEmpty else { throw CocoaError(.fileLocking) }
        if let expectedFingerprint, let expectedRevision {
            let current = try snapshotOnLock()
            guard current.fingerprint == expectedFingerprint, current.revision == expectedRevision else { throw CocoaError(.fileReadUnknown) }
        }
        // Same storage lock as lease/receipt changes; authorization callback only reads lock-backed clocks.
        guard authorize?() != false else { throw CocoaError(.fileReadNoPermission) }
        var journal = try readJournal()
        guard confirmation.root == state.identity, journal.confirmation == confirmation.nonce else { throw CocoaError(.fileReadNoPermission) }
        journal.confirmation = nil; try commit(journal) // Consume durably BEFORE the first destructive operation.
        var deleted = 0, failed = 0, bytes: UInt64 = 0
        for target in confirmation.targets {
            do {
                try validateRoot()
                guard validLeaf(target.name) else { throw CocoaError(.fileReadInvalidFileName) }
                if let receiptID = target.receiptID {
                    guard let receipt = journal.receipts.first(where: { $0.id == receiptID }) else { throw CocoaError(.fileReadUnknown) }
                    _ = try verified(target.name, receipt: receipt)
                }
                try state.hooks.beforeUnlink?(target.name)
                try validateRoot()
                var live = stat()
                guard fstatat(state.fd, target.name, &live, AT_SYMLINK_NOFOLLOW) == 0, same(live, target) else { throw CocoaError(.fileReadUnknown) }
                guard unlinkat(state.fd, target.name, 0) == 0 else { throw State.error() }
                deleted += 1; bytes += target.length
                journal.receipts.removeAll { $0.name == target.name }
            } catch { failed += 1 }
        }
        // A failed metadata cleanup leaves only identity-bound stale records, never authority over a replacement.
        var durable = true
        do { try commit(journal) } catch { durable = false }
        state.revision &+= 1
        return ClearResult(deletedCount: deleted, failedCount: failed, deletedBytes: bytes, journalCleanupDurable: durable)
    } }
}
