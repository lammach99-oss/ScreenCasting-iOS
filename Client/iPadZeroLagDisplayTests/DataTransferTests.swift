import CryptoKit
import Network
import XCTest
import Foundation
@testable import iPadCasting

final class DataTransferTests: XCTestCase {
    func testF03SnapshotRetainsSanitizedFailureAndDirection() {
        let fields = Set(Mirror(reflecting: DataTransferManager.Snapshot()).children.compactMap(\.label))
        XCTAssertTrue(fields.contains("failure"), "Receive errors must not disappear behind Failed")
        XCTAssertTrue(fields.contains("outgoing"), "Terminal progress must retain transfer direction")
        XCTAssertTrue(fields.contains("stage"), "Retain the actual failed stage")
    }
    func testCanonicalEnvelopeAndAllTruncationPoints() throws {
        let id=UUID(uuidString:"00112233-4455-6677-8899-AABBCCDDEEFF")!
        let p=TransferPacket(kind:.end,generation:0x0807060504030201,id:id)
        let bytes=try TransferProtocol.encode(p)
        XCTAssertEqual(bytes.map{String(format:"%02X",$0)}.joined(),"01010203040506070800112233445566778899AABBCCDDEEFF")
        for cut in 0..<bytes.count {XCTAssertThrowsError(try TransferProtocol.decode(.end,bytes.prefix(cut)))}
        XCTAssertThrowsError(try TransferProtocol.decode(.end,bytes+Data([0])))
    }
    func testSharedGoldenWireVectors() throws {
        let vectors: [(UInt8,String)] = [
            (43, "01010203040506070800112233445566778899AABBCCDDEEFF0100030000000000000000000500612E7478740300000000000000"),
            (43, "01010203040506070800112233445566778899AABBCCDDEEFF0200030000000000000000000500612E747874030000000000000001000A00C491E1BAB9702E7478740000000000000000"),
            (44, "01010203040506070800112233445566778899AABBCCDDEEFF0100"),
            (44, "01010203040506070800112233445566778899AABBCCDDEEFF0001"),
            (45, "01010203040506070800112233445566778899AABBCCDDEEFF00000000000000000000000000000000000003000000010203"),
            (45, "01010203040506070800112233445566778899AABBCCDDEEFF000001000000000000000040000000000000020000000405"),
            (46, "01010203040506070800112233445566778899AABBCCDDEEFF00000000000000000000E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"),
            (46, "01010203040506070800112233445566778899AABBCCDDEEFF00000300000000000000039058C6F2C0CB492C533B0A4D14EF77CC0F78ABCCCED5287D84A1A2011CFB81"),
            (47, "01010203040506070800112233445566778899AABBCCDDEEFF000000"),
            (47, "01010203040506070800112233445566778899AABBCCDDEEFF00000A"),
            (48, "01010203040506070800112233445566778899AABBCCDDEEFF0E"),
            (49, "01010203040506070800112233445566778899AABBCCDDEEFF"),
            (50, "01010203040506070800112233445566778899AABBCCDDEEFF00")
        ]
        for (raw,hex) in vectors {
            var bytes=Data();var index=hex.startIndex
            while index<hex.endIndex {let next=hex.index(index,offsetBy:2);bytes.append(UInt8(hex[index..<next],radix:16)!);index=next}
            let kind=TransferKind(rawValue:raw)!,packet=try TransferProtocol.decode(kind,bytes)
            XCTAssertEqual(try TransferProtocol.encode(packet),bytes)
            XCTAssertEqual(packet.generation,0x0807060504030201)
            XCTAssertEqual(packet.id.uuidString,"00112233-4455-6677-8899-AABBCCDDEEFF")
        }
    }
    func testExistingParserEverySplitAndAdjacentInput() throws {
        let transfer=TransferPacket(kind:.chunk,generation:7,id:UUID(),bytes:Data([1,2,3]))
        let payload=try TransferProtocol.encode(transfer)
        func frame(_ type: WireMessageType,_ payload: Data) -> Data {
            var result=Data("SCST".utf8);result.append(contentsOf:[1,type.rawValue,0,0])
            var length=UInt32(payload.count).littleEndian,sequence=UInt32(1).littleEndian
            withUnsafeBytes(of:&length){result.append(contentsOf:$0)};withUnsafeBytes(of:&sequence){result.append(contentsOf:$0)};result.append(payload);return result
        }
        let encoded=frame(.transferChunk,payload)+frame(.pointerInput,Data(count:8))+frame(.ping,Data(count:16))
        for split in 0...encoded.count {
            let parser=WireStreamParser(generation:7);var types:[WireMessageType]=[]
            parser.consume(encoded.prefix(split),generation:7){if case .message(let m)=$0 {types.append(m.header.type)}}
            parser.consume(encoded.dropFirst(split),generation:7){if case .message(let m)=$0 {types.append(m.header.type)}}
            XCTAssertEqual(types,[.transferChunk,.pointerInput,.ping])
        }
    }
    func testMalformedBulkLengthNeverAllocatesPayload() {
        let parser=WireStreamParser(generation:7)
        var header=Data("SCST".utf8);header.append(contentsOf:[1,45,0,0]);var length=UInt32(TransferProtocol.maxPayloadBytes+1).littleEndian
        withUnsafeBytes(of:&length){header.append(contentsOf:$0)};header.append(Data(count:4))
        parser.consume(header,generation:7){_ in}
        XCTAssertEqual(parser.allocatedPayloadBytes,0)
    }
    func testUnsafeNamesAndBounds() throws {
        for name in ["",".","..","../x","/x","C:x","\\\\pc\\x","a/b","a\\b","NUL","CON.txt","COM1","LPT9.txt","x.","x ","a\0b",String(repeating:"a",count:256)] {XCTAssertFalse(TransferProtocol.validName(name))}
        XCTAssertTrue(TransferProtocol.validName("đẹp.txt"))
        XCTAssertEqual(TransferProtocol.defaultChunkBytes,16384);XCTAssertEqual(TransferProtocol.maxChunkBytes,65536)
        XCTAssertThrowsError(try TransferProtocol.validate([]))
    }
    func testPrivateStageIntegrityAndCleanup() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=try TransferStore(directory:directory,metadata:TransferFile(name:"x",length:1),id:UUID())
        try store.append(chunk:0,offset:0,bytes:Data([1]))
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("x").path))
        XCTAssertThrowsError(try store.publish(length:1,digest:Data(count:32)))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:directory.path).isEmpty)
    }
    func testCancelDropsQueuedBulkButPreservesControl() async {
        let queue=DispatchQueue(label:"transfer-cancel-test"),done=expectation(description:"cancel boundary")
        var bytes:[UInt8]=[];var callbacks:[(NWError?)->Void]=[]
        let writer=ControlChannelWriter(queue:queue){data,_,callback in bytes.append(data[0]);callbacks.append(callback)}
        queue.async {
            writer.begin(generation:3);XCTAssertTrue(writer.enqueueBulk(Data([1])){_ in});XCTAssertTrue(writer.enqueueBulk(Data([2])){_ in});XCTAssertTrue(writer.enqueue(Data([9])))
            writer.cancelBulk();callbacks.removeFirst()(nil)
            queue.asyncAfter(deadline:.now()+0.02){XCTAssertEqual(bytes,[1,9]);callbacks.removeFirst()(nil);done.fulfill()}
        }
        await fulfillment(of:[done],timeout:2)
    }
    func testStoreBoundarySizesCollisionAndInvalidOffsets() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        for size in [0,1,15360,16384,16385,65536,65537,2*1024*1024] {
            let directory=root.appendingPathComponent(String(size)),bytes=Data(repeating:0x41,count:size)
            let store=try TransferStore(directory:directory,metadata:TransferFile(name:"đẹp.bin",length:UInt64(size)),id:UUID())
            var offset=0,chunk:UInt64=0
            while offset<size {let count=min(16384,size-offset);try store.append(chunk:chunk,offset:UInt64(offset),bytes:bytes.subdata(in:offset..<offset+count));offset+=count;chunk+=1}
            let final=try store.publish(length:UInt64(size),digest:Data(SHA256.hash(data:bytes)))
            XCTAssertEqual(try Data(contentsOf:final),bytes)
            let collision=try TransferStore(directory:directory,metadata:TransferFile(name:"đẹp.bin",length:0),id:UUID())
            XCTAssertNotEqual(try collision.publish(length:0,digest:Data(SHA256.hash(data:Data()))),final)
        }
        let store=try TransferStore(directory:root,metadata:TransferFile(name:"invalid",length:3),id:UUID())
        XCTAssertThrowsError(try store.append(chunk:1,offset:0,bytes:Data([1])))
        XCTAssertThrowsError(try store.append(chunk:0,offset:1,bytes:Data([1])))
        try store.append(chunk:0,offset:0,bytes:Data([1]))
        XCTAssertThrowsError(try store.append(chunk:0,offset:0,bytes:Data([1])))
        XCTAssertThrowsError(try store.publish(length:3,digest:Data(count:32)))
    }
    func testManagersSequentialBatchAndExplicitApproval() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("source.bin"),empty=root.appendingPathComponent("empty.bin")
        try Data(repeating:7,count:32769).write(to:source);try Data().write(to:empty)
        let completed=expectation(description:"batch ack"),approval=expectation(description:"explicit approval")
        var left:DataTransferManager!,right:DataTransferManager!
        left=DataTransferManager(generation:1,directory:root.appendingPathComponent("left")){packet,completion in
            if !right.post(packet,completion:{completion(true)}) {completion(false)}
        }
        right=DataTransferManager(generation:2,directory:root.appendingPathComponent("right")){packet,completion in
            if !left.post(packet,completion:{completion(true)}) {completion(false)}
        }
        right.changed={snapshot in if snapshot.phase == .awaitingDecision {approval.fulfill()}}
        left.changed={snapshot in if snapshot.phase == .completed {completed.fulfill()}}
        left.sendFiles([source,empty]);await fulfillment(of:[approval],timeout:3)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("right/source.bin").path))
        right.decide(true);await fulfillment(of:[completed],timeout:5)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("right/source.bin")),Data(repeating:7,count:32769))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("right/empty.bin")),Data())
        left.retire();right.retire()
    }
    func testWrongCancelIdentityCannotOwnReplacement() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let offered=expectation(description:"offer"),rejected=expectation(description:"reject")
        let manager=DataTransferManager(generation:9,directory:root){_,completion in completion(true)}
        manager.changed={snapshot in if snapshot.phase == .awaitingDecision {offered.fulfill()};if snapshot.phase == .rejected {rejected.fulfill()}}
        let id=UUID(),offer=TransferPacket(kind:.offer,generation:7,id:id,files:[TransferFile(name:"x",length:1)])
        XCTAssertTrue(manager.post(offer));await fulfillment(of:[offered],timeout:2)
        XCTAssertTrue(manager.owns(TransferPacket(kind:.cancel,generation:7,id:id)))
        XCTAssertFalse(manager.owns(TransferPacket(kind:.cancel,generation:7,id:UUID())))
        XCTAssertFalse(manager.owns(TransferPacket(kind:.cancel,generation:8,id:id)))
        manager.decide(false);await fulfillment(of:[rejected],timeout:2);manager.retire()
    }
    func testBulkYieldsToControl() async throws {
        let queue=DispatchQueue(label:"transfer-writer-test")
        let finished=expectation(description:"priority order")
        var order:[UInt8]=[];var callbacks:[(NWError?)->Void]=[]
        let writer=ControlChannelWriter(queue:queue){data,_,callback in order.append(data[0]);callbacks.append(callback)}
        queue.async {
            writer.begin(generation:1)
            XCTAssertTrue(writer.enqueueBulk(Data([1])){_ in})
            XCTAssertTrue(writer.enqueueBulk(Data([2])){_ in})
            XCTAssertTrue(writer.enqueue(Data([9])))
            callbacks.removeFirst()(nil)
            queue.asyncAfter(deadline:.now()+0.02){
                XCTAssertEqual(order,[1,9]);callbacks.removeFirst()(nil)
                queue.asyncAfter(deadline:.now()+0.02){XCTAssertEqual(order,[1,9,2]);callbacks.removeFirst()(nil);finished.fulfill()}
            }
        }
        await fulfillment(of:[finished],timeout:2)
    }

    func testCancelBulkCompletesQueuedBulkFailureExactlyOnceWithoutAffectingControl() async {
        let q = DispatchQueue(label: "F01.explicit-callbacks")
        let done = expectation(description: "active and control drained")
        var sent: [UInt8] = [], callbacks: [(NWError?) -> Void] = []
        var a = 0, b = 0, c = 0
        let writer = ControlChannelWriter(queue: q) { data, _, callback in
            sent.append(data[0]); callbacks.append(callback)
        }
        q.async {
            writer.begin(generation: 31)
            XCTAssertTrue(writer.enqueueBulk(Data([1])) { error in a += 1; XCTAssertNil(error) })
            XCTAssertTrue(writer.enqueueBulk(Data([2])) { error in b += 1; XCTAssertNotNil(error) })
            XCTAssertTrue(writer.enqueue(Data([9])) { error in c += 1; XCTAssertNil(error) })
            writer.cancelBulk(); writer.cancelBulk()
            XCTAssertEqual(b, 1, "Queued B must receive exactly one terminal failure")
            XCTAssertEqual(a, 0); XCTAssertEqual(c, 0); XCTAssertEqual(sent, [1])
            callbacks.removeFirst()(nil)
            q.async {
                XCTAssertEqual(a, 1); XCTAssertEqual(b, 1); XCTAssertEqual(sent, [1, 9])
                let control = callbacks.removeFirst(); control(nil); control(nil)
                q.async {
                    XCTAssertEqual(c, 1); XCTAssertEqual(b, 1)
                    writer.cancelBulk(); writer.cancel()
                    XCTAssertEqual(b, 1); done.fulfill()
                }
            }
        }
        await fulfillment(of: [done], timeout: 3)
    }

    func testCancelBulkPreservesActiveAndRejectsStaleGenerationCallback() async {
        let q = DispatchQueue(label: "F01.generation")
        let done = expectation(description: "replacement control")
        var callbacks: [(NWError?) -> Void] = [], sent: [UInt8] = []
        var active = 0, queued = 0, replacement = 0
        let writer = ControlChannelWriter(queue: q) { data, _, callback in sent.append(data[0]); callbacks.append(callback) }
        q.async {
            writer.begin(generation: 1)
            XCTAssertTrue(writer.enqueueBulk(Data([1])) { _ in active += 1 })
            writer.cancelBulk(); XCTAssertEqual(active, 0)
            XCTAssertTrue(writer.enqueueBulk(Data([2])) { error in queued += 1; XCTAssertNotNil(error) })
            writer.cancelBulk(); writer.cancel(); writer.begin(generation: 2)
            XCTAssertTrue(writer.enqueue(Data([9])) { _ in replacement += 1 })
            let old = callbacks.removeFirst(); old(.posix(.ECANCELED)); old(nil)
            q.async {
                XCTAssertEqual(sent, [1, 9]); XCTAssertEqual(active, 0); XCTAssertEqual(queued, 1)
                callbacks.removeFirst()(nil)
                q.async { XCTAssertEqual(replacement, 1); XCTAssertEqual(queued, 1); done.fulfill() }
            }
        }
        await fulfillment(of: [done], timeout: 3)
    }

    func testCancelBulkCallbackMayEnqueueReplacementWithoutLosingControl() async {
        let q = DispatchQueue(label: "F01.reentrant"), done = expectation(description: "replacement drained")
        var callbacks: [(NWError?) -> Void] = [], sent: [UInt8] = [], cancelled = 0
        let writer = ControlChannelWriter(queue: q) { data, _, callback in sent.append(data[0]); callbacks.append(callback) }
        q.async {
            writer.begin(generation: 1)
            XCTAssertTrue(writer.enqueueBulk(Data([1])) { _ in })
            XCTAssertTrue(writer.enqueueBulk(Data([2])) { error in
                cancelled += 1; XCTAssertNotNil(error)
                XCTAssertTrue(writer.enqueueBulk(Data([3])) { _ in })
            })
            XCTAssertTrue(writer.enqueue(Data([9])))
            writer.cancelBulk(); XCTAssertEqual(cancelled, 1)
            callbacks.removeFirst()(nil)
            q.async {
                XCTAssertEqual(sent, [1, 9]); callbacks.removeFirst()(nil)
                q.async {
                    XCTAssertEqual(sent, [1, 9, 3])
                    if !callbacks.isEmpty { callbacks.removeFirst()(nil) }
                    q.async { done.fulfill() }
                }
            }
        }
        await fulfillment(of: [done], timeout: 3)
    }

    #if targetEnvironment(simulator)
    func testBulkCancellationDoesNotRetireAuthenticatedSession() async {
        let network = NetworkManager(), session = network.simulateCommittedWifiSessionForTesting()
        defer { network.stopForTesting() }
        var sends: [UInt8] = [], callbacks: [(NWError?) -> Void] = []
        var active = 0, queued = 0, control = 0
        let done = expectation(description: "urgent control completes")
        network.controlSendForAudioTesting = { data, completion in sends.append(data[5]); callbacks.append(completion) }
        network.beginTransferWriterForTesting()
        network.enqueueTransferWireForTesting(bulk: true) { error in active += 1; XCTAssertNil(error) }
        network.enqueueTransferWireForTesting(bulk: true) { error in queued += 1; XCTAssertNotNil(error) }
        network.enqueueTransferWireForTesting(bulk: false) { error in control += 1; XCTAssertNil(error); done.fulfill() }
        network.networkQueueForTesting.sync {}
        network.cancelTransfer(); network.networkQueueForTesting.sync {}
        XCTAssertEqual(queued, 1); XCTAssertEqual(active, 0); XCTAssertEqual(control, 0)
        XCTAssertEqual(network.wifiLifecycleSnapshotForTesting().authenticatedGeneration, session.generation)
        network.networkQueueForTesting.sync { callbacks.removeFirst()(nil) }
        network.networkQueueForTesting.sync {}
        XCTAssertEqual(sends, [WireMessageType.transferEnd.rawValue, WireMessageType.ping.rawValue])
        network.networkQueueForTesting.sync { if !callbacks.isEmpty { callbacks.removeFirst()(nil) } }
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(active, 1); XCTAssertEqual(queued, 1); XCTAssertEqual(control, 1)
        XCTAssertEqual(network.wifiSessionSnapshotForTesting().generation, session.generation)
    }

    func testRealManagerSaturationFailsTransferClosedAndRearmsOnce() async throws {
        let network = NetworkManager(), session = network.simulateCommittedWifiSessionForTesting()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = DataTransferManager(generation: session.generation, directory: root) { _, completion in completion(true) }
        let blocked = expectation(description: "first accepted offer held"), rearmed = expectation(description: "accepted work releases receive"), failed = expectation(description: "overflow fails transfer closed")
        let release = DispatchSemaphore(value: 0)
        manager.changed = { snapshot in
            if snapshot.phase == .awaitingDecision { blocked.fulfill(); release.wait() }
            if snapshot.phase == .failed { failed.fulfill() }
        }
        var reads: [(Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void] = [], arms = 0
        network.transferReceiveForTesting = { _, callback in
            arms += 1; reads.append(callback); XCTAssertEqual(reads.count, 1)
            if arms == 2 { rearmed.fulfill() }
        }
        defer { network.stopForTesting(); manager.retire(); try? FileManager.default.removeItem(at: root) }
        network.startTransferReceiveForTesting(manager: manager)
        var bytes = Data()
        for _ in 0..<3 {
            let offer = TransferPacket(kind: .offer, generation: 7, id: UUID(), files: [TransferFile(name: "x", length: 0)])
            bytes.append(transferTestFrame(.transferOffer, try TransferProtocol.encode(offer)))
        }
        network.networkQueueForTesting.sync { reads.removeFirst()(bytes, nil, false, nil) }
        await fulfillment(of: [blocked], timeout: 3)
        XCTAssertEqual(network.transferPendingForTesting, 2); XCTAssertTrue(reads.isEmpty); XCTAssertEqual(arms, 1)
        release.signal()
        await fulfillment(of: [rearmed, failed], timeout: 3)
        network.networkQueueForTesting.sync {}
        XCTAssertEqual(network.transferPendingForTesting, 0); XCTAssertEqual(arms, 2); XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(network.wifiLifecycleSnapshotForTesting().authenticatedGeneration, session.generation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("x").path))
    }

    private func transferTestFrame(_ type: WireMessageType, _ payload: Data) -> Data {
        var frame = Data("SCST".utf8); frame.append(contentsOf: [1, type.rawValue, 0, 0])
        var size = UInt32(payload.count).littleEndian, sequence = UInt32(1).littleEndian
        withUnsafeBytes(of: &size) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: &sequence) { frame.append(contentsOf: $0) }
        frame.append(payload); return frame
    }

    func testRejectedTransferAdmissionRearmsAuthenticatedReceiveOrRetiresExplicitly() throws {
        let network = NetworkManager(), session = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = DataTransferManager(generation: session.generation, directory: root) { _, completion in completion(true) }
        defer { network.stopForTesting(); manager.retire(); try? FileManager.default.removeItem(at: root) }
        var reads: [(Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void] = []
        var arms = 0, posts = 0, pongs = 0
        network.transferReceiveForTesting = { _, callback in arms += 1; reads.append(callback); XCTAssertEqual(reads.count, 1) }
        network.transferPostForTesting = { _, _ in posts += 1; return false }
        network.controlSendForAudioTesting = { data, completion in
            if data.count >= 16 && data[5] == WireMessageType.pong.rawValue { pongs += 1 }
            completion(nil)
        }
        network.startTransferReceiveForTesting(manager: manager)
        let packet = TransferPacket(kind: .end, generation: 7, id: UUID())
        let transfer = transferTestFrame(.transferEnd, try TransferProtocol.encode(packet))
        let ping = transferTestFrame(.ping, Data(count: 16))
        // Repeated synchronous refusal must return to the outer receive boundary,
        // with one outstanding read, without recursive parser entry or extra queues.
        for _ in 0..<16 {
            network.networkQueueForTesting.sync { reads.removeFirst()(transfer + ping, nil, false, nil) }
            network.networkQueueForTesting.sync {}
            XCTAssertEqual(network.transferPendingForTesting, 0)
        }
        XCTAssertEqual(posts, 16); XCTAssertEqual(arms, 17); XCTAssertEqual(reads.count, 1); XCTAssertEqual(pongs, 16)
        // A captured old receive callback must not dispatch into a replacement owner.
        let stale = reads.removeFirst()
        _ = network.simulateCommittedWifiSessionForTesting()
        network.networkQueueForTesting.sync { stale(transfer, nil, false, nil) }
        XCTAssertEqual(posts, 16); XCTAssertEqual(arms, 17)
    }

    func testTransferAdmissionAcceptedThenRefusedWaitsForExactlyOneOwnerCompletion() throws {
        let network = NetworkManager(), session = network.simulateCommittedWifiSessionForTesting(mode: RealtimeTransportMode.legacyTLS)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = DataTransferManager(generation: session.generation, directory: root) { _, completion in completion(true) }
        defer { network.stopForTesting(); manager.retire(); try? FileManager.default.removeItem(at: root) }
        var reads: [(Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void] = [], finishes: [() -> Void] = []
        var posts = 0, arms = 0
        network.transferReceiveForTesting = { _, callback in arms += 1; reads.append(callback); XCTAssertEqual(reads.count, 1) }
        network.transferPostForTesting = { _, completion in
            posts += 1
            if posts == 1 { finishes.append(completion); return true }
            return false
        }
        network.startTransferReceiveForTesting(manager: manager)
        let frame = transferTestFrame(.transferEnd, try TransferProtocol.encode(TransferPacket(kind: .end, generation: 7, id: UUID())))
        network.networkQueueForTesting.sync { reads.removeFirst()(frame + frame, nil, false, nil) }
        XCTAssertEqual(posts, 2); XCTAssertEqual(arms, 1); XCTAssertTrue(reads.isEmpty); XCTAssertEqual(network.transferPendingForTesting, 1)
        finishes.removeFirst()(); network.networkQueueForTesting.sync {}
        XCTAssertEqual(arms, 2); XCTAssertEqual(reads.count, 1); XCTAssertEqual(network.transferPendingForTesting, 0)
        // Hold an accepted completion, reconnect, then release it: no stale rearm.
        posts = 0
        network.networkQueueForTesting.sync { reads.removeFirst()(frame, nil, false, nil) }
        XCTAssertEqual(network.transferPendingForTesting, 1)
        _ = network.simulateCommittedWifiSessionForTesting()
        finishes.removeFirst()(); network.networkQueueForTesting.sync {}
        XCTAssertEqual(arms, 2); XCTAssertTrue(reads.isEmpty)
    }

    func testTransferAdmissionWithoutManagerOrAuthenticationHasNoSideEffects() throws {
        let network = NetworkManager(), session = network.simulateCommittedWifiSessionForTesting()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = DataTransferManager(generation: session.generation, directory: root) { _, _ in XCTFail("No transfer side effects allowed") }
        defer { network.stopForTesting(); manager.retire(); try? FileManager.default.removeItem(at: root) }
        var reads: [(Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void] = [], posts = 0
        network.transferReceiveForTesting = { _, callback in reads.append(callback) }
        network.transferPostForTesting = { _, _ in posts += 1; return false }
        let frame = transferTestFrame(.transferEnd, try TransferProtocol.encode(TransferPacket(kind: .end, generation: 7, id: UUID())))
        network.startTransferReceiveForTesting(manager: nil)
        network.networkQueueForTesting.sync { reads.removeFirst()(frame, nil, false, nil) }
        XCTAssertEqual(posts, 0); XCTAssertEqual(reads.count, 1)
        reads.removeAll()
        network.startTransferReceiveForTesting(manager: manager, authenticated: false)
        network.networkQueueForTesting.sync { reads.removeFirst()(frame, nil, false, nil) }
        XCTAssertEqual(posts, 0); XCTAssertEqual(network.transferPendingForTesting, 0)
    }
    #endif

}
