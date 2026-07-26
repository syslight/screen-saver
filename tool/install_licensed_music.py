#!/usr/bin/env python3
"""Install the reviewed, attributed music catalog into a display node directory."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("target", type=Path, help="Explicit smart_frame music directory")
    parser.add_argument(
        "--catalog",
        type=Path,
        default=Path(__file__).with_name("licensed_music_catalog.json"),
    )
    args = parser.parse_args()
    if not args.target.is_absolute():
        parser.error("target must be an absolute path")
    if shutil.which("curl") is None:
        parser.error("curl is required")

    catalog = json.loads(args.catalog.read_text(encoding="utf-8"))
    args.target.mkdir(parents=True, exist_ok=True)
    credits = [
        "smart_frame licensed music catalog",
        "",
        f"License: {catalog['license']} ({catalog['licenseUrl']})",
        f"Library policy: {catalog['libraryPolicyUrl']}",
        "",
    ]
    for track in catalog["tracks"]:
        mood_dir = args.target / track["mood"]
        mood_dir.mkdir(parents=True, exist_ok=True)
        destination = mood_dir / f"{track['title']} · {track['artist']}.mp3"
        pending = destination.with_suffix(".part")
        if not destination.exists() or destination.stat().st_size < 4096:
            command = [
                "curl",
                "--retry",
                "3",
                "-L",
                "--fail",
                "--show-error",
                "--silent",
                "-o",
                str(pending),
                track["downloadUrl"],
            ]
            subprocess.run(command, check=True)
            pending.replace(destination)
            print(f"downloaded {destination.name}")
        else:
            print(f"kept {destination.name}")
        credits.extend(
            [
                f"{track['title']} by {track['artist']}",
                f"Source: {track['sourcePage']}",
                f"License: {catalog['license']} {catalog['licenseUrl']}",
                "",
            ]
        )
    (args.target / "ATTRIBUTION.txt").write_text(
        "\n".join(credits), encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
