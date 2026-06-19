import XCTest
import Foundation
@testable import RustCore

/// TSK-988: RemoteTransport's framed IO must RETRY on EINTR (a signal
/// interrupting a blocking read/write), not treat the -1/EINTR return as a
/// fatal connection error. `readFull` is the extracted, injectable retry loop;
/// `writeEnvelope` applies the same one-line `errno == EINTR → continue` guard.
final class RemoteTransportEINTRTests: XCTestCase {

    func test_readFull_retriesOnEINTR() throws {
        var calls = 0
        let out = try RemoteTransport.readFull(4) { buf in
            calls += 1
            if calls == 1 { errno = EINTR; return -1 }   // first read interrupted
            for i in 0..<buf.count { buf[i] = 0xAB }
            return buf.count
        }
        XCTAssertEqual(calls, 2, "EINTR must be retried, not thrown")
        XCTAssertEqual(out, [0xAB, 0xAB, 0xAB, 0xAB])
    }

    func test_readFull_partialReadsAccumulateAcrossEINTR() throws {
        var calls = 0
        let out = try RemoteTransport.readFull(3) { buf in
            calls += 1
            switch calls {
            case 1: buf[0] = 1; return 1                              // 1 byte
            case 2: errno = EINTR; return -1                         // interrupted
            default: for i in 0..<buf.count { buf[i] = 9 }; return buf.count
            }
        }
        XCTAssertEqual(out, [1, 9, 9])
        XCTAssertEqual(calls, 3)
    }

    func test_readFull_nonEINTRError_throws() {
        XCTAssertThrowsError(try RemoteTransport.readFull(4) { _ in errno = EIO; return -1 })
    }

    func test_readFull_eof_throws() {
        XCTAssertThrowsError(try RemoteTransport.readFull(4) { _ in 0 })
    }
}
