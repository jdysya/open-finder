from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import TYPE_CHECKING

from video_analyzer_worker.plugin_adapter import PluginProgressEvent, PluginResultEvent

if TYPE_CHECKING:
    from pydantic import JsonValue


def test_plugin_adapter_emits_existing_plugin_protocol(tmp_path: Path) -> None:
    engine_root = tmp_path / "engine"
    engine_root.mkdir()
    _write_fixture_engine(engine_root / "main.py")
    video = tmp_path / "demo.mp4"
    _ = video.write_bytes(b"fixture")
    output = tmp_path / "output"
    task_temp = tmp_path / "task-temp"
    plugin_input: dict[str, JsonValue] = {
        "schemaVersion": 1,
        "taskID": "11111111-1111-1111-1111-111111111111",
        "files": [
            {
                "path": str(video),
                "name": video.name,
                "extension": "mp4",
                "isDirectory": False,
            }
        ],
        "config": {
            "analyzerRoot": str(engine_root),
            "analyzerPython": sys.executable,
            "useJoyTag": "false",
        },
        "tempDirectory": str(task_temp),
        "outputDirectory": str(output),
    }
    run_script = Path(__file__).parents[2] / "run.py"

    completed = subprocess.run(  # noqa: S603
        [sys.executable, str(run_script)],
        input=json.dumps(plugin_input),
        capture_output=True,
        text=True,
        check=False,
    )

    lines = completed.stdout.splitlines()
    progress = PluginProgressEvent.model_validate_json(lines[0])
    result = PluginResultEvent.model_validate_json(lines[-1])
    assert completed.returncode == 0
    assert progress.fraction == 0.0
    assert result.status == "success"
    assert result.artifacts[0].type == "videoAnalysisResult"
    assert '"name":"demo.mp4"' in result.artifacts[0].content
    assert task_temp.joinpath("0000", "fixture.json").is_file()
    assert not output.exists()
    assert completed.stderr == ""


def test_plugin_adapter_requires_analyzer_root() -> None:
    plugin_input: dict[str, JsonValue] = {
        "schemaVersion": 1,
        "taskID": "11111111-1111-1111-1111-111111111111",
        "files": [],
        "config": {},
        "tempDirectory": "/Users/example/task-temp",
        "outputDirectory": "/Users/example/output",
    }
    run_script = Path(__file__).parents[2] / "run.py"

    completed = subprocess.run(  # noqa: S603
        [sys.executable, str(run_script)],
        input=json.dumps(plugin_input),
        capture_output=True,
        text=True,
        check=False,
    )

    assert completed.returncode == 2
    assert "analyzerRoot" in completed.stderr
    assert completed.stdout == ""


def _write_fixture_engine(path: Path) -> None:
    report: dict[str, JsonValue] = {
        "video_name": "demo.mp4",
        "total_frames": 0,
        "frames": [],
    }
    payload = json.dumps(report)
    script = (
        "import argparse, pathlib\n"
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
