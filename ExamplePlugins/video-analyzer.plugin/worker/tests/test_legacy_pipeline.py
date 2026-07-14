from __future__ import annotations

import json
import sys
from typing import TYPE_CHECKING
from uuid import UUID

import pytest

from video_analyzer_worker.legacy_pipeline import LegacyCliPipeline
from video_analyzer_worker.models import (
    AnalysisInputFile,
    AnalysisOptions,
    VideoAnalysisProgress,
    VideoAnalysisRequest,
)
from video_analyzer_worker.pipeline import WorkerExecutionError

if TYPE_CHECKING:
    from pathlib import Path


def test_legacy_pipeline_converts_report_and_aggregates_tags(tmp_path: Path) -> None:
    engine_root = tmp_path / "engine"
    engine_root.mkdir()
    output = tmp_path / "output"
    video = tmp_path / "demo.mp4"
    _ = video.write_bytes(b"fixture")
    _write_fixture_engine(engine_root / "main.py")
    request = VideoAnalysisRequest(
        task_id=UUID("11111111-1111-1111-1111-111111111111"),
        files=(AnalysisInputFile(path=str(video), name=video.name),),
        options=AnalysisOptions(use_joy_tag=True),
        output_directory=str(output),
    )
    progress: list[VideoAnalysisProgress] = []

    result = LegacyCliPipeline(engine_root, sys.executable).analyze(request, progress.append)

    analyzed = result.videos[0]
    assert analyzed.summary.total_frames == 2
    assert analyzed.summary.partial == 1
    assert analyzed.summary.none == 1
    assert analyzed.suggested_tags[0].name == "卧室"
    assert analyzed.suggested_tags[0].frame_ratio == 1.0
    assert [item.stage for item in progress] == ["preparing", "finished"]


def test_legacy_pipeline_reports_subprocess_failure(tmp_path: Path) -> None:
    engine_root = tmp_path / "engine"
    engine_root.mkdir()
    _ = (engine_root / "main.py").write_text(
        "import sys\nsys.stderr.write('model unavailable')\nraise SystemExit(4)\n",
        encoding="utf-8",
    )
    video = tmp_path / "demo.mp4"
    _ = video.write_bytes(b"fixture")
    request = VideoAnalysisRequest(
        task_id=UUID("11111111-1111-1111-1111-111111111111"),
        files=(AnalysisInputFile(path=str(video), name=video.name),),
        output_directory=str(tmp_path / "output"),
    )

    with pytest.raises(WorkerExecutionError, match="model unavailable"):
        _ = LegacyCliPipeline(engine_root, sys.executable).analyze(request, lambda _progress: None)


def _write_fixture_engine(path: Path) -> None:
    report = {
        "video_name": "demo.mp4",
        "total_frames": 2,
        "frames": [
            {
                "frame_path": "/tmp/frame-1.jpg",
                "timestamp": 1.0,
                "face_visible": True,
                "face_count": 1,
                "nudity_level": "partial",
                "summary": "frame 1",
                "adult_tags": [],
                "scene_tags": [{"tag": "bedroom", "zh": "卧室", "score": 0.9}],
            },
            {
                "frame_path": "/tmp/frame-2.jpg",
                "timestamp": 2.0,
                "face_visible": False,
                "face_count": 0,
                "nudity_level": "none",
                "summary": "frame 2",
                "adult_tags": [],
                "scene_tags": [{"tag": "bedroom", "zh": "卧室", "score": 0.8}],
            },
        ],
    }
    payload = json.dumps(report)
    script = (
        "import argparse, json, pathlib\n"
        "parser = argparse.ArgumentParser()\n"
        "parser.add_argument('video')\n"
        "parser.add_argument('--output', required=True)\n"
        "parser.add_argument('--no-joytag', action='store_true')\n"
        "args = parser.parse_args()\n"
        "out = pathlib.Path(args.output)\n"
        "out.mkdir(parents=True, exist_ok=True)\n"
        f"(out / 'fixture.json').write_text({payload!r}, encoding='utf-8')\n"
    )
    _ = path.write_text(script, encoding="utf-8")
