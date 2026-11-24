import Foundation

public enum ProtoError: Error, Equatable {
    case truncated
    case malformedVarint
    case unsupportedWireType(Int)
}

public enum WireType: Int {
    case varint = 0, fixed64 = 1, lengthDelimited = 2, fixed32 = 5
}

/// Minimal protobuf wire-format reader. Only what the dish messages need; field
/// numbers come from the device's own reflection dump (schema/dish.protoset).
public struct ProtoReader {
    private let bytes: [UInt8]
    private var index = 0

    public init(_ bytes: [UInt8]) { self.bytes = bytes }
    public init(_ data: Data) { self.bytes = [UInt8](data) }

    public var isAtEnd: Bool { index >= bytes.count }
    public var position: Int { index }

    /// Every top-level field with its exact encoded bytes (key and value), so unchanged fields can be resent verbatim.
    public static func rawFields(_ bytes: [UInt8]) throws -> [(number: Int, wire: WireType, raw: [UInt8], reader: ProtoReader)] {
        var reader = ProtoReader(bytes)
        var fields: [(number: Int, wire: WireType, raw: [UInt8], reader: ProtoReader)] = []
        while true {
            let start = reader.position
            guard let (number, wire) = try reader.nextField() else { break }
            let valueReader = reader
            try reader.skip(wire)
            fields.append((number, wire, Array(bytes[start..<reader.position]), valueReader))
        }
        return fields
    }

    public mutating func nextField() throws -> (number: Int, wire: WireType)? {
        guard !isAtEnd else { return nil }
        let key = try readVarint()
        let rawWire = Int(key & 7)
        guard let wire = WireType(rawValue: rawWire) else { throw ProtoError.unsupportedWireType(rawWire) }
        return (Int(key >> 3), wire)
    }

    public mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < bytes.count else { throw ProtoError.truncated }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte < 0x80 { return result }
            shift += 7
            if shift > 63 { throw ProtoError.malformedVarint }
        }
    }

    public mutating func readLengthDelimited() throws -> [UInt8] {
        let length = Int(try readVarint())
        guard length >= 0, index + length <= bytes.count else { throw ProtoError.truncated }
        defer { index += length }
        return Array(bytes[index..<index + length])
    }

    public mutating func readFloat() throws -> Float {
        Float(bitPattern: UInt32(truncatingIfNeeded: try readFixed(byteCount: 4)))
    }

    public mutating func readFixed(byteCount: Int) throws -> UInt64 {
        guard index + byteCount <= bytes.count else { throw ProtoError.truncated }
        var value: UInt64 = 0
        for offset in 0..<byteCount { value |= UInt64(bytes[index + offset]) << (8 * UInt64(offset)) }
        index += byteCount
        return value
    }

    public mutating func skip(_ wire: WireType) throws {
        switch wire {
        case .varint: _ = try readVarint()
        case .fixed64: _ = try readFixed(byteCount: 8)
        case .fixed32: _ = try readFixed(byteCount: 4)
        case .lengthDelimited: _ = try readLengthDelimited()
        }
    }

    /// proto3 packs repeated floats into one length-delimited field; older
    /// encoders emit one fixed32 per element. Accept both.
    public mutating func appendFloats(wire: WireType, to array: inout [Float]) throws {
        switch wire {
        case .lengthDelimited:
            var packed = ProtoReader(try readLengthDelimited())
            while !packed.isAtEnd { array.append(try packed.readFloat()) }
        case .fixed32:
            array.append(try readFloat())
        default:
            throw ProtoError.unsupportedWireType(wire.rawValue)
        }
    }
}

/// Minimal writer, used to build requests and by tests to synthesize responses.
public struct ProtoWriter {
    public private(set) var bytes: [UInt8] = []
    public init() {}

    /// Appends already-encoded fields untouched.
    public mutating func writeRaw(_ raw: [UInt8]) { bytes.append(contentsOf: raw) }

    public mutating func varint(_ value: UInt64) {
        var remaining = value
        while remaining >= 0x80 {
            bytes.append(UInt8(remaining & 0x7f) | 0x80)
            remaining >>= 7
        }
        bytes.append(UInt8(remaining))
    }

    private mutating func key(_ number: Int, _ wire: WireType) { varint(UInt64(number << 3 | wire.rawValue)) }

    public mutating func writeVarint(_ number: Int, _ value: UInt64) {
        key(number, .varint); varint(value)
    }

    public mutating func writeBool(_ number: Int, _ value: Bool) { writeVarint(number, value ? 1 : 0) }

    public mutating func writeFloat(_ number: Int, _ value: Float) {
        key(number, .fixed32)
        var bits = value.bitPattern
        for _ in 0..<4 { bytes.append(UInt8(bits & 0xff)); bits >>= 8 }
    }

    public mutating func writeBytes(_ number: Int, _ payload: [UInt8]) {
        key(number, .lengthDelimited); varint(UInt64(payload.count)); bytes.append(contentsOf: payload)
    }

    public mutating func writeString(_ number: Int, _ value: String) { writeBytes(number, Array(value.utf8)) }

    public mutating func writePackedFloats(_ number: Int, _ values: [Float]) {
        var packed = ProtoWriter()
        for value in values {
            var bits = value.bitPattern
            for _ in 0..<4 { packed.bytes.append(UInt8(bits & 0xff)); bits >>= 8 }
        }
        writeBytes(number, packed.bytes)
    }

    public mutating func writeMessage(_ number: Int, _ build: (inout ProtoWriter) -> Void) {
        var nested = ProtoWriter()
        build(&nested)
        writeBytes(number, nested.bytes)
    }
}
