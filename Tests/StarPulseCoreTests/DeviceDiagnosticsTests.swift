import Foundation
import Testing
@testable import StarPulseCore

@Suite struct DeviceDiagnosticsTests {
    /// Response{dish_get_diagnostics 6001{hardware_self_test 7}}, as a live dish answers (firmware 2026.11.12).
    @Test func dishSelfTest() throws {
        var writer = ProtoWriter()
        writer.writeMessage(6001) { $0.writeVarint(7, 1) }
        #expect(try DeviceDiagnostics.selfTest(response: writer.bytes) == .passed)

        var failed = ProtoWriter()
        failed.writeMessage(6001) { $0.writeVarint(7, 2) }
        #expect(try DeviceDiagnostics.selfTest(response: failed.bytes) == .failed)
    }

    @Test func dishWithoutResult() throws {
        var writer = ProtoWriter()
        writer.writeMessage(6001) { $0.writeVarint(4, 28800) }
        #expect(try DeviceDiagnostics.selfTest(response: writer.bytes) == .noResult)
        #expect(try DeviceDiagnostics.selfTest(response: []) == nil)
    }

    /// Response{wifi_get_diagnostics 6000{networks 4{clients_ethernet 10, clients_2ghz 11, clients_5ghz 12}}}.
    @Test func routerClientsAddUpAcrossNetworks() throws {
        var writer = ProtoWriter()
        writer.writeMessage(6000) { body in
            body.writeMessage(4) { $0.writeVarint(11, 4); $0.writeVarint(12, 3) }
            body.writeMessage(4) { $0.writeVarint(10, 1); $0.writeVarint(12, 2) }
        }
        let counts = try #require(try DeviceDiagnostics.clientCounts(response: writer.bytes))
        #expect(counts == .init(ethernet: 1, band2GHz: 4, band5GHz: 5))
        #expect(try DeviceDiagnostics.clientCounts(response: []) == nil)
    }

    @Test func hugeCountsDoNotTrap() throws {
        var writer = ProtoWriter()
        writer.writeMessage(6000) { body in
            for _ in 0..<3 { body.writeMessage(4) { $0.writeVarint(11, .max) } }
        }
        #expect(try DeviceDiagnostics.clientCounts(response: writer.bytes)?.band2GHz == 30_000)
    }
}
