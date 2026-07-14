from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import ClassVar, final

from pydantic import BaseModel, ConfigDict, ValidationError

from video_analyzer_worker.models import (
    AnalysisSummary,
    AnalyzedVideo,
    FrameAnalysis,
    NudityLevel,
    TagSuggestion,
    VideoAnalysisProgress,
    VideoAnalysisRequest,
    VideoAnalysisResult,
)
from video_analyzer_worker.pipeline import ProgressCallback, WorkerExecutionError

_TAG_CONFIDENCE_THRESHOLD = 0.5


class _LegacyModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, extra="ignore")


class _LegacyTag(_LegacyModel):
    tag: str
    zh: str
    score: float


class _LegacyFrame(_LegacyModel):
    frame_path: str
    timestamp: float
    face_visible: bool
    face_count: int
    nudity_level: NudityLevel
    summary: str
    adult_tags: tuple[_LegacyTag, ...] = ()
    scene_tags: tuple[_LegacyTag, ...] = ()


class _LegacyReport(_LegacyModel):
    video_name: str
    total_frames: int
    frames: tuple[_LegacyFrame, ...]


@final
class LegacyCliPipeline:
    _engine_root: Path
    _python_executable: str

    def __init__(self, engine_root: Path, python_executable: str) -> None:
        self._engine_root = engine_root
        self._python_executable = python_executable

    @classmethod
    def from_environment(cls) -> LegacyCliPipeline:
        root = os.environ.get("OPENFINDER_VIDEO_ANALYZER_ROOT", "").strip()
        if not root:
            raise WorkerExecutionError(
                detail="OPENFINDER_VIDEO_ANALYZER_ROOT must point to the video-analyzer checkout"
            )
        executable = os.environ.get("OPENFINDER_VIDEO_ANALYZER_PYTHON", sys.executable)
        return cls(Path(root).expanduser().resolve(), executable)

    def analyze(
        self,
        request: VideoAnalysisRequest,
        progress: ProgressCallback,
    ) -> VideoAnalysisResult:
        entry = self._engine_root / "main.py"
        if not entry.is_file():
            raise WorkerExecutionError(detail=f"video analyzer entry point not found: {entry}")
        if not request.files:
            raise WorkerExecutionError(detail="video analysis request contains no files")

        videos: list[AnalyzedVideo] = []
        total = len(request.files)
        for index, input_file in enumerate(request.files):
            progress(
                VideoAnalysisProgress(
                    task_id=request.task_id,
                    video_path=input_file.path,
                    stage="preparing",
                    detail=f"starting {input_file.name}",
                    fraction=index / total,
                )
            )
            video_path = Path(input_file.path)
            if not video_path.is_file():
                raise WorkerExecutionError(detail=f"video file not found: {video_path}")
            report_directory = Path(request.output_directory) / f"{index:04d}"
            report_directory.mkdir(parents=True, exist_ok=True)
            command = [
                self._python_executable,
                str(entry),
                str(video_path),
                "--output",
                str(report_directory),
            ]
            if not request.options.use_joy_tag:
                command.append("--no-joytag")
            try:
                # The executable and checkout are explicit user configuration; no shell is used.
                completed = subprocess.run(  # noqa: S603
                    command,
                    cwd=self._engine_root,
                    capture_output=True,
                    text=True,
                    check=False,
                )
            except OSError as error:
                raise WorkerExecutionError(detail=f"unable to start analyzer: {error}") from error
            if completed.returncode != 0:
                detail = completed.stderr.strip() or completed.stdout.strip()
                raise WorkerExecutionError(
                    detail=detail or f"video analyzer exited with {completed.returncode}"
                )
            report_path = self._single_report(report_directory)
            videos.append(self._convert_report(input_file.path, report_path))
            progress(
                VideoAnalysisProgress(
                    task_id=request.task_id,
                    video_path=input_file.path,
                    stage="finished",
                    detail=f"finished {input_file.name}",
                    fraction=(index + 1) / total,
                )
            )
        return VideoAnalysisResult(task_id=request.task_id, videos=tuple(videos))

    @staticmethod
    def _single_report(directory: Path) -> Path:
        reports = sorted(directory.glob("*.json"))
        if len(reports) != 1:
            raise WorkerExecutionError(
                detail=f"expected one JSON report in {directory}, found {len(reports)}"
            )
        return reports[0]

    @staticmethod
    def _convert_report(video_path: str, report_path: Path) -> AnalyzedVideo:
        try:
            report = _LegacyReport.model_validate_json(report_path.read_text(encoding="utf-8"))
        except (OSError, ValidationError) as error:
            raise WorkerExecutionError(
                detail=f"invalid analyzer report {report_path}: {error}"
            ) from error
        total = len(report.frames)
        frames = tuple(
            FrameAnalysis(
                index=index,
                timestamp=frame.timestamp,
                image_path=frame.frame_path,
                face_visible=frame.face_visible,
                face_count=frame.face_count,
                nudity_level=frame.nudity_level,
                summary=frame.summary,
                tags=LegacyCliPipeline._frame_tags(frame, total),
            )
            for index, frame in enumerate(report.frames)
        )
        return AnalyzedVideo(
            path=video_path,
            name=report.video_name,
            summary=AnalysisSummary(
                total_frames=report.total_frames,
                face_visible=sum(frame.face_visible for frame in report.frames),
                explicit=sum(frame.nudity_level == "explicit" for frame in report.frames),
                moderate=sum(frame.nudity_level == "moderate" for frame in report.frames),
                partial=sum(frame.nudity_level == "partial" for frame in report.frames),
                none=sum(frame.nudity_level == "none" for frame in report.frames),
            ),
            frames=frames,
            suggested_tags=LegacyCliPipeline._aggregate_tags(report.frames),
            report_path=str(report_path.with_suffix(".html"))
            if report_path.with_suffix(".html").is_file()
            else None,
        )

    @staticmethod
    def _frame_tags(frame: _LegacyFrame, total_frames: int) -> tuple[TagSuggestion, ...]:
        denominator = max(total_frames, 1)
        return tuple(
            TagSuggestion(
                name=tag.zh or tag.tag,
                category=category,
                confidence=tag.score,
                frame_ratio=1 / denominator,
                source="joytag",
                model_version="legacy",
            )
            for category, tags in (("adult", frame.adult_tags), ("scene", frame.scene_tags))
            for tag in tags
        )

    @staticmethod
    def _aggregate_tags(frames: tuple[_LegacyFrame, ...]) -> tuple[TagSuggestion, ...]:
        stats: dict[tuple[str, str], tuple[int, float]] = {}
        for frame in frames:
            seen: set[tuple[str, str]] = set()
            for category, tags in (("adult", frame.adult_tags), ("scene", frame.scene_tags)):
                for tag in tags:
                    name = tag.zh or tag.tag
                    identity = (category, name)
                    if tag.score < _TAG_CONFIDENCE_THRESHOLD or identity in seen:
                        continue
                    count, confidence = stats.get(identity, (0, 0.0))
                    stats[identity] = (count + 1, max(confidence, tag.score))
                    seen.add(identity)
        total = max(len(frames), 1)
        return tuple(
            TagSuggestion(
                name=name,
                category=category,
                confidence=confidence,
                frame_ratio=count / total,
                source="joytag",
                model_version="legacy",
            )
            for (category, name), (count, confidence) in sorted(stats.items())
        )
