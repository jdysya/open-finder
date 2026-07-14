from __future__ import annotations

import io
import json
from typing import TYPE_CHECKING

from video_analyzer_worker.main import run
from video_analyzer_worker.models import (
    AnalysisSummary,
    AnalyzedVideo,
    VideoAnalysisProgress,
    VideoAnalysisRequest,
    VideoAnalysisResult,
)

if TYPE_CHECKING:
    from collections.abc import Callable


class FixturePipeline:
    def analyze(
        self,
        request: VideoAnalysisRequest,
        progress: Callable[[VideoAnalysisProgress], None],
    ) -> VideoAnalysisResult:
        progress(
            VideoAnalysisProgress(
                task_id=request.task_id,
                video_path=request.files[0].path,
                stage="preparing",
                detail="fixture",
                fraction=0.1,
            )
        )
        return VideoAnalysisResult(
            task_id=request.task_id,
            videos=(
                AnalyzedVideo(
                    path=request.files[0].path,
                    name=request.files[0].name,
                    summary=AnalysisSummary(
                        total_frames=0,
                        face_visible=0,
                        explicit=0,
                        moderate=0,
                        partial=0,
                        none=0,
                    ),
                ),
            ),
        )


def test_run_emits_progress_then_result() -> None:
    stdin = io.StringIO(
        json.dumps(
            {
                "schemaVersion": 1,
                "taskID": "11111111-1111-1111-1111-111111111111",
                "files": [{"path": "/Users/example/demo.mp4", "name": "demo.mp4"}],
                "options": {"useJoyTag": False},
                "outputDirectory": "/Users/example/output",
            }
        )
    )
    stdout = io.StringIO()
    stderr = io.StringIO()

    exit_code = run(stdin, stdout, stderr, FixturePipeline())

    events = stdout.getvalue().splitlines()
    assert exit_code == 0
    assert '"type":"progress"' in events[0]
    assert '"type":"result"' in events[1]
    assert '"name":"demo.mp4"' in events[1]
    assert stderr.getvalue() == ""


def test_run_reports_invalid_request_without_stdout_noise() -> None:
    stdout = io.StringIO()
    stderr = io.StringIO()

    exit_code = run(io.StringIO("not-json"), stdout, stderr, FixturePipeline())

    assert exit_code == 2
    assert stdout.getvalue() == ""
    assert "invalid request" in stderr.getvalue()
