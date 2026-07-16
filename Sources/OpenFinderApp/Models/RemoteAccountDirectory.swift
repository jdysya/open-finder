import Foundation
import OpenFinderCore

final class RemoteAccountDirectory: @unchecked Sendable {
    private let lock = NSLock()
    private let storageURL: URL?
    private var storage: [UUID: RemoteAccount] = [:]

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL
        if let storageURL,
           let data = try? Data(contentsOf: storageURL),
           let accounts = try? JSONDecoder.openFinder.decode([RemoteAccount].self, from: data) {
            storage = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        }
    }

    func save(_ account: RemoteAccount) {
        lock.lock()
        defer { lock.unlock() }
        storage[account.id] = account
        persistLocked()
    }

    func account(id: UUID) -> RemoteAccount? {
        lock.lock()
        defer { lock.unlock() }
        return storage[id]
    }

    func all() -> [RemoteAccount] {
        lock.lock()
        defer { lock.unlock() }
        return storage.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func remove(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: id)
        persistLocked()
    }

    private func persistLocked() {
        guard let storageURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let accounts = storage.values.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            try JSONEncoder.openFinder.encode(accounts).write(to: storageURL, options: .atomic)
        } catch {
            // Persistence failure should not crash browsing; the Settings status surface reports operational failures.
        }
    }
}
