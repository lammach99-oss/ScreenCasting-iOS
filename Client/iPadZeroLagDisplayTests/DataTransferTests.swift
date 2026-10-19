import Network
import XCTest
import Foundation
@testable import iPadCasting

final class DataTransferTests: XCTestCase {
    func testCanonicalEnvelopeAndAllTruncationPoints() throws {
        let id=UUID(uuidString:"00112233-4455-6677-8899-AABBCCDDEEFF")!
        let p=TransferPacket(kind:.end,generation:0x0807060504030201,id:id)
        let bytes=try TransferProtocol.encode(p)
        XCTAssertEqual(bytes.map{String(format:"%02X",$0)}.joined(),"01010203040506070800112233445566778899AABBCCDDEEFF")
        for cut in 0..<bytes.count {XCTAssertThrowsError(try TransferProtocol.decode(.end,bytes.prefix(cut)))}
        XCTAssertThrowsError(try TransferProtocol.decode(.end,bytes+Data([0])))
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
}
