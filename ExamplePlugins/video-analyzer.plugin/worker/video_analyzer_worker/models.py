from __future__ import annotations

from typing import ClassVar, Literal, TypeAlias
from uuid import UUID

from pydantic import BaseModel, ConfigDict

AnalysisStage: TypeAlias = Literal[
    "preparing",
    "sceneDetection",
    "keyframeExtraction",
    "nudityAnalysis",
    "tagAnalysis",
    "reportGeneration",
    "finished",
]
NudityLevel: TypeAlias = Literal["none", "partial", "moderate", "explicit", "unknown"]


class ContractModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        frozen=True,
        alias_generator=lambda name: {
            "schema_version": "schemaVersion",
            "task_id": "taskID",
            "use_joy_tag": "useJoyTag",
            "output_directory": "outputDirectory",
            "frame_ratio": "frameRatio",
            "model_version": "modelVersion",
            "image_path": "imagePath",
            "face_visible": "faceVisible",
            "face_count": "faceCount",
            "nudity_level": "nudityLevel",
            "total_frames": "totalFrames",
            "suggested_tags": "suggestedTags",
            "report_path": "reportPath",
            "video_path": "videoPath",
        }.get(name, name),
        validate_by_name=True,
        extra="forbid",
    )


class AnalysisInputFile(ContractModel):
    path: str
    name: str


class AnalysisOptions(ContractModel):
    use_joy_tag: bool = True


class VideoAnalysisRequest(ContractModel):
    schema_version: int = 1
    task_id: UUID
    files: tuple[AnalysisInputFile, ...]
    options: AnalysisOptions = AnalysisOptions()
    output_directory: str


class TagSuggestion(ContractModel):
    name: str
    category: str
    confidence: float
    frame_ratio: float
    source: str
    model_version: str


class FrameAnalysis(ContractModel):
    index: int
    timestamp: float
    image_path: str
    face_visible: bool
    face_count: int
    nudity_level: NudityLevel
    summary: str
    tags: tuple[TagSuggestion, ...] = ()


class AnalysisSummary(ContractModel):
    total_frames: int
    face_visible: int
    explicit: int
    moderate: int
    partial: int
    none: int


class AnalyzedVideo(ContractModel):
    path: str
    name: str
    summary: AnalysisSummary
    frames: tuple[FrameAnalysis, ...] = ()
    suggested_tags: tuple[TagSuggestion, ...] = ()
    report_path: str | None = None


class VideoAnalysisResult(ContractModel):
    schema_version: Literal[1] = 1
    task_id: UUID
    videos: tuple[AnalyzedVideo, ...]


class VideoAnalysisProgress(ContractModel):
    task_id: UUID
    video_path: str
    stage: AnalysisStage
    detail: str
    fraction: float


class LogEvent(ContractModel):
    schema_version: Literal[1] = 1
    type: Literal["log"] = "log"
    level: str
    message: str


class ProgressEvent(ContractModel):
    schema_version: Literal[1] = 1
    type: Literal["progress"] = "progress"
    task_id: UUID
    video_path: str
    stage: AnalysisStage
    detail: str
    fraction: float


class ResultEvent(ContractModel):
    schema_version: Literal[1] = 1
    type: Literal["result"] = "result"
    result: VideoAnalysisResult


WorkerEvent: TypeAlias = LogEvent | ProgressEvent | ResultEvent
