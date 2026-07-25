#!/bin/zsh

/usr/bin/python3 -c '
import json
import sys
import uuid

try:
    invocation = json.load(sys.stdin)
    if invocation.get("actionID") != "inspect-spectrum":
        raise ValueError("unsupported action")
    task_id = str(uuid.UUID(invocation["taskID"]))
    if not isinstance(invocation.get("files"), list) or not invocation["files"]:
        raise ValueError("missing selected file")
    selected_file = invocation["files"][0]
    source_path = selected_file["path"]
    display_name = selected_file["name"]
    if not isinstance(source_path, str) or not source_path:
        raise ValueError("missing selected file path")
    if not isinstance(display_name, str) or not display_name:
        raise ValueError("missing selected file name")

    document_id = str(uuid.uuid4())
    document = {
        "schemaID": "mediaAnalysis.v1",
        "schemaVersion": 1,
        "documentID": document_id,
        "taskID": task_id,
        "items": [{
            "media": {
                "stableID": "spectrum-fixture:" + document_id,
                "sourcePath": source_path,
                "displayName": display_name,
            },
            "summaryMetrics": [{"key": "spectrumPeak", "value": 1.0, "unit": "score"}],
            "facets": [{"key": "analysisKind", "value": "spectrum"}],
            "moments": [{
                "index": 0,
                "timestamp": 0,
                "summary": "Spectrum inspection completed.",
                "facets": [],
                "assets": [],
                "suggestedTags": [],
            }],
            "suggestedTags": [],
            "report": None,
        }],
        "suggestedTags": [],
        "actions": [],
        "managedTagLedger": {"mediaEntries": []},
        "createdAt": "2025-01-01T00:00:00Z",
    }
    event = {
        "type": "result",
        "status": "success",
        "message": "Spectrum inspection completed.",
        "artifacts": [{"type": "mediaAnalysis.v1", "content": json.dumps(document, separators=(",", ":"))}],
    }
except (KeyError, TypeError, ValueError, json.JSONDecodeError):
    event = {"type": "result", "status": "failure", "message": "Invalid plugin input."}

print(json.dumps(event, separators=(",", ":")))
'
