from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Protocol, TypeAlias

from typing_extensions import override

from video_analyzer_worker.models import (
    VideoAnalysisProgress,
    VideoAnalysisRequest,
    VideoAnalysisResult,
)

ProgressCallback: TypeAlias = Callable[[VideoAnalysisProgress], None]


class AnalysisPipeline(Protocol):
    def analyze(
        self,
        request: VideoAnalysisRequest,
        progress: ProgressCallback,
    ) -> VideoAnalysisResult: ...


@dataclass(frozen=True, slots=True)
class WorkerExecutionError(Exception):
    detail: str

    @override
    def __str__(self) -> str:
        return self.detail
