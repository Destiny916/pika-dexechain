#!/usr/bin/env python3
"""pika-migrate entrypoint for post-collection episode screening."""

from __future__ import annotations

import os
from pathlib import Path
import runpy
import sys


def main() -> None:
    script_dir = Path(__file__).resolve().parent
    app_dir = Path(os.environ.get("APP_DIR", script_dir.parent)).resolve()
    pika_dir = Path(os.environ.get("PIKA_DIR", app_dir / "pika")).resolve()
    target = pika_dir / "pika_ros" / "scripts" / "screen_episodes.py"
    if not target.is_file():
        raise SystemExit(f"screen_episodes.py not found: {target}")
    sys.argv[0] = str(target)
    runpy.run_path(str(target), run_name="__main__")


if __name__ == "__main__":
    main()
