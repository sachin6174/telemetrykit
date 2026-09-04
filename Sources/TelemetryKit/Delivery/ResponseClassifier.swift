import Foundation

internal enum HTTPDeliveryDisposition: Sendable, Equatable {
    case delivered
    case retry(retryAfter: Date?)
    case splitBatch
    case authenticationBlocked
    case discard
}

internal enum TransportFailureDisposition: Sendable, Equatable {
    case retry
    case cancelled
    case configurationBlocked
}

/// Converts transport results into a small delivery state-machine vocabulary.
internal enum ResponseClassifier {
    internal static func classify(
        statusCode: Int,
        headers: [String: String] = [:],
        now: Date = Date()
    ) -> HTTPDeliveryDisposition {
        switch statusCode {
        case 200...299:
            return .delivered
        case 401, 403:
            return .authenticationBlocked
        case 408, 425, 429, 500...599:
            return .retry(retryAfter: retryAfterDate(in: headers, now: now))
        case 413:
            return .splitBatch
        default:
            return .discard
        }
    }

    internal static func classify(error: Error) -> TransportFailureDisposition {
        let urlErrorCode: URLError.Code?
        if let urlError = error as? URLError {
            urlErrorCode = urlError.code
        } else {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                urlErrorCode = URLError.Code(rawValue: nsError.code)
            } else {
                urlErrorCode = nil
            }
        }

        guard let urlErrorCode else {
            // Unknown transport failures are given the bounded retry cycle rather
            // than losing telemetry after one opaque implementation error.
            return .retry
        }

        switch urlErrorCode {
        case .cancelled:
            return .cancelled
        case .badURL,
            .unsupportedURL,
            .userAuthenticationRequired,
            .appTransportSecurityRequiresSecureConnection,
            .serverCertificateHasBadDate,
            .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid,
            .clientCertificateRejected,
            .clientCertificateRequired:
            return .configurationBlocked
        default:
            return .retry
        }
    }

    private static func retryAfterDate(
        in headers: [String: String],
        now: Date
    ) -> Date? {
        guard
            let value = headers.first(where: {
                $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame
            })?.value.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }

        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }

        // IMF-fixdate is the required HTTP-date form for modern senders.
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        return formatter.date(from: value)
    }
}
