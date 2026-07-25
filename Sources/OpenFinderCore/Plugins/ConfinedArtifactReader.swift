import CryptoKit
import Darwin
import Foundation

public enum ConfinedArtifactError: Error, Equatable, LocalizedError, Sendable {
    case invalidRoot
    case rootReplaced
    case invalidRelativePath
    case unavailable
    case symbolicLink
    case notRegularFile
    case tooLarge
    case sizeMismatch
    case hashMismatch
    case modifiedDuringRead
    case ioFailure

    public var errorDescription: String? {
        switch self {
        case .invalidRoot: "The plugin artifact root is unavailable."
        case .rootReplaced: "The plugin artifact root changed during processing."
        case .invalidRelativePath: "The plugin artifact path is invalid."
        case .unavailable: "The plugin artifact is unavailable."
        case .symbolicLink: "Plugin artifacts cannot be symbolic links."
        case .notRegularFile: "The plugin artifact is not a regular file."
        case .tooLarge: "The plugin artifact exceeds the permitted size."
        case .sizeMismatch: "The plugin artifact size does not match its metadata."
        case .hashMismatch: "The plugin artifact digest does not match its metadata."
        case .modifiedDuringRead: "The plugin artifact changed while it was being read."
        case .ioFailure: "The plugin artifact could not be read safely."
        }
    }
}

public struct ConfinedArtifactReader: Sendable {
    public static let maximumResultBytes = 50 * 1_048_576

    public let root: URL
    private let rootDevice: dev_t
    private let rootInode: ino_t

    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        let descriptor = Darwin.open(self.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ConfinedArtifactError.invalidRoot }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
            throw ConfinedArtifactError.invalidRoot
        }
        rootDevice = status.st_dev
        rootInode = status.st_ino
    }

    public func read(
        _ artifact: PluginFileArtifact,
        maximumByteCount: Int = Self.maximumResultBytes
    ) throws -> Data {
        let descriptor = try openFile(relativePath: artifact.relativePath)
        defer { Darwin.close(descriptor) }
        let before = try fileStatus(descriptor)
        guard before.st_size >= 0 else { throw ConfinedArtifactError.ioFailure }
        guard before.st_size <= maximumByteCount else { throw ConfinedArtifactError.tooLarge }
        guard before.st_size == artifact.byteCount else { throw ConfinedArtifactError.sizeMismatch }

        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw ConfinedArtifactError.ioFailure
            }
            guard data.count <= maximumByteCount - count else { throw ConfinedArtifactError.tooLarge }
            let chunk = Data(buffer[..<count])
            hasher.update(data: chunk)
            data.append(chunk)
        }

        let after = try fileStatus(descriptor)
        guard isSameFile(before, after), data.count == artifact.byteCount else {
            throw ConfinedArtifactError.modifiedDuringRead
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == artifact.sha256 else { throw ConfinedArtifactError.hashMismatch }
        return data
    }

    public func validate(relativePath: String) throws -> URL {
        let descriptor = try openFile(relativePath: relativePath)
        Darwin.close(descriptor)
        return root.appendingPathComponent(relativePath).standardizedFileURL
    }

    public func relativePath(forValidatedURL url: URL) throws -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { throw ConfinedArtifactError.invalidRelativePath }
        let relativePath = String(path.dropFirst(rootPath.count))
        _ = try Self.pathComponents(relativePath)
        return relativePath
    }

    func openFile(relativePath: String) throws -> Int32 {
        let components = try Self.pathComponents(relativePath)
        var current = try openVerifiedRoot()
        defer { Darwin.close(current) }

        for component in components.dropLast() {
            let next = component.withCString {
                openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw mappedOpenError() }
            Darwin.close(current)
            current = next
        }
        let final = components.last!.withCString {
            openat(current, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard final >= 0 else { throw mappedOpenError() }
        var status = stat()
        guard fstat(final, &status) == 0 else {
            Darwin.close(final)
            throw ConfinedArtifactError.ioFailure
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(final)
            throw ConfinedArtifactError.notRegularFile
        }
        return final
    }

    private func openVerifiedRoot() throws -> Int32 {
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ConfinedArtifactError.rootReplaced }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            Darwin.close(descriptor)
            throw ConfinedArtifactError.ioFailure
        }
        guard status.st_dev == rootDevice, status.st_ino == rootInode else {
            Darwin.close(descriptor)
            throw ConfinedArtifactError.rootReplaced
        }
        return descriptor
    }

    private func fileStatus(_ descriptor: Int32) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw ConfinedArtifactError.ioFailure }
        return value
    }

    private func isSameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func pathComponents(_ path: String) throws -> [String] {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\") else {
            throw ConfinedArtifactError.invalidRelativePath
        }
        let bytes = Array(path.utf8)
        if bytes.count >= 2,
           ((65 ... 90).contains(bytes[0]) || (97 ... 122).contains(bytes[0])), bytes[1] == 58 {
            throw ConfinedArtifactError.invalidRelativePath
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ConfinedArtifactError.invalidRelativePath
        }
        return components
    }

    private func mappedOpenError() -> ConfinedArtifactError {
        errno == ELOOP ? .symbolicLink : .unavailable
    }
}
