import Foundation

// grpc-web unary framing: 1 flag byte (0x00 message, 0x80 trailers) + 4-byte
// big-endian length + payload. Ported from Dishylink core/grpcWeb.ts (MIT).

public struct GrpcWebError: Error, Equatable, LocalizedError {
    public let status: Int
    public let message: String
    public var errorDescription: String? { "gRPC status \(status): \(message)" }
}

public enum GrpcWeb {
    private static let messageFlag: UInt8 = 0x00
    private static let trailersFlag: UInt8 = 0x80

    public static func encodeFrame(_ message: [UInt8]) -> Data {
        var frame = Data([messageFlag])
        withUnsafeBytes(of: UInt32(message.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(contentsOf: message)
        return frame
    }

    static func parseTrailers(_ text: String) -> (status: Int, message: String) {
        var status = 0
        var message = ""
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "grpc-status" { status = Int(value) ?? 2 }
            if name == "grpc-message" { message = value.removingPercentEncoding ?? value }
        }
        return (status, message)
    }

    /// Returns the single response message, throwing on a non-zero gRPC status.
    public static func decodeResponse(body: Data, headerStatus: Int?, headerMessage: String?) throws -> [UInt8] {
        // Trailers-only responses carry the status in HTTP headers with no body.
        if let headerStatus, headerStatus != 0 {
            throw GrpcWebError(status: headerStatus, message: headerMessage ?? "unknown error")
        }
        let bytes = [UInt8](body)
        var offset = 0
        var message: [UInt8]?
        while offset + 5 <= bytes.count {
            let flag = bytes[offset]
            let length = bytes[offset + 1..<offset + 5].reduce(0) { $0 << 8 | Int($1) }
            guard offset + 5 + length <= bytes.count else { throw ProtoError.truncated }
            let payload = Array(bytes[offset + 5..<offset + 5 + length])
            offset += 5 + length
            if flag & trailersFlag != 0 {
                let trailers = parseTrailers(String(decoding: payload, as: UTF8.self))
                if trailers.status != 0 { throw GrpcWebError(status: trailers.status, message: trailers.message) }
            } else {
                message = payload
            }
        }
        guard let message else { throw GrpcWebError(status: 2, message: "response contained no message frame") }
        return message
    }
}

/// Injectable HTTP layer so the client can be tested without a dish.
public struct HTTPTransport: Sendable {
    public var send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public init(send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.send = send
    }

    public static let live = HTTPTransport { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

extension HTTPTransport {
    private static let cloudSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // The Cookie header is set by hand from the Keychain; the system jar must
        // neither add to it nor learn the account session.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    /// For starlink.com: no shared cookie storage.
    public static let cloud = HTTPTransport { request in
        let (data, response) = try await cloudSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
