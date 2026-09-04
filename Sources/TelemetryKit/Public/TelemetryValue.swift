import CoreFoundation
import Foundation

/// A strongly typed value that can be attached to a telemetry event.
///
/// TelemetryKit deliberately does not accept arbitrary Swift values. Keeping the
/// payload model small makes encoding deterministic and prevents accidental
/// persistence of objects that were never intended to leave the process.
public indirect enum TelemetryValue: Sendable, Equatable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case boolean(Bool)
    case array([TelemetryValue])
    case object([String: TelemetryValue])
    case null
}

extension TelemetryValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum ValueType: String, Codable {
        case string
        case integer
        case double
        case boolean
        case array
        case object
        case null
    }

    public init(from decoder: Decoder) throws {
        // TelemetryKit writes a tagged representation so an explicitly supplied
        // `.double(1.0)` cannot silently become `.integer(1)` on a round trip.
        // The scalar fallback keeps payloads produced by pre-1.0 prototypes and
        // ordinary JSON decoders readable during migration.
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
            let type = try? container.decode(ValueType.self, forKey: .type)
        {
            switch type {
            case .string:
                self = .string(try container.decode(String.self, forKey: .value))
            case .integer:
                self = .integer(try container.decode(Int64.self, forKey: .value))
            case .double:
                self = .double(try container.decode(Double.self, forKey: .value))
            case .boolean:
                self = .boolean(try container.decode(Bool.self, forKey: .value))
            case .array:
                self = .array(try container.decode([TelemetryValue].self, forKey: .value))
            case .object:
                self = .object(
                    try container.decode([String: TelemetryValue].self, forKey: .value)
                )
            case .null:
                self = .null
            }
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([TelemetryValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: TelemetryValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .string(let value):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(value, forKey: .value)
        case .integer(let value):
            try container.encode(ValueType.integer, forKey: .type)
            try container.encode(value, forKey: .value)
        case .double(let value):
            try container.encode(ValueType.double, forKey: .type)
            try container.encode(value, forKey: .value)
        case .boolean(let value):
            try container.encode(ValueType.boolean, forKey: .type)
            try container.encode(value, forKey: .value)
        case .array(let value):
            try container.encode(ValueType.array, forKey: .type)
            try container.encode(value, forKey: .value)
        case .object(let value):
            try container.encode(ValueType.object, forKey: .type)
            try container.encode(value, forKey: .value)
        case .null:
            try container.encode(ValueType.null, forKey: .type)
        }
    }
}

extension TelemetryValue {
    /// Converts values accepted at an Objective-C boundary into a typed value.
    internal init?(foundationValue: Any, depth: Int = 0) {
        var remainingValueCount = 1_024
        guard
            let value = Self.convertFoundationValue(
                foundationValue,
                depth: depth,
                remainingValueCount: &remainingValueCount
            )
        else {
            return nil
        }
        self = value
    }

    private static func convertFoundationValue(
        _ foundationValue: Any,
        depth: Int,
        remainingValueCount: inout Int
    ) -> TelemetryValue? {
        guard depth <= 10, remainingValueCount > 0 else { return nil }
        remainingValueCount -= 1

        switch foundationValue {
        case is NSNull:
            return .null
        case let value as NSString:
            return .string(value as String)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .boolean(value.boolValue)
            } else if let encoding = String(cString: value.objCType).first,
                "csilqCSILQ".contains(encoding)
            {
                if encoding.isUppercase,
                    value.uint64Value > UInt64(Int64.max)
                {
                    return nil
                }
                return .integer(value.int64Value)
            } else {
                guard value.doubleValue.isFinite else { return nil }
                return .double(value.doubleValue)
            }
        case let value as [Any]:
            guard value.count <= remainingValueCount else { return nil }
            var converted: [TelemetryValue] = []
            converted.reserveCapacity(min(value.count, remainingValueCount))
            for item in value {
                guard
                    let item = convertFoundationValue(
                        item,
                        depth: depth + 1,
                        remainingValueCount: &remainingValueCount
                    )
                else {
                    return nil
                }
                converted.append(item)
            }
            return .array(converted)
        case let value as [String: Any]:
            guard value.count <= remainingValueCount else { return nil }
            var converted: [String: TelemetryValue] = [:]
            converted.reserveCapacity(min(value.count, remainingValueCount))
            for (key, item) in value {
                guard
                    let item = convertFoundationValue(
                        item,
                        depth: depth + 1,
                        remainingValueCount: &remainingValueCount
                    )
                else {
                    return nil
                }
                converted[key] = item
            }
            return .object(converted)
        default:
            return nil
        }
    }
}
