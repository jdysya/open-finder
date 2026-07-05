#!/usr/bin/env python3
import json
import pathlib
import sys

payload = json.load(sys.stdin)
lines = []
for index, item in enumerate(payload.get("files", []), start=1):
    path = pathlib.Path(item["path"])
    new_name = f"{index:03d}-{path.name}"
    lines.append(f"{path.name} -> {new_name}")
print(json.dumps({"type": "progress", "fraction": 1.0, "message": "Preview generated"}))
print(json.dumps({"type": "result", "status": "success", "message": "Batch rename preview generated", "clipboard": "\n".join(lines)}))
