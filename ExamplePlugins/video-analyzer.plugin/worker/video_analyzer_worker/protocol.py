from __future__ import annotations

from dataclasses import dataclass
from typing import ClassVar

from pydantic import BaseModel, ConfigDict, Field
from typing_extensions import override

from video_analyzer_worker.models import VideoAnalysisRequest, WorkerEvent


@dataclass(frozen=True, slots=True)
class UnsupportedSchemaVersionError(Exception):
    version: int

    @override
    def __str__(self) -> str:
        return f"unsupported video analysis schema version: {self.version}"


class _SchemaEnvelope(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, extra="ignore")

    schema_version: int = Field(alias="schemaVersion")


def parse_request(raw: str) -> VideoAnalysisRequest:
    envelope = _SchemaEnvelope.model_validate_json(raw)
    if envelope.schema_version != 1:
        raise UnsupportedSchemaVersionError(version=envelope.schema_version)
    return VideoAnalysisRequest.model_validate_json(raw)


def serialize_event(event: WorkerEvent) -> str:
    return event.model_dump_json(by_alias=True, exclude_none=True)
