#!/usr/bin/env python3
"""Validate local DLSM captures and produce a session-safe pair manifest."""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SUPPORTED_LAYOUTS = {
    "BGRA8": (".bgra", 4),
    "L8": (".luma", 1),
}


@dataclass(frozen=True)
class CapturedFrame:
    metadata_path: Path
    pixels_path: Path
    metadata: dict[str, Any]

    @property
    def frame_id(self) -> int:
        return int(self.metadata["frameID"])

    @property
    def session_id(self) -> str:
        return str(self.metadata.get("sessionID", "legacy"))

    @property
    def sequence_index(self) -> int:
        return int(self.metadata.get("sequenceIndex", self.frame_id))

    @property
    def capture_group(self) -> str:
        return str(self.metadata.get("captureGroup", self.session_id))

    @property
    def pixel_layout(self) -> str:
        return str(self.metadata["pixelLayout"])

    @property
    def coarse_scale(self) -> int:
        return int(self.metadata.get("coarseScale", 4))


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Validate Sol's local Temporal captures, keep sessions isolated, "
            "and identify truly adjacent pairs for an offline flow teacher."
        )
    )
    parser.add_argument("capture_directory", type=Path)
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Manifest path (default: <capture_directory>/dataset-manifest.json)",
    )
    return parser.parse_args()


def payload_path(metadata_path: Path, pixel_layout: str) -> Path:
    try:
        extension, _ = SUPPORTED_LAYOUTS[pixel_layout]
    except KeyError as error:
        raise ValueError(
            f"unsupported pixel layout in {metadata_path.name}: {pixel_layout}"
        ) from error
    return metadata_path.with_suffix(extension)


def validate_metadata(metadata_path: Path, metadata: dict[str, Any]) -> None:
    schema_version = int(metadata.get("schemaVersion", 0))
    if schema_version not in (1, 2):
        raise ValueError(f"unsupported schema in {metadata_path.name}")

    pixel_layout = str(metadata.get("pixelLayout", ""))
    if pixel_layout not in SUPPORTED_LAYOUTS:
        raise ValueError(
            f"unsupported pixel layout in {metadata_path.name}: {pixel_layout}"
        )
    _, expected_bytes_per_pixel = SUPPORTED_LAYOUTS[pixel_layout]

    width = int(metadata["width"])
    height = int(metadata["height"])
    bytes_per_pixel = int(metadata["bytesPerPixel"])
    if width <= 0 or height <= 0:
        raise ValueError(f"invalid dimensions in {metadata_path.name}")
    if bytes_per_pixel != expected_bytes_per_pixel:
        raise ValueError(
            f"invalid bytesPerPixel in {metadata_path.name}: "
            f"{bytes_per_pixel}"
        )
    if int(metadata["frameID"]) < 0:
        raise ValueError(f"invalid frame ID in {metadata_path.name}")
    if int(metadata["presentationTimestampNanoseconds"]) < 0:
        raise ValueError(f"invalid timestamp in {metadata_path.name}")

    if schema_version == 2:
        if not str(metadata.get("sessionID", "")).strip():
            raise ValueError(f"missing session ID in {metadata_path.name}")
        if not str(metadata.get("captureGroup", "")).strip():
            raise ValueError(f"missing capture group in {metadata_path.name}")
        if int(metadata.get("sequenceIndex", 0)) < 1:
            raise ValueError(f"invalid sequence index in {metadata_path.name}")
        if int(metadata.get("captureInterval", 0)) < 1:
            raise ValueError(f"invalid capture interval in {metadata_path.name}")
        if int(metadata.get("coarseScale", 0)) != 4:
            raise ValueError(f"unsupported coarse scale in {metadata_path.name}")
        if int(metadata.get("sourceWidth", 0)) < width:
            raise ValueError(f"invalid source width in {metadata_path.name}")
        if int(metadata.get("sourceHeight", 0)) < height:
            raise ValueError(f"invalid source height in {metadata_path.name}")


def load_frames(capture_directory: Path) -> list[CapturedFrame]:
    frames: list[CapturedFrame] = []
    seen_sequence_keys: set[tuple[str, int]] = set()
    for metadata_path in sorted(capture_directory.glob("frame-*.json")):
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        validate_metadata(metadata_path, metadata)

        pixels_path = payload_path(
            metadata_path,
            str(metadata["pixelLayout"]),
        )
        if not pixels_path.is_file():
            raise ValueError(f"missing pixel payload for {metadata_path.name}")

        width = int(metadata["width"])
        height = int(metadata["height"])
        bytes_per_pixel = int(metadata["bytesPerPixel"])
        expected_size = width * height * bytes_per_pixel
        actual_size = pixels_path.stat().st_size
        if actual_size != expected_size:
            raise ValueError(
                f"{pixels_path.name} has {actual_size} bytes; "
                f"expected {expected_size}"
            )

        frame = CapturedFrame(
            metadata_path=metadata_path,
            pixels_path=pixels_path,
            metadata=metadata,
        )
        sequence_key = (frame.session_id, frame.sequence_index)
        if sequence_key in seen_sequence_keys:
            raise ValueError(
                "duplicate capture sequence index "
                f"{frame.sequence_index} in session {frame.session_id}"
            )
        seen_sequence_keys.add(sequence_key)
        frames.append(frame)

    frames.sort(
        key=lambda frame: (
            frame.session_id,
            frame.sequence_index,
            frame.frame_id,
        )
    )
    return frames


def pair_metadata(
    previous: CapturedFrame,
    current: CapturedFrame,
) -> dict[str, Any] | None:
    same_extent = (
        previous.metadata["width"] == current.metadata["width"]
        and previous.metadata["height"] == current.metadata["height"]
    )
    same_layout = previous.pixel_layout == current.pixel_layout
    same_scale = previous.coarse_scale == current.coarse_scale
    frame_gap = current.frame_id - previous.frame_id
    sequence_gap = current.sequence_index - previous.sequence_index
    delta_nanoseconds = (
        int(current.metadata["presentationTimestampNanoseconds"])
        - int(previous.metadata["presentationTimestampNanoseconds"])
    )
    current_is_cut = bool(current.metadata.get("discontinuity", False))
    if (
        not same_extent
        or not same_layout
        or not same_scale
        or frame_gap <= 0
        or sequence_gap <= 0
        or delta_nanoseconds <= 0
        or current_is_cut
    ):
        return None

    temporal_adjacent = frame_gap == 1 and sequence_gap == 1
    return {
        "previous": previous.pixels_path.name,
        "current": current.pixels_path.name,
        "previousMetadata": previous.metadata_path.name,
        "currentMetadata": current.metadata_path.name,
        "previousFrameID": previous.frame_id,
        "currentFrameID": current.frame_id,
        "frameGap": frame_gap,
        "sequenceGap": sequence_gap,
        "temporalAdjacent": temporal_adjacent,
        "deltaNanoseconds": delta_nanoseconds,
        "width": int(current.metadata["width"]),
        "height": int(current.metadata["height"]),
        "pixelLayout": current.pixel_layout,
        "coarseScale": current.coarse_scale,
        "sessionID": current.session_id,
        "captureGroup": current.capture_group,
    }


def make_pairs(frames: list[CapturedFrame]) -> list[dict[str, Any]]:
    frames_by_session: dict[str, list[CapturedFrame]] = defaultdict(list)
    for frame in frames:
        frames_by_session[frame.session_id].append(frame)

    pairs: list[dict[str, Any]] = []
    for session_id in sorted(frames_by_session):
        session_frames = sorted(
            frames_by_session[session_id],
            key=lambda frame: (frame.sequence_index, frame.frame_id),
        )
        for previous, current in zip(session_frames, session_frames[1:]):
            pair = pair_metadata(previous, current)
            if pair is not None:
                pairs.append(pair)
    return pairs


def session_summaries(
    frames: list[CapturedFrame],
    pairs: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    frames_by_session: dict[str, list[CapturedFrame]] = defaultdict(list)
    for frame in frames:
        frames_by_session[frame.session_id].append(frame)
    adjacent_by_session: dict[str, int] = defaultdict(int)
    for pair in pairs:
        if pair["temporalAdjacent"]:
            adjacent_by_session[str(pair["sessionID"])] += 1

    return [
        {
            "sessionID": session_id,
            "captureGroup": session_frames[0].capture_group,
            "frameCount": len(session_frames),
            "adjacentPairCount": adjacent_by_session[session_id],
        }
        for session_id, session_frames in sorted(frames_by_session.items())
    ]


def main() -> int:
    arguments = parse_arguments()
    capture_directory = arguments.capture_directory.expanduser().resolve()
    if not capture_directory.is_dir():
        raise SystemExit(f"capture directory does not exist: {capture_directory}")

    try:
        frames = load_frames(capture_directory)
        pairs = make_pairs(frames)
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(f"invalid capture: {error}") from error

    if len(frames) < 2:
        raise SystemExit("at least two valid captures are required")
    if not pairs:
        raise SystemExit("captures contained no safe within-session pairs")

    manifest_path = (
        arguments.output.expanduser().resolve()
        if arguments.output
        else capture_directory / "dataset-manifest.json"
    )
    adjacent_pair_count = sum(
        1 for pair in pairs if pair["temporalAdjacent"]
    )
    manifest = {
        "schemaVersion": 2,
        "frameCount": len(frames),
        "pairCount": len(pairs),
        "adjacentPairCount": adjacent_pair_count,
        "pixelLayouts": sorted({frame.pixel_layout for frame in frames}),
        "sessions": session_summaries(frames, pairs),
        "pairs": pairs,
    }
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(
        f"Prepared {len(pairs)} safe pairs from {len(frames)} frames "
        f"({adjacent_pair_count} truly adjacent): {manifest_path}"
    )
    if adjacent_pair_count == 0:
        print(
            "warning: no frame-gap-1 pairs are available; the dataset can "
            "supply image texture but not real-sequence motion labels"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
