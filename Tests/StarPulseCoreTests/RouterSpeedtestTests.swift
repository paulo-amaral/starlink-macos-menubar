import Foundation
import Testing
@testable import StarPulseCore

@Suite struct RouterSpeedtestTests {
    func packed(_ values: [Float]) -> [UInt8] { values.flatMap { withUnsafeBytes(of: $0.bitPattern.littleEndian, Array.init) } }

    /// Response{get_speedtest_status 1028{status 1{...}}}, the shape seen on a live router (firmware 2026.11.09).
    func response(_ build: (inout ProtoWriter) -> Void) -> [UInt8] {
        var writer = ProtoWriter()
        writer.writeMessage(1028) { $0.writeMessage(1, build) }
        return writer.bytes
    }

    @Test func finishedRunDecodes() throws {
        let bytes = response { s in
            s.writeVarint(2, 2_235_520_252)
            s.writeMessage(1001) { $0.writeBytes(1, packed([10, 20, 30])) }
            s.writeMessage(1000) { $0.writeBytes(1, packed([4, 6])) }
        }
        let test = try RouterSpeedtest.decode(response: bytes)
        #expect(!test.running)
        #expect(test.id == 2_235_520_252)
        #expect(test.downloadMbps == [10, 20, 30])
        #expect(RouterSpeedtest.average(test.downloadMbps) == 20)
        #expect(RouterSpeedtest.average(test.uploadMbps) == 5)
        #expect(!test.failed)
    }

    @Test func runningDownloadOnly() throws {
        let test = try RouterSpeedtest.decode(response: response { s in
            s.writeBool(1, true)
            s.writeMessage(1001) { $0.writeBytes(1, packed([1.5])) }
            s.writeMessage(1000) { _ in }
        })
        #expect(test.running && test.uploadMbps.isEmpty && test.downloadMbps == [1.5])
        #expect(RouterSpeedtest.average([]) == nil)
    }

    @Test func errorIsFlagged() throws {
        let test = try RouterSpeedtest.decode(response: response { s in s.writeMessage(1001) { $0.writeVarint(2, 3) } })
        #expect(test.failed)
    }
}
