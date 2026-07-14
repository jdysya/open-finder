from __future__ import annotations

import sys
from pathlib import Path
from typing import ClassVar, Literal, TextIO
from uuid import UUID

from pydantic import BaseModel, ConfigDict, ValidationError

from video_analyzer_worker.legacy_pipeline import LegacyCliPipeline
from video_analyzer_worker.models import (
    AnalysisInputFile,
    AnalysisOptions,
    VideoAnalysisProgress,
    VideoAnalysisRequest,
)
from video_analyzer_worker.pipeline import WorkerExecutionError


class _PluginModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        frozen=True,
        alias_generator=lambda name: {
            "schema_version": "schemaVersion",
            "task_id": "taskID",
            "is_directory": "isDirectory",
            "temp_directory": "tempDirectory",
            "output_directory": "outputDirectory",
        }.get(name, name),
        validate_by_name=True,
        extra="ignore",
    )


class _PluginInputFile(_PluginModel):
    path: str
    name: str
    is_directory: bool


class _PluginInput(_PluginModel):
    schema_version: int
    task_id: UUID
    files: tuple[_PluginInputFile, ...]
    config: dict[str, str]
    temp_directory: str
    output_directory: str


class PluginProgressEvent(_PluginModel):
    type: Literal["progress"] = "progress"
    fraction: float
    message: str


class PluginArtifact(_PluginModel):
    type: str
    content: str


class PluginResultEvent(_PluginModel):
    type: Literal["result"] = "result"
    status: Literal["success"] = "success"
    message: str
    artifacts: tuple[PluginArtifact, ...]


def run_plugin(stdin: TextIO, stdout: TextIO, stderr: TextIO) -> int:
    try:
        plugin_input = _PluginInput.model_validate_json(stdin.read())
        if plugin_input.schema_version != 1:
            _ = stderr.write(f"unsupported plugin input schema: {plugin_input.schema_version}\n")
            return 2
        analyzer_root = plugin_input.config.get("analyzerRoot", "").strip()
        if not analyzer_root:
            _ = stderr.write("plugin configuration analyzerRoot is required\n")
            return 2
        files = tuple(
            AnalysisInputFile(path=item.path, name=item.name)
            for item in plugin_input.files
            if not item.is_directory
        )
        request = VideoAnalysisRequest(
            task_id=plugin_input.task_id,
            files=files,
            options=AnalysisOptions(
                use_joy_tag=plugin_input.config.get("useJoyTag", "true") == "true"
            ),
            output_directory=plugin_input.temp_directory,
        )
        pipeline = LegacyCliPipeline(
            Path(analyzer_root).expanduser().resolve(),
            plugin_input.config.get("analyzerPython", "").strip() or sys.executable,
        )

        def emit_progress(progress: VideoAnalysisProgress) -> None:
            event = PluginProgressEvent(
                fraction=progress.fraction,
                message=f"{progress.stage}: {progress.detail}",
            )
            _ = stdout.write(f"{event.model_dump_json(by_alias=True)}\n")
            stdout.flush()

        result = pipeline.analyze(request, emit_progress)
        artifact = PluginArtifact(
            type="videoAnalysisResult",
            content=result.model_dump_json(by_alias=True, exclude_none=True),
        )
        event = PluginResultEvent(
            message=f"Analyzed {len(result.videos)} video(s)", artifacts=(artifact,)
        )
        _ = stdout.write(f"{event.model_dump_json(by_alias=True)}\n")
        stdout.flush()
    except ValidationError as error:
        _ = stderr.write(f"invalid plugin input: {error}\n")
        return 2
    except WorkerExecutionError as error:
        _ = stderr.write(f"analysis failed: {error}\n")
        return 1
    else:
        return 0


def main() -> int:
    return run_plugin(sys.stdin, sys.stdout, sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
