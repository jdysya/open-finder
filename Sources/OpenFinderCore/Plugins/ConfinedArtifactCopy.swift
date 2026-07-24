import CryptoKit
import Darwin
import Foundation

extension ConfinedArtifactReader {
    public func copy(
        relativePath: String,
        to destination: URL,
        maximumByteCount: Int = .max
    ) throws {
        try copy(relativePath: relativePath, expected: nil, to: destination, maximumByteCount: maximumByteCount)
    }

    public func copy(
        artifact: PluginFileArtifact,
        to destination: URL,
        maximumByteCount: Int = Self.maximumResultBytes
    ) throws {
        try copy(
            relativePath: artifact.relativePath,
            expected: artifact,
            to: destination,
            maximumByteCount: maximumByteCount
        )
    }

    private func copy(
        relativePath: String,
        expected: PluginFileArtifact?,
        to destination: URL,
        maximumByteCount: Int
    ) throws {
        let source = try openFile(relativePath: relativePath)
        defer { Darwin.close(source) }
        var before = stat()
        guard fstat(source, &before) == 0, before.st_size >= 0 else {
            throw ConfinedArtifactError.ioFailure
        }
        guard before.st_size <= maximumByteCount else { throw ConfinedArtifactError.tooLarge }
        if let expected, before.st_size != expected.byteCount {
            throw ConfinedArtifactError.sizeMismatch
        }

        let target = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard target >= 0 else { throw ConfinedArtifactError.ioFailure }
        defer { Darwin.close(target) }
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: destination)
            }
        }

        var total = 0
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(source, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw ConfinedArtifactError.ioFailure
            }
            guard total <= maximumByteCount - count else { throw ConfinedArtifactError.tooLarge }
            try writeAll(buffer, count: count, descriptor: target)
            hasher.update(data: Data(buffer[..<count]))
            total += count
        }

        var after = stat()
        guard fstat(source, &after) == 0 else { throw ConfinedArtifactError.ioFailure }
        guard sameIdentityAndRevision(before, after), total == before.st_size else {
            throw ConfinedArtifactError.modifiedDuringRead
        }
        if let expected {
            guard total == expected.byteCount else { throw ConfinedArtifactError.sizeMismatch }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == expected.sha256 else { throw ConfinedArtifactError.hashMismatch }
        }
        guard fsync(target) == 0 else { throw ConfinedArtifactError.ioFailure }
        completed = true
    }

    private func writeAll(_ buffer: [UInt8], count: Int, descriptor: Int32) throws {
        try buffer.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), count - offset)
                guard written >= 0 else {
                    if errno == EINTR { continue }
                    throw ConfinedArtifactError.ioFailure
                }
                guard written > 0 else { throw ConfinedArtifactError.ioFailure }
                offset += written
            }
        }
    }

    private func sameIdentityAndRevision(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
