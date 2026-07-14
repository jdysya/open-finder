from __future__ import annotations

import sys
from typing import TextIO

from pydantic import ValidationError

from video_analyzer_worker.legacy_pipeline import LegacyCliPipeline
from video_analyzer_worker.models import ProgressEvent, ResultEvent, VideoAnalysisProgress
from video_analyzer_worker.pipeline import AnalysisPipeline, WorkerExecutionError
from video_analyzer_worker.protocol import (
    UnsupportedSchemaVersionError,
    parse_request,
    serialize_event,
)


def run(stdin: TextIO, stdout: TextIO, stderr: TextIO, pipeline: AnalysisPipeline) -> int:
    try:
        request = parse_request(stdin.read())

        def emit_progress(progress: VideoAnalysisProgress) -> None:
            event = ProgressEvent(
                task_id=progress.task_id,
                video_path=progress.video_path,
                stage=progress.stage,
                detail=progress.detail,
                fraction=progress.fraction,
            )
            _ = stdout.write(f"{serialize_event(event)}\n")
            stdout.flush()

        result = pipeline.analyze(request, emit_progress)
        _ = stdout.write(f"{serialize_event(ResultEvent(result=result))}\n")
        stdout.flush()
    except (UnsupportedSchemaVersionError, ValidationError) as error:
        _ = stderr.write(f"invalid request: {error}\n")
        return 2
    except WorkerExecutionError as error:
        _ = stderr.write(f"analysis failed: {error}\n")
        return 1
    else:
        return 0


def main() -> int:
    return run(sys.stdin, sys.stdout, sys.stderr, LegacyCliPipeline.from_environment())


if __name__ == "__main__":
    raise SystemExit(main())
