import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Prevents clients from concurrently owning the same queue. Apple platforms
/// also hold an advisory file lock so an app extension cannot race its host.
internal final class StorageDirectoryLease: @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        static let shared = Registry()

        private let lock = NSLock()
        private var leasedPaths: Set<String> = []

        func acquire(path: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return leasedPaths.insert(path).inserted
        }

        func release(path: String) {
            lock.lock()
            leasedPaths.remove(path)
            lock.unlock()
        }
    }

    private let path: String
    #if canImport(Darwin)
        private let fileDescriptor: Int32
    #endif
    private let lock = NSLock()
    private var isReleased = false

    #if canImport(Darwin)
        private init(path: String, fileDescriptor: Int32) {
            self.path = path
            self.fileDescriptor = fileDescriptor
        }
    #else
        private init(path: String) {
            self.path = path
        }
    #endif

    internal static func acquire(for directory: URL) throws -> StorageDirectoryLease {
        let normalizedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let path = normalizedDirectory.path
        guard Registry.shared.acquire(path: path) else {
            throw TelemetryError.storageUnavailable(
                "Another client already owns this storage namespace."
            )
        }

        #if canImport(Darwin)
            do {
                try FileManager.default.createDirectory(
                    at: normalizedDirectory,
                    withIntermediateDirectories: true
                )
                let lockPath =
                    normalizedDirectory
                    .appendingPathComponent(".telemetrykit.lock", isDirectory: false)
                    .path
                let fileDescriptor = lockPath.withCString {
                    Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
                }
                guard fileDescriptor >= 0 else {
                    throw TelemetryError.storageUnavailable(
                        "The storage namespace lock file could not be opened."
                    )
                }
                guard Darwin.flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                    Darwin.close(fileDescriptor)
                    throw TelemetryError.storageUnavailable(
                        "Another process already owns this storage namespace."
                    )
                }
                return StorageDirectoryLease(path: path, fileDescriptor: fileDescriptor)
            } catch {
                Registry.shared.release(path: path)
                throw error
            }
        #else
            return StorageDirectoryLease(path: path)
        #endif
    }

    deinit {
        release()
    }

    internal func release() {
        lock.lock()
        guard !isReleased else {
            lock.unlock()
            return
        }
        isReleased = true
        lock.unlock()
        #if canImport(Darwin)
            _ = Darwin.flock(fileDescriptor, LOCK_UN)
            _ = Darwin.close(fileDescriptor)
        #endif
        Registry.shared.release(path: path)
    }
}
