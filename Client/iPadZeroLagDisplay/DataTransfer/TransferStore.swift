import Darwin
import Foundation
import CryptoKit

/// Serial worker-owned single-file stage in app-private storage.
final class TransferStore {
    private let directory: URL
    private let metadata: TransferFile
    private let temporary: URL
    private var handle: FileHandle?
    private var hasher = SHA256()
    private(set) var written: UInt64 = 0
    private var nextChunk: UInt64 = 0
    private var terminal = false
    init(directory: URL, metadata: TransferFile, id: UUID) throws {
        guard TransferProtocol.validName(metadata.name), metadata.length <= TransferProtocol.maxFileBytes else { throw TransferProtocol.Failure.invalid }
        self.directory = directory; self.metadata = metadata
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey,.volumeAvailableCapacityForImportantUsageKey])
        guard values.isSymbolicLink != true else { throw TransferProtocol.Failure.invalid }
        if let capacity = values.volumeAvailableCapacityForImportantUsage, capacity < 0 || UInt64(capacity) < metadata.length + 64 * 1024 * 1024 { throw CocoaError(.fileWriteOutOfSpace) }
        temporary = directory.appendingPathComponent(".scdt-\(id.uuidString)-\(UUID().uuidString).part")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: temporary)
    }
    func append(chunk: UInt64, offset: UInt64, bytes: Data) throws {
        guard !terminal, let handle, chunk == nextChunk, offset == written, !bytes.isEmpty,
              bytes.count <= TransferProtocol.maxChunkBytes, UInt64(bytes.count) <= metadata.length - written else { throw TransferProtocol.Failure.invalid }
        do { try handle.write(contentsOf: bytes); hasher.update(data: bytes); written += UInt64(bytes.count); nextChunk += 1 }
        catch { retire(); throw error }
    }
    func publish(length: UInt64, digest: Data) throws -> URL {
        guard !terminal, let handle else { throw TransferProtocol.Failure.invalid }
        do {
            guard length == metadata.length, written == length, digest.count == 32, Data(hasher.finalize()) == digest else { throw TransferProtocol.Failure.invalid }
            try handle.synchronize(); try handle.close(); self.handle = nil
            let original = URL(fileURLWithPath: metadata.name), ext = original.pathExtension, stem = original.deletingPathExtension().lastPathComponent
            for suffix in 0..<10000 {
                let name = suffix == 0 ? metadata.name : stem + " (\(suffix))" + (ext.isEmpty ? "" : "." + ext)
                let final = directory.appendingPathComponent(name)
                // link() publishes atomically on the same app-owned volume and fails if the name exists.
                let result = temporary.path.withCString { source in final.path.withCString { target in link(source,target) } }
                if result == 0 { try FileManager.default.removeItem(at: temporary); terminal = true; return final }
                if errno != EEXIST { throw CocoaError(.fileWriteUnknown) }
            }
            throw CocoaError(.fileWriteFileExists)
        } catch { retire(); throw error }
    }
    func retire() {
        terminal = true; try? handle?.close(); handle = nil
        try? FileManager.default.removeItem(at: temporary)
    }
    deinit { retire() }
}
