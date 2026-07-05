#!/usr/bin/env python3
import json
import pathlib
import subprocess
import sys

payload = json.load(sys.stdin)
files = payload.get("files", [])
if len(files) != 1:
    print(json.dumps({"type": "result", "status": "failure", "message": "Select exactly one .app bundle."}))
    sys.exit(0)

app_path = pathlib.Path(files[0]["path"])
if app_path.suffix.lower() != ".app" or not app_path.is_dir():
    print(json.dumps({"type": "result", "status": "failure", "message": f"Not an .app bundle: {app_path}"}))
    sys.exit(0)

print(json.dumps({"type": "progress", "fraction": 0.1, "message": f"Running sudo xattr for {app_path.name}"}), flush=True)
command = ["/usr/bin/sudo", "-n", "/usr/bin/xattr", "-dr", "com.apple.quarantine", str(app_path)]
result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
if result.returncode == 0:
    print(json.dumps({"type": "progress", "fraction": 1.0, "message": "Quarantine attribute removed"}))
    print(json.dumps({"type": "result", "status": "success", "message": f"Removed quarantine from {app_path}"}))
else:
    detail = result.stderr.strip() or result.stdout.strip() or f"sudo xattr exited with {result.returncode}"
    print(json.dumps({
        "type": "result",
        "status": "failure",
        "message": f"Could not remove quarantine from {app_path}. {detail}. If sudo needs a password, run sudo -v in Terminal first."
    }))
