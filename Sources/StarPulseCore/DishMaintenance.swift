import Foundation

/// Dish maintenance requests; field numbers from Dishylink's schema/dish.protoset.
public enum DishMaintenance: Int, Sendable {
    case reboot = 1001
    case clearObstructionMap = 2017

    public enum Route: Sendable, Equatable { case lan, cloud }

    public enum Failure: Error, Equatable, LocalizedError {
        case signInNeeded
        public var errorDescription: String? {
            "The dish refused the request over the local network. Sign in to your Starlink account so StarPulse can send it through Starlink."
        }
    }

    /// Request{target_id 13, <action> {}} for Starlink's cloud gateway, addressed to the dish ("ut…").
    public func cloudRequest(dishId: String) throws -> [UInt8] {
        guard dishId.hasPrefix("ut"), dishId.count > 2 else { throw PauseError.invalidTarget }
        var writer = ProtoWriter()
        writer.writeBytes(13, Array(dishId.utf8))
        writer.writeBytes(rawValue, [])
        return writer.bytes
    }

    /// Sends over the LAN first. Current firmware refuses LAN writes with gRPC status 7
    /// (Dishylink LOCAL-API.md), and then the signed-in cloud path carries the same request.
    public static func run(local: @Sendable () async throws -> Void, cloud: (@Sendable () async throws -> Void)?) async throws -> Route {
        do {
            try await local()
            return .lan
        } catch let error as GrpcWebError where error.status == 7 {
            guard let cloud else { throw Failure.signInNeeded }
            try await cloud()
            return .cloud
        }
    }
}

extension DishClient {
    public func perform(_ action: DishMaintenance) async throws {
        _ = try await LocalGrpc.call(url: url, field: action.rawValue, transport: transport)
    }
}
