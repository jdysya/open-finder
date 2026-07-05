#!/usr/bin/env python3
import hashlib
import json
import pathlib
import sys

payload = json.load(sys.stdin)
links = []
files = payload.get("files", [])
for index, item in enumerate(files):
    name = item["name"]
    digest = hashlib.sha1(item["path"].encode()).hexdigest()[:10]
    print(json.dumps({"type": "progress", "fraction": index / max(len(files), 1), "message": f"Uploading {name}"}), flush=True)
    url = f"https://example.invalid/openfinder/{digest}/{name}"
    links.append(f"![{pathlib.Path(name).stem}]({url})")
print(json.dumps({"type": "progress", "fraction": 1.0, "message": "Demo upload complete"}))
print(json.dumps({"type": "result", "status": "success", "message": f"Uploaded {len(files)} demo file(s)", "clipboard": "\n".join(links)}))
