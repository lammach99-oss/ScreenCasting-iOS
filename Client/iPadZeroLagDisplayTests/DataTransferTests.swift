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
