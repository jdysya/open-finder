import Darwin
import Foundation
import GRDB

struct ArtifactSnapshot: Sendable {
    let id: UUID
    let relativePath: String
    let byteCount: Int
    let sha256: String

    static func fetchAll(_ db: Database) throws -> (records: [Self], issues: [PersistenceReconciliationIssue]) {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT artifact_id, relative_path, byte_count, sha256
                FROM artifact_records
                """
        )
        var records: [Self] = []
        var issues: [PersistenceReconciliationIssue] = []
        for row in rows {
            let rawID: String = row["artifact_id"]
            guard let id = UUID(uuidString: rawID) else {
                issues.append(.init(
                    kind: .corruptArtifactRow,
                    detail: "Artifact row has an invalid UUID: \(rawID)"
                ))
                continue
            }
            records.append(Self(
                id: id,
                relativePath: row["relative_path"],
                byteCount: row["byte_count"],
                sha256: row["sha256"]
            ))
        }
        return (records, issues)
    }
}

struct ArtifactLinkSnapshot: Sendable {
    let artifactID: UUID
    let taskID: UUID

    static func fetchAll(_ db: Database) throws -> (
        records: [Self],
        issues: [PersistenceReconciliationIssue]
    ) {
        let rows = try Row.fetchAll(db, sql: "SELECT artifact_id, task_id FROM task_artifacts")
        var records: [Self] = []
        var issues: [PersistenceReconciliationIssue] = []
        for row in rows {
            let rawArtifactID: String = row["artifact_id"]
            let rawTaskID: String = row["task_id"]
            guard
                let artifactID = UUID(uuidString: rawArtifactID),
                let taskID = UUID(uuidString: rawTaskID)
            else {
                issues.append(.init(
                    kind: .corruptArtifactRow,
                    artifactID: UUID(uuidString: rawArtifactID),
                    taskID: UUID(uuidString: rawTaskID),
                    detail: "Artifact link row has invalid UUID metadata."
                ))
                continue
            }
            records.append(Self(artifactID: artifactID, taskID: taskID))
        }
        return (records, issues)
    }
}

struct PersistenceRootIdentity: Sendable {
    let device: dev_t
    let inode: ino_t

    init(root: URL) throws {
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PersistenceRootError.invalid }
        defer { Darwin.close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else {
            throw PersistenceRootError.invalid
        }
        device = value.st_dev
        inode = value.st_ino
    }

    func verify(root: URL) throws {
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PersistenceRootError.replaced }
        defer { Darwin.close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0,
              value.st_dev == device, value.st_ino == inode else {
            throw PersistenceRootError.replaced
        }
    }
}

struct MediaDocumentSnapshot: Sendable {
    let id: UUID
    let taskID: UUID
    let artifactIDs: Set<UUID>

    static func fetchAll(
        _ db: Database
    ) throws -> (records: [Self], rowIDs: Set<String>, issues: [PersistenceReconciliationIssue]) {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT document_id, task_id, schema_id, schema_version, payload FROM media_analysis_documents"
        )
        var records: [Self] = []
        var issues: [PersistenceReconciliationIssue] = []
        for row in rows {
            let rawID: String = row["document_id"]
            let rawTaskID: String = row["task_id"]
            do {
                guard
                    let id = UUID(uuidString: rawID),
                    let taskID = UUID(uuidString: rawTaskID),
                    row["schema_id"] as String == MediaAnalysisDocument.schemaIdentifier,
                    row["schema_version"] as Int == MediaAnalysisDocument.currentSchemaVersion
                else { throw PersistenceRecordError.invalidMediaMetadata }
                let document = try JSONDecoder().decode(
                    MediaAnalysisDocument.self,
                    from: row["payload"] as Data
                )
                guard document.documentID == id, document.taskID == taskID else {
                    throw PersistenceRecordError.mediaIdentityMismatch
                }
                let artifactIDs = document.items.reduce(into: Set<UUID>()) { result, item in
                    result.formUnion(item.moments.flatMap(\.assets).map(\.artifactID))
                    if let report = item.report { result.insert(report.artifactID) }
                }
                records.append(Self(id: id, taskID: taskID, artifactIDs: artifactIDs))
            } catch {
                issues.append(.init(
                    kind: .corruptMediaDocument,
                    taskID: UUID(uuidString: rawTaskID),
                    documentID: UUID(uuidString: rawID),
                    detail: "Media document row is invalid: \(error)"
                ))
            }
        }
        return (records, Set(rows.map { $0["document_id"] as String }), issues)
    }
}

struct ManagedTagSnapshot: Sendable {
    let documentID: String

    static func fetchAll(_ db: Database) throws -> [Self] {
        try String.fetchAll(
            db,
            sql: "SELECT DISTINCT document_id FROM media_managed_tags ORDER BY document_id"
        ).map(Self.init)
    }
}

struct TaskIDSnapshot {
    static func fetchAll(_ db: Database) throws -> Set<UUID> {
        Set(try String.fetchAll(db, sql: "SELECT task_id FROM task_records").compactMap(UUID.init))
    }
}

struct ExpiredTaskSnapshot: Sendable {
    let id: UUID

    static func fetchAll(_ db: Database, now: Date) throws -> [Self] {
        let cutoff = now.addingTimeInterval(-ArtifactRecord.retentionInterval)
        return try String.fetchAll(
            db,
            sql: """
                SELECT task_id
                FROM task_records
                WHERE status IN ('succeeded', 'failed', 'cancelled', 'interrupted', 'unavailable')
                  AND finished_at IS NOT NULL
                  AND finished_at <= ?
                ORDER BY finished_at, task_id
                """,
            arguments: [cutoff.timeIntervalSince1970]
        ).compactMap { UUID(uuidString: $0) }.map(Self.init)
    }
}

private enum PersistenceRecordError: Error {
    case invalidMediaMetadata
    case mediaIdentityMismatch
}

private enum PersistenceRootError: Error {
    case invalid
    case replaced
}
