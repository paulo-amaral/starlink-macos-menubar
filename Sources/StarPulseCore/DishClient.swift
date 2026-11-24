import Foundation

public protocol DishDataSource: Sendable {
    func status() async throws -> DishStatus
    func history() async throws -> DishHistory
    func obstructionMap() async throws -> ObstructionMap
    func config() async throws -> DishConfig
}

/// Talks to the dish over the LAN. Endpoint from Dishylink core/dishClient.ts.
public struct DishClient: DishDataSource {
    public static let defaultURL = URL(string: "http://192.168.100.1:9201/SpaceX.API.Device.Device/Handle")!

    let url: URL
    let transport: HTTPTransport
    private let now: @Sendable () -> Date

    public init(url: URL = DishClient.defaultURL, transport: HTTPTransport = .live, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.transport = transport
        self.now = now
    }

    private func call(getHistory: Bool) async throws -> [UInt8] {
        try await LocalGrpc.call(url: url, field: getHistory ? DishDecoder.Request.getHistory : DishDecoder.Request.getStatus, transport: transport)
    }

    public func status() async throws -> DishStatus {
        try DishDecoder.decodeStatus(response: try await call(getHistory: false))
    }

    public func obstructionMap() async throws -> ObstructionMap {
        try DishDecoder.decodeObstructionMap(response: try await LocalGrpc.call(url: url, field: DishDecoder.Request.obstructionMap, transport: transport))
    }

    public func config() async throws -> DishConfig {
        try DishDecoder.decodeConfig(response: try await LocalGrpc.call(url: url, field: DishDecoder.ConfigRequest.dishGetConfig, transport: transport))
    }

    public func history() async throws -> DishHistory {
        try DishDecoder.decodeHistory(response: try await call(getHistory: true), now: now())
    }
}

/// One unary gRPC-web call to the dish or the router; both speak the same Device/Handle service.
enum LocalGrpc {
    static func call(url: URL, field: Int, transport: HTTPTransport) async throws -> [UInt8] {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Grpc-Web")
        request.httpBody = GrpcWeb.encodeFrame(DishDecoder.requestBytes(field: field))
        let (data, http) = try await transport.send(request)
        let headerStatus = http.value(forHTTPHeaderField: "grpc-status").flatMap(Int.init)
        if headerStatus == nil, !(200..<300).contains(http.statusCode) {
            throw GrpcWebError(status: http.statusCode == 401 || http.statusCode == 403 ? 16 : 2, message: "HTTP \(http.statusCode)")
        }
        return try GrpcWeb.decodeResponse(body: data, headerStatus: headerStatus, headerMessage: http.value(forHTTPHeaderField: "grpc-message"))
    }
}
