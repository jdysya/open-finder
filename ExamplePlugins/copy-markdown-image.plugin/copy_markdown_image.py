#!/usr/bin/env python3
import json
import pathlib
import sys

payload = json.load(sys.stdin)
links = []
for item in payload.get("files", []):
    path = pathlib.Path(item["path"])
    alt = path.stem.replace("-", " ").replace("_", " ")
    links.append(f"![{alt}]({path.as_uri()})")
print(json.dumps({"type": "progress", "fraction": 1.0, "message": "Markdown links generated"}))
print(json.dumps({"type": "result", "status": "success", "message": f"Generated {len(links)} link(s)", "clipboard": "\n".join(links)}))
