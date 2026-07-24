import Darwin
import Foundation

struct PersistenceRootEntry: Sendable {
    let relativePath: String
    let isDirectory: Bool
    let isRegularFile: Bool
    let isSymbolicLink: Bool
}

final class PersistenceRootHandle: @unchecked Sendable {
    private let descriptor: CInt
    private let device: dev_t
    private let inode: ino_t

    init(root: URL) throws {
        let descriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw Self.error() }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else {
            Darwin.close(descriptor)
            throw Self.error()
        }
        self.descriptor = descriptor
        device = value.st_dev
        inode = value.st_ino
    }

    deinit {
        Darwin.close(descriptor)
    }

    func verifyPath(_ root: URL) throws {
        let candidate = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard candidate >= 0 else { throw Self.error() }
        defer { Darwin.close(candidate) }
        var value = stat()
        guard fstat(candidate, &value) == 0,
              value.st_dev == device, value.st_ino == inode else {
            throw Self.error()
        }
    }

    func read(relativePath: String) throws -> Data {
        let components = try Self.components(relativePath)
        let parent = try openDirectory(Array(components.dropLast()))
        defer { Darwin.close(parent) }
        let file = Darwin.openat(
            parent,
            components.last!,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard file >= 0 else { throw Self.error() }
        defer { Darwin.close(file) }
        var value = stat()
        guard fstat(file, &value) == 0, value.st_mode & S_IFMT == S_IFREG else {
            throw Self.error()
        }
        return try FileHandle(fileDescriptor: file, closeOnDealloc: false).readToEnd() ?? Data()
    }

    func entries(relativeDirectory: String) throws -> [PersistenceRootEntry] {
        var result: [PersistenceRootEntry] = []
        try appendEntries(relativeDirectory: relativeDirectory, result: &result)
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    func removeTree(relativePath: String) throws {
        let components = try Self.components(relativePath)
        let parent = try openDirectory(Array(components.dropLast()))
        defer { Darwin.close(parent) }
        try removeTree(parent: parent, name: components.last!)
    }

    func removeFileAndEmptyParent(relativePath: String) throws {
        let components = try Self.components(relativePath)
        let parentComponents = Array(components.dropLast())
        let parent = try openDirectory(parentComponents)
        defer { Darwin.close(parent) }
        var value = stat()
        guard fstatat(parent, components.last!, &value, AT_SYMLINK_NOFOLLOW) == 0,
              value.st_mode & S_IFMT == S_IFREG,
              unlinkat(parent, components.last!, 0) == 0 else {
            throw Self.error()
        }
        guard let directoryName = parentComponents.last else { return }
        let grandparent = try openDirectory(Array(parentComponents.dropLast()))
        defer { Darwin.close(grandparent) }
        if unlinkat(grandparent, directoryName, AT_REMOVEDIR) != 0,
           errno != ENOTEMPTY, errno != ENOENT {
            throw Self.error()
        }
    }

    private func appendEntries(
        relativeDirectory: String,
        result: inout [PersistenceRootEntry]
    ) throws {
        let directory = try openDirectory(try Self.componentsAllowingEmpty(relativeDirectory))
        guard let stream = fdopendir(directory) else {
            Darwin.close(directory)
            throw Self.error()
        }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            var value = stat()
            guard fstatat(dirfd(stream), name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw Self.error()
            }
            let relativePath = relativeDirectory.isEmpty ? name : "\(relativeDirectory)/\(name)"
            let kind = value.st_mode & S_IFMT
            result.append(.init(
                relativePath: relativePath,
                isDirectory: kind == S_IFDIR,
                isRegularFile: kind == S_IFREG,
                isSymbolicLink: kind == S_IFLNK
            ))
            if kind == S_IFDIR {
                try appendEntries(relativeDirectory: relativePath, result: &result)
            }
        }
    }

    private func removeTree(parent: CInt, name: String) throws {
        var value = stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Self.error()
        }
        guard value.st_mode & S_IFMT == S_IFDIR else {
            guard unlinkat(parent, name, 0) == 0 else { throw Self.error() }
            return
        }
        let directory = Darwin.openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directory >= 0 else { throw Self.error() }
        let duplicate = fcntl(directory, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            Darwin.close(directory)
            throw Self.error()
        }
        defer {
            closedir(stream)
            Darwin.close(directory)
        }
        while let entry = readdir(stream) {
            let child = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if child != ".", child != ".." { try removeTree(parent: directory, name: child) }
        }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw Self.error() }
    }

    private func openDirectory(_ components: [String]) throws -> CInt {
        var current = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard current >= 0 else { throw Self.error() }
        for component in components {
            let next = Darwin.openat(
                current,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            Darwin.close(current)
            guard next >= 0 else { throw Self.error() }
            current = next
        }
        return current
    }

    private static func components(_ path: String) throws -> [String] {
        let result = try componentsAllowingEmpty(path)
        guard !result.isEmpty else { throw error() }
        return result
    }

    private static func componentsAllowingEmpty(_ path: String) throws -> [String] {
        guard !NSString(string: path).isAbsolutePath else { throw error() }
        let result = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard result.allSatisfy({ $0 != "." && $0 != ".." }) else { throw error() }
        return result
    }

    private static func error() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
