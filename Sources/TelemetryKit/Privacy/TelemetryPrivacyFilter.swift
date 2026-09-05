import Foundation

/// A deterministic, side-effect-free privacy pass applied before encoding.
internal struct TelemetryPrivacyFilter: Sendable {
    private struct KeyCandidate {
        let normalized: String
        let original: String
    }

    private struct SanitizationBudget {
        var remainingNodes: Int
        var remainingUTF8Bytes: Int

        mutating func consumeNode() -> Bool {
            guard remainingNodes > 0 else { return false }
            remainingNodes -= 1
            return true
        }

        mutating func consume(_ string: String) -> Bool {
            let count = string.utf8.count
            guard count <= remainingUTF8Bytes else { return false }
            remainingUTF8Bytes -= count
            return true
        }
    }

    private static let redactedMarker = "[REDACTED]"
    private static let maximumRedactionKeyCount = 128
    private static let maximumRedactionKeyBytes = 256

    private let configuration: TelemetryPrivacyConfiguration
    private let normalizedRedactedKeys: Set<String>
    private let maximumOutputBytes: Int
    private let maximumNodeCount: Int

    internal init(
        configuration: TelemetryPrivacyConfiguration,
        maximumOutputBytes: Int = 64 * 1_024
    ) {
        self.configuration = configuration
        self.maximumOutputBytes = max(1, maximumOutputBytes)
        self.maximumNodeCount = min(4_096, max(32, maximumOutputBytes / 24))
        self.normalizedRedactedKeys = Set(
            configuration.redactedAttributeKeys
                .lazy
                .filter { $0.utf8.count <= Self.maximumRedactionKeyBytes }
                .prefix(Self.maximumRedactionKeyCount)
                .map(Self.normalizedKey)
        )
    }

    /// Returns `nil` only when the event cannot be made safe and encodable.
    /// Sensitive attribute keys are retained with a constant marker so users can
    /// diagnose filtering without any part of the original value surviving.
    internal func sanitize(_ event: TelemetryEvent) -> TelemetryEvent? {
        guard configuration.maximumAttributeCount > 0,
            configuration.maximumStringLength > 0,
            configuration.maximumCollectionLength > 0,
            configuration.maximumNestingDepth > 0
        else {
            return nil
        }

        var budget = SanitizationBudget(
            remainingNodes: maximumNodeCount,
            remainingUTF8Bytes: maximumOutputBytes
        )
        let name = truncate(
            event.name.trimmingCharacters(in: .whitespacesAndNewlines),
            to: configuration.maximumStringLength
        )
        guard !name.isEmpty, budget.consumeNode(), budget.consume(name) else {
            return nil
        }

        var sanitized = event
        sanitized.name = name
        sanitized.attributes = sanitizeObject(
            event.attributes,
            maximumCount: configuration.maximumAttributeCount,
            depth: 0,
            budget: &budget
        )
        return sanitized
    }

    /// Bounds values retained by a long-lived span before the caller decides
    /// when to end it. End-time attributes still pass through normal capture.
    internal func sanitizeSpan(
        operation: String,
        attributes: [String: TelemetryValue]
    ) -> (operation: String, attributes: [String: TelemetryValue]) {
        guard configuration.maximumAttributeCount > 0,
            configuration.maximumStringLength > 0,
            configuration.maximumCollectionLength > 0,
            configuration.maximumNestingDepth > 0
        else {
            return ("", [:])
        }

        var budget = SanitizationBudget(
            remainingNodes: maximumNodeCount,
            remainingUTF8Bytes: maximumOutputBytes
        )
        let operation = truncate(
            operation.trimmingCharacters(in: .whitespacesAndNewlines),
            to: configuration.maximumStringLength
        )
        guard budget.consumeNode(), budget.consume(operation) else {
            return ("", [:])
        }
        return (
            operation,
            sanitizeObject(
                attributes,
                maximumCount: configuration.maximumAttributeCount,
                depth: 0,
                budget: &budget
            )
        )
    }

    /// Produces the only URL attributes automatic network instrumentation may
    /// emit. User info, query, fragment, scheme, and port are never returned.
    internal func sanitizedURLAttributes(_ url: URL?) -> [String: TelemetryValue] {
        guard let url,
            configuration.networkURLCollection != .none,
            let rawHost = url.host,
            !rawHost.isEmpty
        else {
            return [:]
        }

        let host = truncate(
            rawHost.lowercased(with: Locale(identifier: "en_US_POSIX")),
            to: configuration.maximumStringLength
        )
        guard !host.isEmpty else { return [:] }

        var attributes: [String: TelemetryValue] = [
            "network.host": .string(host)
        ]
        if configuration.networkURLCollection == .hostAndPath {
            let path = truncate(url.path, to: configuration.maximumStringLength)
            if !path.isEmpty, path != "/" {
                attributes["network.path"] = .string(path)
            }
        }
        return attributes
    }

    private func sanitizeObject(
        _ object: [String: TelemetryValue],
        maximumCount: Int,
        depth: Int,
        budget: inout SanitizationBudget
    ) -> [String: TelemetryValue] {
        guard depth <= configuration.maximumNestingDepth else { return [:] }

        let safeMaximumCount = min(maximumCount, maximumNodeCount)
        var result: [String: TelemetryValue] = [:]
        result.reserveCapacity(min(object.count, safeMaximumCount))

        // Select the lexicographically smallest capped set without first
        // materializing every key in an attacker-controlled dictionary.
        let keys = selectedKeys(from: object, maximumCount: safeMaximumCount)

        for originalKey in keys {
            guard result.count < safeMaximumCount else { break }
            let normalizedOriginalKey = Self.normalizedKey(originalKey)
            let key = truncate(
                originalKey.trimmingCharacters(in: .whitespacesAndNewlines),
                to: configuration.maximumStringLength
            )
            guard !key.isEmpty,
                budget.consume(key),
                let value = object[originalKey]
            else {
                continue
            }

            // Match before truncating the key. Otherwise a deliberately tiny
            // key-length cap could turn "authorization" into "autho" and bypass
            // the configured redaction rule.
            if normalizedRedactedKeys.contains(normalizedOriginalKey) {
                guard budget.consumeNode(), budget.consume(Self.redactedMarker) else {
                    continue
                }
                result[key] = .string(Self.redactedMarker)
                continue
            }

            guard let sanitizedValue = sanitize(value, depth: depth, budget: &budget) else {
                continue
            }
            result[key] = sanitizedValue
        }
        return result
    }

    private func selectedKeys(
        from object: [String: TelemetryValue],
        maximumCount: Int
    ) -> [String] {
        guard maximumCount > 0 else { return [] }
        var selected: [KeyCandidate] = []
        selected.reserveCapacity(min(object.count, maximumCount))
        let maximumKeyBytes = min(maximumOutputBytes, safeMaximumKeyBytes())

        for original in object.keys {
            // Oversized keys are dropped before normalization so lowercasing an
            // attacker-controlled key cannot allocate outside the output budget.
            guard original.utf8.count <= maximumKeyBytes else { continue }
            let candidate = KeyCandidate(
                normalized: Self.normalizedKey(original),
                original: original
            )
            if selected.count < maximumCount {
                selected.append(candidate)
                continue
            }

            guard
                let largestIndex = selected.indices.max(by: {
                    Self.keyCandidateIsOrderedBefore(selected[$0], selected[$1])
                }),
                Self.keyCandidateIsOrderedBefore(candidate, selected[largestIndex])
            else {
                continue
            }
            selected[largestIndex] = candidate
        }

        selected.sort(by: Self.keyCandidateIsOrderedBefore)
        return selected.map(\.original)
    }

    private func sanitize(
        _ value: TelemetryValue,
        depth: Int,
        budget: inout SanitizationBudget
    ) -> TelemetryValue? {
        guard budget.consumeNode() else { return nil }

        switch value {
        case .string(let value):
            let truncated = truncate(value, to: configuration.maximumStringLength)
            return budget.consume(truncated) ? .string(truncated) : nil
        case .integer(let value):
            return .integer(value)
        case .double(let value):
            return value.isFinite ? .double(value) : nil
        case .boolean(let value):
            return .boolean(value)
        case .null:
            return .null
        case .array(let values):
            guard depth < configuration.maximumNestingDepth else { return nil }
            var sanitized: [TelemetryValue] = []
            let maximumCount = min(configuration.maximumCollectionLength, maximumNodeCount)
            sanitized.reserveCapacity(min(values.count, maximumCount))
            for value in values.prefix(maximumCount) {
                guard let item = sanitize(value, depth: depth + 1, budget: &budget) else {
                    continue
                }
                sanitized.append(item)
            }
            return .array(sanitized)
        case .object(let value):
            guard depth < configuration.maximumNestingDepth else { return nil }
            return .object(
                sanitizeObject(
                    value,
                    maximumCount: configuration.maximumCollectionLength,
                    depth: depth + 1,
                    budget: &budget
                )
            )
        }
    }

    private func truncate(_ value: String, to maximumLength: Int) -> String {
        String(value.prefix(max(0, maximumLength)))
    }

    private func safeMaximumKeyBytes() -> Int {
        let (value, overflow) = configuration.maximumStringLength.multipliedReportingOverflow(
            by: 4
        )
        return overflow ? Int.max : max(Self.maximumRedactionKeyBytes, value)
    }

    private static func keyCandidateIsOrderedBefore(
        _ lhs: KeyCandidate,
        _ rhs: KeyCandidate
    ) -> Bool {
        lhs.normalized == rhs.normalized
            ? lhs.original < rhs.original
            : lhs.normalized < rhs.normalized
    }

    private static func normalizedKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}
