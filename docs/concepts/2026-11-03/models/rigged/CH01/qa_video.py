#!/usr/bin/env python3
"""Read-only ffprobe metadata/decode-count verification of the demo video."""
import argparse
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video", type=Path)
    parser.add_argument("--ffprobe", default=shutil.which("ffprobe") or r"C:\ffmpeg\bin\ffprobe.exe")
    parser.add_argument("--expected-frames", type=int, default=403)
    args = parser.parse_args()
    before = hashlib.sha256(args.video.read_bytes()).hexdigest()
    result = subprocess.run([args.ffprobe, "-v", "error", "-count_frames", "-show_streams",
                             "-show_format", "-of", "json", str(args.video.resolve())],
                            capture_output=True, text=True, check=True)
    data = json.loads(result.stdout)
    streams = [s for s in data["streams"] if s["codec_type"] == "video"]
    errors, warnings = [], []
    if len(streams) != 1:
        errors.append("Expected one video stream")
    stream = streams[0] if streams else {}
    try:
        fps = float(Fraction(stream.get("avg_frame_rate", "0")))
    except (ValueError, ZeroDivisionError):
        fps = 0.0
        errors.append("Invalid frame-rate metadata")
    duration = float(data["format"].get("duration", 0))
    if stream.get("codec_name") != "h264":
        errors.append("Video is not H.264")
    if (stream.get("width", 0), stream.get("height", 0)) != (1920, 1080):
        errors.append("Resolution differs from intended 1920x1080")
    if abs(fps - 30.0) > .001:
        errors.append("Frame rate is not 30 fps")
    if not 12 <= duration <= 16:
        errors.append("Duration outside requested 12-16 seconds")
    if stream.get("pix_fmt") != "yuv420p":
        warnings.append("Pixel format is not standard yuv420p")
    if not stream.get("color_space"):
        warnings.append("Color-space metadata absent; color appearance needs visual review")
    for field in ("color_space", "color_transfer", "color_primaries"):
        if stream.get(field) not in (None, "bt709"):
            warnings.append(field + " differs from intended bt709")
    if stream.get("nb_frames") and stream.get("nb_read_frames") and stream["nb_frames"] != stream["nb_read_frames"]:
        errors.append("Declared and decoded frame counts differ")
    try:
        decoded_frames = int(stream.get("nb_read_frames", ""))
    except ValueError:
        decoded_frames = None
    if decoded_frames != args.expected_frames:
        errors.append("Decoded frame count differs from expected " + str(args.expected_frames))
    if result.stderr.strip():
        errors.append("ffprobe reported decode errors: " + result.stderr.strip())
    report = {"file": str(args.video.resolve()), "ffprobe": str(args.ffprobe), "scope": "Metadata and successful decoded-frame count only; animation beauty, foot contacts and visual artifacts are separate",
              "duration_s": duration, "fps": fps, "file_bytes": args.video.stat().st_size,
              "decoded_frames": decoded_frames, "expected_frames": args.expected_frames,
              "source_sha256": before, "source_unchanged": before == hashlib.sha256(args.video.read_bytes()).hexdigest(),
              "video": stream, "errors": errors, "warnings": warnings,
              "status": "requires_correction" if errors else "video_metadata_checks_completed"}
    (HERE / "qa_video.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (HERE / "qa_video.txt").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in report.items() if key != "video"}))
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
