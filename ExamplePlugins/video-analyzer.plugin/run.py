#!/usr/bin/env python3

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path


def main() -> int:
    uv = shutil.which("uv")
    if uv is None:
        _ = sys.stderr.write("video analyzer requires uv on PATH\n")
        return 2
    worker = Path(__file__).parent / "worker"
    environment = os.environ.copy()
    _ = environment.pop("VIRTUAL_ENV", None)
    cache_root = Path.home() / "Library/Caches/OpenFinder/VideoAnalyzerWorker"
    _ = environment.setdefault("UV_PROJECT_ENVIRONMENT", str(cache_root / "venv"))
    _ = environment.setdefault("UV_CACHE_DIR", str(cache_root / "uv-cache"))
    payload = sys.stdin.buffer.read()
    try:
        completed = subprocess.run(
            [
                uv,
                "run",
                "--directory",
                str(worker),
                "--project",
                str(worker),
                "python",
                "-m",
                "video_analyzer_worker.plugin_adapter",
            ],
            input=payload,
            stdout=sys.stdout.buffer,
            stderr=sys.stderr.buffer,
            env=environment,
            check=False,
        )
    except OSError as error:
        _ = sys.stderr.write(f"unable to launch video analyzer worker: {error}\n")
        return 2
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
