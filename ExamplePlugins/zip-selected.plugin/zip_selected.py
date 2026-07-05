#!/usr/bin/env python3
import json
import pathlib
import sys
import zipfile

payload = json.load(sys.stdin)
output = pathlib.Path(payload["outputDirectory"]) / "openfinder-selection.zip"
files = payload.get("files", [])
with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
    for index, item in enumerate(files):
        source = pathlib.Path(item["path"])
        print(json.dumps({"type": "progress", "fraction": index / max(len(files), 1), "message": f"Adding {source.name}"}), flush=True)
        if source.is_dir():
            for child in source.rglob("*"):
                if child.is_file():
                    archive.write(child, child.relative_to(source.parent))
        elif source.is_file():
            archive.write(source, source.name)
print(json.dumps({"type": "progress", "fraction": 1.0, "message": "Archive complete"}))
print(json.dumps({"type": "result", "status": "success", "message": f"Created {output}", "clipboard": str(output)}))
