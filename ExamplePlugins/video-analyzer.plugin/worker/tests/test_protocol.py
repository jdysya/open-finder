from __future__ import annotations

import json
from uuid import UUID

import pytest

from video_analyzer_worker.models import ProgressEvent, VideoAnalysisRequest
from video_analyzer_worker.protocol import UnsupportedSchemaVersionError, parse_request


def test_parse_request_accepts_version_one() -> None:
    raw = json.dumps(
        {
            "schemaVersion": 1,
            "taskID": "11111111-1111-1111-1111-111111111111",
            "files": [{"path": "/Users/example/demo.mp4", "name": "demo.mp4"}],
            "options": {"useJoyTag": True},
            "outputDirectory": "/Users/example/output",
        }
    )

    request = parse_request(raw)

    assert request == VideoAnalysisRequest.model_validate_json(raw)
    assert request.task_id == UUID("11111111-1111-1111-1111-111111111111")


def test_parse_request_rejects_unsupported_version() -> None:
    raw = json.dumps(
        {
            "schemaVersion": 2,
            "taskID": "11111111-1111-1111-1111-111111111111",
            "files": [],
            "options": {"useJoyTag": True},
            "outputDirectory": "/Users/example/output",
        }
    )

    with pytest.raises(UnsupportedSchemaVersionError) as captured:
        _ = parse_request(raw)

    assert captured.value.version == 2


def test_progress_event_serializes_swift_contract_field_names() -> None:
    event = ProgressEvent(
        task_id=UUID("11111111-1111-1111-1111-111111111111"),
        video_path="/Users/example/demo.mp4",
        stage="sceneDetection",
        detail="working",
        fraction=0.2,
    )

    payload = event.model_dump_json(by_alias=True)

    assert '"schemaVersion":1' in payload
    assert '"taskID":"11111111-1111-1111-1111-111111111111"' in payload
    assert '"videoPath":"/Users/example/demo.mp4"' in payload
    assert '"type":"progress"' in payload
