import Foundation
import Testing
@testable import StarPulseCore

@Test func maintenanceCloudRequestTargetsTheDish() throws {
    var expected = ProtoWriter()
    expected.writeBytes(13, Array("ut0158168c-42207c02-5946ca71".utf8))
    expected.writeBytes(1001, [])
    #expect(try DishMaintenance.reboot.cloudRequest(dishId: "ut0158168c-42207c02-5946ca71") == expected.bytes)
    #expect(throws: PauseError.invalidTarget) { try DishMaintenance.reboot.cloudRequest(dishId: "Router-010000000000000001B31340") }
    #expect(throws: PauseError.invalidTarget) { try DishMaintenance.clearObstructionMap.cloudRequest(dishId: "") }
}

@Test func maintenanceTriesTheLanFirst() async throws {
    let cloudCalls = Counter()
    let route = try await DishMaintenance.run(local: {}, cloud: { cloudCalls.add() })
    #expect(route == .lan)
    #expect(cloudCalls.value == 0)
}

// Current firmware refuses LAN writes with gRPC status 7; Starlink's cloud then carries the request.
@Test func maintenanceFallsBackToTheCloudWhenTheDishRefuses() async throws {
    let cloudCalls = Counter()
    let refused = { @Sendable () async throws in throw GrpcWebError(status: 7, message: "permission denied") }
    #expect(try await DishMaintenance.run(local: refused, cloud: { cloudCalls.add() }) == .cloud)
    #expect(cloudCalls.value == 1)
    await #expect(throws: DishMaintenance.Failure.signInNeeded) { try await DishMaintenance.run(local: refused, cloud: nil) }
    let unreachable = { @Sendable () async throws in throw URLError(.timedOut) }
    await #expect(throws: URLError.self) { try await DishMaintenance.run(local: unreachable, cloud: { cloudCalls.add() }) }
    #expect(cloudCalls.value == 1)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

@Test func accountDishesComeFromTheTelemetry() {
    let telemetry: [String: Any] = ["data": [
        "columnNamesByDeviceType": ["r": ["DeviceType", "DeviceId"], "u": ["DeviceType", "DeviceId"]],
        "values": [["u", "ut0158168c-42207c02-5946ca71"], ["r", "Router-main"]],
    ]]
    #expect(StarlinkCloud.dishIds(fromTelemetry: telemetry) == ["ut0158168c-42207c02-5946ca71"])
    #expect(StarlinkCloud.dishIds(fromTelemetry: ["data": [:]]).isEmpty)
}

// Same rule as the router: the dish that answered on the LAN must be one on the account.
@Test func maintenanceRequiresTheLanDishToBeOnTheAccount() throws {
    let account = ["ut0158168c-42207c02-5946ca71"]
    #expect(try StarlinkCloud.requireAccountDish(lan: "ut0158168c-42207c02-5946CA71", account: account) == "ut0158168c-42207c02-5946ca71")
    #expect(throws: PauseError.otherDish) { try StarlinkCloud.requireAccountDish(lan: "ut00000000-00000000-00000000", account: account) }
    #expect(throws: PauseError.otherDish) { try StarlinkCloud.requireAccountDish(lan: "", account: account) }
}
