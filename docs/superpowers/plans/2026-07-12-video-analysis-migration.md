# Video Analysis Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a testable built-in video-analysis capability that reuses the existing Python inference pipeline while keeping OpenFinder responsible for task orchestration, persistence, and future Finder-tag reconciliation.

**Architecture:** OpenFinderCore owns versioned analysis request/result models, an atomic result store, and a managed-tag ledger. A bundled Python worker accepts one JSON request on stdin and emits versioned NDJSON progress/result events; an example built-in plugin adapts the existing plugin input to that worker. The first release uses the existing process runner and task queue, restricts video analysis to one concurrent task, and deliberately avoids the tag UI and Finder metadata implementation still under development.

**Tech Stack:** Swift 6, SwiftPM, XCTest, Python 3.11+, Pydantic v2, pytest, NDJSON, existing OpenFinder plugin process runner.

## Global Constraints

- Branch from `bd3cf27` so `FileTag` and `TagProvider` are shared with the scoped-tag worktree.
- Do not modify the scoped-tag plan's hot files: `FileItem.swift`, local/remote providers, `AppModel.swift`, `FileTableRepresentable.swift`, or `FilePaneView.swift`.
- Do not read or write Finder private xattrs from Python.
- Do not migrate the React, HTTP, WebSocket, browser-launch, delete, reveal, or Python `store.json` layers.
- Every protocol payload carries `schemaVersion = 1` and rejects unsupported versions at its trust boundary.
- Store analysis suggestions separately from `FileTag`; map them only in the tag adapter so confidence and model provenance are not lost.
- Record only tags actually introduced by the analyzer in the managed-tag ledger; pre-existing user tags are never analyzer-owned.
- Use TDD for Swift and Python behavior. Real ML inference is an optional smoke test; deterministic CI uses a fake pipeline.
- Do not commit unless the user explicitly asks for a commit.

---

## Task 1: Add versioned Swift analysis contracts

**Files:**

- Create: `Sources/OpenFinderCore/VideoAnalysis/VideoAnalysisModels.swift`
- Create: `Sources/OpenFinderCore/VideoAnalysis/VideoAnalysisEvents.swift`
- Create: `Tests/OpenFinderCoreTests/VideoAnalysisModelTests.swift`

**Interfaces:**

- Produces `VideoAnalysisRequest`, `VideoAnalysisOptions`, `VideoAnalysisResult`, `VideoFrameAnalysis`, `VideoAnalysisTagSuggestion`, `VideoAnalysisProgress`, and `VideoAnalysisWorkerEvent`.
- Produces `VideoAnalysisWorkerEventParser.parse(line:)` for versioned NDJSON.

- [ ] Write failing Codable round-trip, unsupported-schema, malformed-event, and exhaustive event tests.
- [ ] Run `swift test --filter VideoAnalysisModelTests` and capture the expected RED output.
- [ ] Implement minimal Foundation-only values and typed parsing errors.
- [ ] Run the focused suite GREEN, then `swift test --filter PluginSystemTests`.

## Task 2: Add atomic result storage and managed-analysis-tag ledger

**Files:**

- Create: `Sources/OpenFinderCore/VideoAnalysis/VideoAnalysisResultStore.swift`
- Create: `Sources/OpenFinderCore/VideoAnalysis/ManagedAnalysisTagLedger.swift`
- Create: `Tests/OpenFinderCoreTests/VideoAnalysisResultStoreTests.swift`
- Create: `Tests/OpenFinderCoreTests/ManagedAnalysisTagLedgerTests.swift`

**Interfaces:**

- Produces `VideoFileFingerprint`, `StoredVideoAnalysis`, and actor `VideoAnalysisResultStore`.
- Produces pure `ManagedAnalysisTagLedger.reconcile(current:suggested:previouslyManaged:)` returning additions, removals, and the next managed set.

- [ ] Write failing tests for atomic round-trip, stale fingerprint rejection, corrupted JSON, pre-existing manual tags, stale managed tags, and idempotent reconciliation.
- [ ] Run focused tests RED.
- [ ] Implement atomic temporary-file replacement and pure set reconciliation.
- [ ] Run focused tests GREEN and verify no product file outside `VideoAnalysis/` changed.

## Task 3: Extract a strict Python NDJSON worker

**Files:**

- Create: `ExamplePlugins/video-analyzer.plugin/worker/pyproject.toml`
- Create: `ExamplePlugins/video-analyzer.plugin/worker/video_analyzer_worker/models.py`
- Create: `ExamplePlugins/video-analyzer.plugin/worker/video_analyzer_worker/protocol.py`
- Create: `ExamplePlugins/video-analyzer.plugin/worker/video_analyzer_worker/pipeline.py`
- Create: `ExamplePlugins/video-analyzer.plugin/worker/video_analyzer_worker/main.py`
- Create: `ExamplePlugins/video-analyzer.plugin/worker/tests/test_protocol.py`
- Create: `ExamplePlugins/video-analyzer.plugin/worker/tests/test_main.py`

**Interfaces:**

- Consumes a versioned request JSON from stdin.
- Emits only versioned `log`, `progress`, and `result` NDJSON on stdout; human diagnostics go to stderr.
- `AnalysisPipeline` is a Protocol so tests can use a deterministic fake without loading Torch or models.

- [ ] Add strict pytest/Pydantic tests for valid requests, unsupported versions, malformed JSON, deterministic stage ordering, failure output, and cancellation exit behavior.
- [ ] Run `uv run pytest` RED.
- [ ] Implement the boundary models, protocol encoder, fake/test pipeline seam, and CLI entry point.
- [ ] Run pytest, ruff, basedpyright, and the no-excuse audit GREEN.
- [ ] Add the existing scene/keyframe/NudeNet/JoyTag pipeline behind the protocol without importing Web UI or Finder modules.

## Task 4: Add the built-in video analyzer plugin and runtime preflight

**Files:**

- Create: `ExamplePlugins/video-analyzer.plugin/manifest.json`
- Create: `ExamplePlugins/video-analyzer.plugin/run.py`
- Create: `Tests/OpenFinderCoreTests/VideoAnalyzerPluginTests.swift`
- Modify: `script/build_and_run.sh` only if the existing built-in plugin staging does not already include the new directory.

**Interfaces:**

- Matches supported local video extensions and accepts one or more selected files.
- Adapts `PluginInput` to `VideoAnalysisRequest` and translates worker progress/results to the existing OpenFinder plugin NDJSON protocol.
- Returns typed artifacts for result JSON and optional HTML export.

- [ ] Write failing manifest matching and real subprocess protocol tests.
- [ ] Run focused tests RED.
- [ ] Implement manifest, preflight errors for Python/ffmpeg/dependencies, and adapter.
- [ ] Run focused tests GREEN and invoke the plugin against a temporary deterministic fake-worker fixture.

## Task 5: Add video task kind and single-concurrency resource lane

**Files:**

- Modify: `Sources/OpenFinderCore/Tasks/TaskModels.swift`
- Modify: `Sources/OpenFinderCore/Tasks/TaskQueueService.swift`
- Modify: `Tests/OpenFinderCoreTests/TaskQueueTests.swift`

**Interfaces:**

- Adds `TaskKind.videoAnalysis`.
- Adds an optional resource key to `TaskRequest`; requests sharing `video-analysis` never overlap even when ordinary queue concurrency is greater than one.

- [ ] Write failing tests proving two analysis tasks serialize while an unrelated file task can execute concurrently and queued cancellation releases no resource.
- [ ] Run focused tests RED.
- [ ] Implement the smallest actor-owned resource-lane scheduler.
- [ ] Run `TaskQueueTests` GREEN and verify retry/cancel behavior remains intact.

## Task 6: Complete integration verification and conflict audit

**Files:**

- Create: `artifacts/video-analysis-qa/` evidence only; do not stage.
- Modify documentation only when behavior is proven.

- [ ] Run Python unit/type/lint gates.
- [ ] Run Swift focused suites, `swift test --parallel`, and `swift build`.
- [ ] Execute one real subprocess round-trip with a fake pipeline and capture stdout/stderr/result artifacts.
- [ ] Run `git diff --check`, scan for private Finder xattrs, and compare changed paths against the scoped-tag plan's file list.
- [ ] Inspect every changed source file for single responsibility, strict boundary parsing, cancellation cleanup, and files over 250 pure LOC.
- [ ] Report remaining production risks: external runtime packaging, model download/licensing, and real-model smoke testing.

## Plan Self-Review

- The plan delivers all six approved parallel-safe tasks without touching tag UI/provider implementation.
- Python and Swift boundaries share schema version 1 and corresponding malformed-input tests.
- Tag provenance remains owned by the video module, while Finder mutation remains owned by `TagProvider` after the tag branch reaches its integration gate.
- UI integration is intentionally excluded until scoped-tag Tasks 7–9 stabilize.
