import Foundation

extension AppDatabase {
    static let taskStorageMigration = """
        CREATE TABLE app_schema_metadata (
            singleton INTEGER NOT NULL PRIMARY KEY CHECK (singleton = 1),
            schema_version INTEGER NOT NULL CHECK (schema_version >= 1),
            migrated_at REAL NOT NULL
        ) STRICT;
        INSERT INTO app_schema_metadata (singleton, schema_version, migrated_at)
        VALUES (1, 1, unixepoch());

        CREATE TABLE task_descriptors (
            task_id TEXT NOT NULL PRIMARY KEY,
            schema_version INTEGER NOT NULL CHECK (schema_version = 1),
            handler_id TEXT NOT NULL CHECK (handler_id <> ''),
            payload_version INTEGER NOT NULL CHECK (payload_version >= 1),
            redacted_payload BLOB NOT NULL,
            root_task_id TEXT NOT NULL,
            parent_task_id TEXT,
            attempt INTEGER NOT NULL CHECK (attempt >= 1),
            resource_key TEXT,
            idempotency_key TEXT,
            queue_ordinal INTEGER NOT NULL UNIQUE CHECK (queue_ordinal >= 0),
            created_at REAL NOT NULL,
            CHECK (
                (attempt = 1 AND parent_task_id IS NULL AND root_task_id = task_id)
                OR (attempt > 1 AND parent_task_id IS NOT NULL AND parent_task_id <> task_id)
            )
        ) STRICT;
        CREATE UNIQUE INDEX idx_task_descriptors_queue_ordinal
            ON task_descriptors(queue_ordinal);
        CREATE INDEX idx_task_descriptors_lineage
            ON task_descriptors(root_task_id, attempt);
        CREATE INDEX idx_task_descriptors_parent
            ON task_descriptors(parent_task_id);
        CREATE INDEX idx_task_descriptors_idempotency
            ON task_descriptors(idempotency_key)
            WHERE idempotency_key IS NOT NULL;

        CREATE TABLE task_records (
            task_id TEXT NOT NULL PRIMARY KEY
                REFERENCES task_descriptors(task_id) ON DELETE CASCADE,
            record_version INTEGER NOT NULL CHECK (record_version = 1),
            kind_payload BLOB NOT NULL,
            title TEXT NOT NULL,
            status TEXT NOT NULL CHECK (
                status IN (
                    'queued', 'running', 'succeeded', 'failed', 'cancelling',
                    'cancelled', 'interrupted', 'unavailable'
                )
            ),
            status_reason TEXT CHECK (
                status_reason IS NULL OR status_reason IN (
                    'recoveryInterrupted', 'unknownHandler', 'unsupportedPayloadVersion',
                    'malformedPayload', 'handlerUnavailable'
                )
            ),
            progress REAL CHECK (progress IS NULL OR (progress >= 0 AND progress <= 1)),
            progress_detail BLOB,
            created_at REAL NOT NULL,
            started_at REAL,
            finished_at REAL,
            input_summary TEXT NOT NULL,
            result_summary TEXT,
            error_message TEXT,
            log_file_path TEXT,
            retry_count INTEGER NOT NULL CHECK (retry_count >= 0),
            clipboard_text TEXT,
            effects_committed_at REAL,
            CHECK (finished_at IS NULL OR finished_at >= created_at)
        ) STRICT;
        CREATE INDEX idx_task_records_status
            ON task_records(status, created_at);
        CREATE INDEX idx_task_records_finished
            ON task_records(finished_at)
            WHERE finished_at IS NOT NULL;

        CREATE TABLE task_logs (
            task_id TEXT NOT NULL
                REFERENCES task_records(task_id) ON DELETE CASCADE,
            sequence INTEGER NOT NULL CHECK (sequence >= 0),
            logged_at REAL NOT NULL,
            level TEXT NOT NULL CHECK (level <> ''),
            message TEXT NOT NULL,
            PRIMARY KEY (task_id, sequence)
        ) STRICT, WITHOUT ROWID;
        CREATE INDEX idx_task_logs_task_sequence
            ON task_logs(task_id, sequence);
        """

    static let artifactMediaStorageMigration = """
        CREATE TABLE artifact_records (
            artifact_id TEXT NOT NULL PRIMARY KEY,
            record_version INTEGER NOT NULL CHECK (record_version = 1),
            schema_id TEXT NOT NULL CHECK (schema_id <> ''),
            state TEXT NOT NULL CHECK (
                state IN (
                    'staging', 'validated', 'filePublished',
                    'rowLinked', 'committed', 'cleaned'
                )
            ),
            relative_path TEXT NOT NULL CHECK (
                relative_path <> ''
                AND substr(relative_path, 1, 1) <> '/'
                AND instr('/' || relative_path || '/', '/../') = 0
                AND instr('/' || relative_path || '/', '/./') = 0
            ),
            media_type TEXT NOT NULL CHECK (media_type <> ''),
            byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
            sha256 TEXT NOT NULL CHECK (
                length(sha256) = 64
                AND sha256 NOT GLOB '*[^0-9a-f]*'
            ),
            staged_at REAL NOT NULL,
            finished_at REAL,
            retention_deadline REAL,
            reconciliation_state TEXT NOT NULL CHECK (
                reconciliation_state IN (
                    'validate', 'publishFile', 'linkRow',
                    'commit', 'stable', 'cleanupComplete'
                )
            ),
            reconciliation_reason TEXT,
            reconciled_at REAL,
            cleanup_attempts INTEGER NOT NULL DEFAULT 0 CHECK (cleanup_attempts >= 0),
            CHECK (finished_at IS NULL OR finished_at >= staged_at),
            CHECK (retention_deadline IS NULL OR finished_at IS NOT NULL),
            CHECK (
                (state IN ('committed', 'cleaned') AND finished_at IS NOT NULL)
                OR (state NOT IN ('committed', 'cleaned') AND finished_at IS NULL)
            )
        ) STRICT;
        CREATE INDEX idx_artifact_records_state
            ON artifact_records(state, staged_at);
        CREATE INDEX idx_artifact_records_retention
            ON artifact_records(retention_deadline)
            WHERE retention_deadline IS NOT NULL;
        CREATE INDEX idx_artifact_records_reconciliation
            ON artifact_records(reconciliation_state, reconciled_at);

        CREATE TABLE task_artifacts (
            task_id TEXT NOT NULL
                REFERENCES task_records(task_id) ON DELETE CASCADE,
            artifact_id TEXT NOT NULL
                REFERENCES artifact_records(artifact_id) ON DELETE RESTRICT,
            ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
            linked_at REAL NOT NULL DEFAULT (unixepoch()),
            PRIMARY KEY (task_id, artifact_id),
            UNIQUE (task_id, ordinal)
        ) STRICT, WITHOUT ROWID;
        CREATE INDEX idx_task_artifacts_artifact
            ON task_artifacts(artifact_id);

        CREATE TABLE media_analysis_documents (
            document_id TEXT NOT NULL PRIMARY KEY,
            task_id TEXT NOT NULL
                REFERENCES task_records(task_id) ON DELETE CASCADE,
            schema_id TEXT NOT NULL CHECK (schema_id = 'mediaAnalysis.v1'),
            schema_version INTEGER NOT NULL CHECK (schema_version = 1),
            payload BLOB NOT NULL,
            created_at REAL NOT NULL,
            retention_deadline REAL,
            reconciliation_state TEXT NOT NULL DEFAULT 'stable' CHECK (
                reconciliation_state IN ('pending', 'stable', 'cleanupPending', 'cleanupComplete')
            ),
            reconciliation_reason TEXT,
            reconciled_at REAL
        ) STRICT;
        CREATE INDEX idx_media_documents_task
            ON media_analysis_documents(task_id, created_at);
        CREATE INDEX idx_media_documents_retention
            ON media_analysis_documents(retention_deadline)
            WHERE retention_deadline IS NOT NULL;

        CREATE TABLE media_managed_tags (
            document_id TEXT NOT NULL
                REFERENCES media_analysis_documents(document_id) ON DELETE CASCADE,
            stable_media_id TEXT NOT NULL CHECK (stable_media_id <> ''),
            source_path TEXT NOT NULL CHECK (source_path <> ''),
            display_name TEXT NOT NULL CHECK (display_name <> ''),
            tag_name TEXT NOT NULL CHECK (tag_name <> ''),
            ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
            managed_at REAL NOT NULL,
            reconciliation_state TEXT NOT NULL DEFAULT 'stable' CHECK (
                reconciliation_state IN ('pendingAdd', 'stable', 'pendingRemove')
            ),
            reconciliation_reason TEXT,
            PRIMARY KEY (document_id, stable_media_id, tag_name),
            UNIQUE (document_id, stable_media_id, ordinal)
        ) STRICT, WITHOUT ROWID;
        CREATE INDEX idx_media_tags_stable_media
            ON media_managed_tags(stable_media_id, ordinal);
        CREATE INDEX idx_media_tags_reconciliation
            ON media_managed_tags(reconciliation_state, managed_at);

        UPDATE app_schema_metadata
        SET schema_version = 2, migrated_at = unixepoch()
        WHERE singleton = 1;
        """

    static let taskLineageForeignKeysMigration = """
        CREATE TABLE task_descriptors_v3 (
            task_id TEXT NOT NULL PRIMARY KEY,
            schema_version INTEGER NOT NULL CHECK (schema_version = 1),
            handler_id TEXT NOT NULL CHECK (handler_id <> ''),
            payload_version INTEGER NOT NULL CHECK (payload_version >= 1),
            redacted_payload BLOB NOT NULL,
            root_task_id TEXT NOT NULL
                REFERENCES task_descriptors(task_id) ON DELETE RESTRICT,
            parent_task_id TEXT
                REFERENCES task_descriptors(task_id) ON DELETE RESTRICT,
            attempt INTEGER NOT NULL CHECK (attempt >= 1),
            resource_key TEXT,
            idempotency_key TEXT,
            queue_ordinal INTEGER NOT NULL UNIQUE CHECK (queue_ordinal >= 0),
            created_at REAL NOT NULL,
            CHECK (
                (attempt = 1 AND parent_task_id IS NULL AND root_task_id = task_id)
                OR (attempt > 1 AND parent_task_id IS NOT NULL AND parent_task_id <> task_id)
            )
        ) STRICT;

        INSERT INTO task_descriptors_v3 (
            task_id, schema_version, handler_id, payload_version, redacted_payload,
            root_task_id, parent_task_id, attempt, resource_key, idempotency_key,
            queue_ordinal, created_at
        )
        SELECT
            task_id, schema_version, handler_id, payload_version, redacted_payload,
            root_task_id, parent_task_id, attempt, resource_key, idempotency_key,
            queue_ordinal, created_at
        FROM task_descriptors;

        DROP TABLE task_descriptors;
        ALTER TABLE task_descriptors_v3 RENAME TO task_descriptors;

        CREATE UNIQUE INDEX idx_task_descriptors_queue_ordinal
            ON task_descriptors(queue_ordinal);
        CREATE INDEX idx_task_descriptors_lineage
            ON task_descriptors(root_task_id, attempt);
        CREATE INDEX idx_task_descriptors_parent
            ON task_descriptors(parent_task_id);
        CREATE INDEX idx_task_descriptors_idempotency
            ON task_descriptors(idempotency_key)
            WHERE idempotency_key IS NOT NULL;

        UPDATE app_schema_metadata
        SET schema_version = 3, migrated_at = unixepoch()
        WHERE singleton = 1;
        """
}
