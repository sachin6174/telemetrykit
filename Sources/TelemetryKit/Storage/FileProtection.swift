import Foundation

internal enum TelemetryFileProtection {
    /// Creates the queue directory and applies the strongest protection that
    /// still permits background delivery after the first device unlock.
    internal static func prepareDirectory(at url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: directoryAttributes
            )
            try applyAttributes(to: url)
            try excludeDirectoryFromBackup(url)
        } catch {
            throw DiskEventQueueError.unableToCreateDirectory(error.localizedDescription)
        }
    }

    /// Writes a protected sibling temporary file and atomically installs it,
    /// preventing a torn envelope from replacing a durable record.
    internal static func writeAtomically(_ data: Data, to url: URL) throws {
        let temporaryURL =
            url
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(url.lastPathComponent).tmp-\(UUID().uuidString.lowercased())",
                isDirectory: false
            )
        do {
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
                try data.write(
                    to: temporaryURL,
                    options: [.completeFileProtectionUntilFirstUserAuthentication]
                )
            #else
                try data.write(to: temporaryURL)
            #endif
            try applyAttributes(to: temporaryURL)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: url)
            }
            try applyAttributes(to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw DiskEventQueueError.unableToPersistEvent(error.localizedDescription)
        }
    }

    private static var directoryAttributes: [FileAttributeKey: Any]? {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            return [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
            return nil
        #endif
    }

    private static func applyAttributes(to url: URL) throws {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        #endif
    }

    private static func excludeDirectoryFromBackup(_ url: URL) throws {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            var mutableURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try mutableURL.setResourceValues(values)
        #endif
    }
}
