#!/usr/bin/env python3
"""Train and compare Sol's compact Metal motion-and-reactive model.

The v2 trainer combines exact synthetic motion with a deterministic,
forward/backward-consistent block-flow teacher over truly adjacent local
captures. Captured pixels remain local; only compact model weights are written.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Sequence

try:
    import mlx.core as mx
    import mlx.nn as nn
    import mlx.optimizers as optim
    import numpy as np
except ImportError as error:
    print(
        "Training needs MLX and NumPy. Create a local environment and install "
        "them with: python3 -m venv .venv && .venv/bin/pip install mlx numpy",
        file=sys.stderr,
    )
    raise SystemExit(2) from error


SCHEMA_VERSION = 1
ARCHITECTURE = "sol-flow-reactive-2x3x3-v1"
COARSE_SCALE = 4
MOTION_LIMIT = 8.0
SEARCH_RADIUS = int(MOTION_LIMIT // COARSE_SCALE)


@dataclass(frozen=True)
class CaptureFrame:
    path: Path
    width: int
    height: int
    pixel_layout: str
    coarse_scale: int
    session_id: str
    capture_group: str


@dataclass(frozen=True)
class CapturePair:
    previous: CaptureFrame
    current: CaptureFrame
    session_id: str
    capture_group: str


@dataclass(frozen=True)
class SequenceTeacher:
    features: np.ndarray[Any, np.dtype[np.float32]]
    motion: np.ndarray[Any, np.dtype[np.float32]]
    reactive: np.ndarray[Any, np.dtype[np.float32]]


@dataclass(frozen=True)
class DatasetSplit:
    split_unit: str
    holdout_keys: tuple[str, ...]
    training_frames: tuple[CaptureFrame, ...]
    validation_frames: tuple[CaptureFrame, ...]
    training_pairs: tuple[CapturePair, ...]
    validation_pairs: tuple[CapturePair, ...]


class SolFlowReactiveModel(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.conv1 = nn.Conv2d(4, 8, 3, padding=1)
        self.conv2 = nn.Conv2d(8, 3, 3, padding=1)

    def __call__(self, inputs: mx.array) -> mx.array:
        return self.conv2(nn.relu(self.conv1(inputs)))


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Train a compact Sol Temporal model from one or more prepared "
            "local capture directories."
        )
    )
    parser.add_argument("capture_directories", type=Path, nargs="+")
    parser.add_argument(
        "--output",
        type=Path,
        help="Model JSON path (default: first capture/sol-temporal-v1.json)",
    )
    parser.add_argument("--steps", type=int, default=1_200)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--crop-size", type=int, default=64)
    parser.add_argument("--learning-rate", type=float, default=0.002)
    parser.add_argument("--validation-samples", type=int, default=128)
    parser.add_argument("--sequence-probability", type=float, default=0.5)
    parser.add_argument("--holdout-fraction", type=float, default=0.2)
    parser.add_argument(
        "--holdout-group",
        action="append",
        default=[],
        help="Capture-group label to reserve for validation (repeatable)",
    )
    parser.add_argument("--max-sequence-pairs", type=int, default=96)
    parser.add_argument(
        "--baseline-model",
        type=Path,
        default=None,
        help="Existing artifact to compare on the identical holdout",
    )
    parser.add_argument(
        "--from-scratch",
        action="store_true",
        help="Do not initialize from the baseline artifact",
    )
    parser.add_argument(
        "--full-finetune",
        action="store_true",
        help=(
            "Allow adjacent-sequence training to change shared and reactive "
            "weights; default baseline fine-tuning changes only motion output"
        ),
    )
    parser.add_argument("--seed", type=int, default=20260729)
    return parser.parse_args()


def validate_arguments(arguments: argparse.Namespace) -> None:
    if arguments.steps < 1:
        raise ValueError("--steps must be positive")
    if arguments.batch_size < 1:
        raise ValueError("--batch-size must be positive")
    if arguments.crop_size < 16:
        raise ValueError("--crop-size must be at least 16")
    if arguments.validation_samples < 1:
        raise ValueError("--validation-samples must be positive")
    if arguments.max_sequence_pairs < 1:
        raise ValueError("--max-sequence-pairs must be positive")
    if not math.isfinite(arguments.learning_rate) or arguments.learning_rate <= 0:
        raise ValueError("--learning-rate must be positive and finite")
    if not 0 <= arguments.sequence_probability <= 1:
        raise ValueError("--sequence-probability must be between zero and one")
    if not 0 < arguments.holdout_fraction < 1:
        raise ValueError("--holdout-fraction must be between zero and one")


def frame_from_metadata(
    capture_directory: Path,
    metadata_path: Path,
) -> CaptureFrame:
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    schema_version = int(metadata.get("schemaVersion", 0))
    if schema_version not in (1, 2):
        raise ValueError(f"unsupported schema in {metadata_path.name}")

    pixel_layout = str(metadata.get("pixelLayout", ""))
    if pixel_layout == "BGRA8":
        extension = ".bgra"
        bytes_per_pixel = 4
    elif pixel_layout == "L8":
        extension = ".luma"
        bytes_per_pixel = 1
    else:
        raise ValueError(
            f"unsupported pixel layout in {metadata_path.name}: {pixel_layout}"
        )

    path = metadata_path.with_suffix(extension)
    width = int(metadata["width"])
    height = int(metadata["height"])
    if not path.is_file() or path.stat().st_size != width * height * bytes_per_pixel:
        raise ValueError(f"invalid pixel payload: {path}")

    return CaptureFrame(
        path=path.resolve(),
        width=width,
        height=height,
        pixel_layout=pixel_layout,
        coarse_scale=int(metadata.get("coarseScale", COARSE_SCALE)),
        session_id=str(
            metadata.get(
                "sessionID",
                f"legacy-{capture_directory.name}",
            )
        ),
        capture_group=str(
            metadata.get(
                "captureGroup",
                f"legacy-{capture_directory.name}",
            )
        ),
    )


def discover_dataset(
    capture_directory: Path,
) -> tuple[list[CaptureFrame], list[CapturePair]]:
    manifest_path = capture_directory / "dataset-manifest.json"
    if not manifest_path.is_file():
        raise ValueError(
            f"{manifest_path} is missing; run "
            "prepare_sol_temporal_dataset.py first"
        )
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if int(manifest.get("schemaVersion", 0)) not in (1, 2):
        raise ValueError(f"unsupported manifest schema: {manifest_path}")

    frames = [
        frame_from_metadata(capture_directory, metadata_path)
        for metadata_path in sorted(capture_directory.glob("frame-*.json"))
    ]
    if len(frames) < 2:
        raise ValueError(
            f"at least two validated capture frames are required in "
            f"{capture_directory}"
        )
    frame_by_name = {frame.path.name: frame for frame in frames}

    pairs: list[CapturePair] = []
    for pair in manifest.get("pairs", []):
        temporal_adjacent = bool(
            pair.get(
                "temporalAdjacent",
                int(pair.get("frameGap", 0)) == 1,
            )
        )
        if not temporal_adjacent:
            continue
        previous = frame_by_name.get(str(pair.get("previous", "")))
        current = frame_by_name.get(str(pair.get("current", "")))
        if previous is None or current is None:
            raise ValueError(
                f"manifest pair references a missing payload in {manifest_path}"
            )
        if (
            previous.width != current.width
            or previous.height != current.height
            or previous.pixel_layout != current.pixel_layout
            or previous.coarse_scale != current.coarse_scale
            or previous.session_id != current.session_id
        ):
            raise ValueError(f"incompatible adjacent pair in {manifest_path}")
        pairs.append(
            CapturePair(
                previous=previous,
                current=current,
                session_id=current.session_id,
                capture_group=current.capture_group,
            )
        )
    return frames, pairs


def stable_score(value: str, seed: int) -> str:
    return hashlib.sha256(f"{seed}:{value}".encode("utf-8")).hexdigest()


def select_holdout_keys(
    keys: Sequence[str],
    fraction: float,
    seed: int,
) -> set[str]:
    unique = sorted(set(keys), key=lambda value: stable_score(value, seed))
    if len(unique) < 2:
        return set()
    count = max(1, int(round(len(unique) * fraction)))
    count = min(count, len(unique) - 1)
    return set(unique[-count:])


def split_dataset(
    frames: Sequence[CaptureFrame],
    pairs: Sequence[CapturePair],
    holdout_fraction: float,
    requested_holdout_groups: Sequence[str],
    seed: int,
) -> DatasetSplit:
    capture_groups = sorted({frame.capture_group for frame in frames})
    sessions = sorted({frame.session_id for frame in frames})

    requested = {
        value.strip()
        for value in requested_holdout_groups
        if value.strip()
    }
    unknown = requested.difference(capture_groups)
    if unknown:
        raise ValueError(
            "unknown --holdout-group value(s): " + ", ".join(sorted(unknown))
        )

    if requested:
        split_unit = "capture-group"
        holdout_keys = requested

        def key_for(frame: CaptureFrame) -> str:
            return frame.capture_group

    elif len(capture_groups) >= 2:
        split_unit = "capture-group"
        holdout_keys = select_holdout_keys(
            capture_groups,
            holdout_fraction,
            seed,
        )

        def key_for(frame: CaptureFrame) -> str:
            return frame.capture_group

    elif len(sessions) >= 2:
        split_unit = "session"
        holdout_keys = select_holdout_keys(
            sessions,
            holdout_fraction,
            seed,
        )

        def key_for(frame: CaptureFrame) -> str:
            return frame.session_id

    else:
        split_unit = "frame"
        frame_keys = [str(frame.path) for frame in frames]
        holdout_keys = select_holdout_keys(
            frame_keys,
            holdout_fraction,
            seed,
        )

        def key_for(frame: CaptureFrame) -> str:
            return str(frame.path)

    validation_frames = tuple(
        frame for frame in frames if key_for(frame) in holdout_keys
    )
    training_frames = tuple(
        frame for frame in frames if key_for(frame) not in holdout_keys
    )
    if len(training_frames) < 2 or not validation_frames:
        raise ValueError(
            "the deterministic holdout did not leave enough training and "
            "validation frames"
        )

    training_paths = {frame.path for frame in training_frames}
    validation_paths = {frame.path for frame in validation_frames}
    training_pairs = tuple(
        pair
        for pair in pairs
        if pair.previous.path in training_paths
        and pair.current.path in training_paths
    )
    validation_pairs = tuple(
        pair
        for pair in pairs
        if pair.previous.path in validation_paths
        and pair.current.path in validation_paths
    )
    return DatasetSplit(
        split_unit=split_unit,
        holdout_keys=tuple(sorted(holdout_keys)),
        training_frames=training_frames,
        validation_frames=validation_frames,
        training_pairs=training_pairs,
        validation_pairs=validation_pairs,
    )


def linear_resize_luminance(
    luminance: np.ndarray[Any, np.dtype[np.float32]],
    output_width: int,
    output_height: int,
) -> np.ndarray[Any, np.dtype[np.float32]]:
    input_height, input_width = luminance.shape
    x = (np.arange(output_width, dtype=np.float32) + 0.5) * (
        input_width / output_width
    ) - 0.5
    y = (np.arange(output_height, dtype=np.float32) + 0.5) * (
        input_height / output_height
    ) - 0.5
    x0 = np.floor(x).astype(np.int32)
    y0 = np.floor(y).astype(np.int32)
    x1 = np.clip(x0 + 1, 0, input_width - 1)
    y1 = np.clip(y0 + 1, 0, input_height - 1)
    x0 = np.clip(x0, 0, input_width - 1)
    y0 = np.clip(y0, 0, input_height - 1)
    fx = (x - x0).reshape(1, -1)
    fy = (y - y0).reshape(-1, 1)

    top = luminance[y0[:, None], x0[None, :]] * (1 - fx)
    top += luminance[y0[:, None], x1[None, :]] * fx
    bottom = luminance[y1[:, None], x0[None, :]] * (1 - fx)
    bottom += luminance[y1[:, None], x1[None, :]] * fx
    return (top * (1 - fy) + bottom * fy).astype(np.float32)


def load_model_luminance(
    frame: CaptureFrame,
) -> np.ndarray[Any, np.dtype[np.float32]]:
    if frame.pixel_layout == "L8":
        raw = np.memmap(
            frame.path,
            dtype=np.uint8,
            mode="r",
            shape=(frame.height, frame.width),
        )
        return (np.asarray(raw, dtype=np.float32) / 255.0).copy()

    raw = np.memmap(
        frame.path,
        dtype=np.uint8,
        mode="r",
        shape=(frame.height, frame.width, 4),
    )
    blue = raw[:, :, 0].astype(np.float32) / 255.0
    green = raw[:, :, 1].astype(np.float32) / 255.0
    red = raw[:, :, 2].astype(np.float32) / 255.0
    luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722
    coarse_width = (frame.width + COARSE_SCALE - 1) // COARSE_SCALE
    coarse_height = (frame.height + COARSE_SCALE - 1) // COARSE_SCALE
    return linear_resize_luminance(
        luminance,
        coarse_width,
        coarse_height,
    )


def load_images(
    frames: Sequence[CaptureFrame],
    crop_size: int,
) -> dict[Path, np.ndarray[Any, np.dtype[np.float32]]]:
    images = {
        frame.path: load_model_luminance(frame)
        for frame in frames
    }
    usable = {
        path: image
        for path, image in images.items()
        if image.shape[0] >= crop_size and image.shape[1] >= crop_size
    }
    if len(usable) < 2:
        raise ValueError(
            "capture frames are too small for the requested --crop-size"
        )
    return usable


def box_mean(
    values: np.ndarray[Any, np.dtype[np.float32]],
    radius: int,
) -> np.ndarray[Any, np.dtype[np.float32]]:
    if radius <= 0:
        return values
    padded = np.pad(values, ((radius, radius), (radius, radius)), mode="edge")
    integral = np.pad(padded, ((1, 0), (1, 0)), mode="constant")
    integral = integral.cumsum(axis=0).cumsum(axis=1)
    size = radius * 2 + 1
    sums = (
        integral[size:, size:]
        - integral[:-size, size:]
        - integral[size:, :-size]
        + integral[:-size, :-size]
    )
    return (sums / float(size * size)).astype(np.float32)


def shifted_sample(
    image: np.ndarray[Any, np.dtype[np.float32]],
    dx: int,
    dy: int,
) -> tuple[
    np.ndarray[Any, np.dtype[np.float32]],
    np.ndarray[Any, np.dtype[np.bool_]],
]:
    height, width = image.shape
    sampled = np.zeros_like(image)
    valid = np.zeros((height, width), dtype=np.bool_)

    current_x0 = max(0, -dx)
    current_x1 = min(width, width - dx)
    current_y0 = max(0, -dy)
    current_y1 = min(height, height - dy)
    if current_x0 < current_x1 and current_y0 < current_y1:
        sampled[current_y0:current_y1, current_x0:current_x1] = image[
            current_y0 + dy : current_y1 + dy,
            current_x0 + dx : current_x1 + dx,
        ]
        valid[current_y0:current_y1, current_x0:current_x1] = True
    return sampled, valid


def dense_match(
    current: np.ndarray[Any, np.dtype[np.float32]],
    previous: np.ndarray[Any, np.dtype[np.float32]],
) -> tuple[
    np.ndarray[Any, np.dtype[np.int16]],
    np.ndarray[Any, np.dtype[np.int16]],
    np.ndarray[Any, np.dtype[np.float32]],
    np.ndarray[Any, np.dtype[np.float32]],
    np.ndarray[Any, np.dtype[np.bool_]],
]:
    height, width = current.shape
    best_cost = np.full((height, width), np.inf, dtype=np.float32)
    second_cost = np.full((height, width), np.inf, dtype=np.float32)
    best_dx = np.zeros((height, width), dtype=np.int16)
    best_dy = np.zeros((height, width), dtype=np.int16)
    best_valid = np.zeros((height, width), dtype=np.bool_)

    for dy in range(-SEARCH_RADIUS, SEARCH_RADIUS + 1):
        for dx in range(-SEARCH_RADIUS, SEARCH_RADIUS + 1):
            sampled, valid = shifted_sample(previous, dx, dy)
            residual = np.abs(current - sampled)
            residual[~valid] = 1.0
            cost = box_mean(residual, radius=2)

            better = cost < best_cost
            second_cost = np.where(
                better,
                best_cost,
                np.minimum(second_cost, cost),
            )
            best_cost = np.where(better, cost, best_cost)
            best_dx = np.where(better, dx, best_dx)
            best_dy = np.where(better, dy, best_dy)
            best_valid = np.where(better, valid, best_valid)

    return best_dx, best_dy, best_cost, second_cost, best_valid


def gather_at_motion(
    values: np.ndarray[Any, Any],
    dx: np.ndarray[Any, np.dtype[np.int16]],
    dy: np.ndarray[Any, np.dtype[np.int16]],
) -> tuple[np.ndarray[Any, Any], np.ndarray[Any, np.dtype[np.bool_]]]:
    height, width = dx.shape
    y, x = np.indices((height, width))
    source_x = x + dx.astype(np.int32)
    source_y = y + dy.astype(np.int32)
    valid = (
        (source_x >= 0)
        & (source_x < width)
        & (source_y >= 0)
        & (source_y < height)
    )
    clipped_x = np.clip(source_x, 0, width - 1)
    clipped_y = np.clip(source_y, 0, height - 1)
    return values[clipped_y, clipped_x], valid


def make_sequence_teacher(
    current: np.ndarray[Any, np.dtype[np.float32]],
    previous: np.ndarray[Any, np.dtype[np.float32]],
) -> SequenceTeacher:
    (
        forward_dx,
        forward_dy,
        best_cost,
        second_cost,
        best_valid,
    ) = dense_match(current, previous)
    reverse_dx, reverse_dy, _, _, _ = dense_match(previous, current)
    sampled_reverse_dx, reverse_valid_x = gather_at_motion(
        reverse_dx,
        forward_dx,
        forward_dy,
    )
    sampled_reverse_dy, reverse_valid_y = gather_at_motion(
        reverse_dy,
        forward_dx,
        forward_dy,
    )
    reverse_valid = reverse_valid_x & reverse_valid_y
    consistency_error = (
        np.abs(forward_dx.astype(np.int16) + sampled_reverse_dx)
        + np.abs(forward_dy.astype(np.int16) + sampled_reverse_dy)
    )

    matched_previous, matched_valid = gather_at_motion(
        previous,
        forward_dx,
        forward_dy,
    )
    residual = np.abs(current - matched_previous)
    gradient_x = np.zeros_like(current)
    gradient_y = np.zeros_like(current)
    gradient_x[:, 1:] = np.abs(current[:, 1:] - current[:, :-1])
    gradient_y[1:, :] = np.abs(current[1:, :] - current[:-1, :])
    texture = box_mean(gradient_x + gradient_y, radius=1)
    ambiguity = second_cost - best_cost

    reactive = (
        ~best_valid
        | ~matched_valid
        | ~reverse_valid
        | (consistency_error > 1)
        | (best_cost > 0.10)
        | (residual > 0.14)
        | ((ambiguity < 0.006) & (best_cost > 0.018))
        | ((texture < 0.004) & (best_cost > 0.035))
    )
    if float(np.median(best_cost)) > 0.13:
        reactive[:] = True

    motion = np.empty((*current.shape, 2), dtype=np.float32)
    motion[:, :, 0] = forward_dx.astype(np.float32) * COARSE_SCALE
    motion[:, :, 1] = forward_dy.astype(np.float32) * COARSE_SCALE
    motion[reactive] = 0
    difference = current - previous
    features = np.stack(
        (current, previous, difference, np.abs(difference)),
        axis=-1,
    ).astype(np.float32)
    return SequenceTeacher(
        features=features,
        motion=motion,
        reactive=reactive[:, :, None].astype(np.float32),
    )


def stable_pair_sample(
    pairs: Sequence[CapturePair],
    maximum: int,
    seed: int,
) -> list[CapturePair]:
    ordered = sorted(
        pairs,
        key=lambda pair: stable_score(
            f"{pair.previous.path}:{pair.current.path}",
            seed,
        ),
    )
    return ordered[:maximum]


def build_sequence_teachers(
    pairs: Sequence[CapturePair],
    images: dict[Path, np.ndarray[Any, np.dtype[np.float32]]],
    maximum: int,
    seed: int,
) -> list[SequenceTeacher]:
    teachers: list[SequenceTeacher] = []
    for index, pair in enumerate(stable_pair_sample(pairs, maximum, seed), 1):
        previous = images.get(pair.previous.path)
        current = images.get(pair.current.path)
        if previous is None or current is None or previous.shape != current.shape:
            continue
        teachers.append(make_sequence_teacher(current, previous))
        if index == 1 or index % 24 == 0:
            print(
                f"teacher: prepared {index}/"
                f"{min(len(pairs), maximum)} adjacent pairs"
            )
    return teachers


def random_crop(
    image: np.ndarray[Any, np.dtype[np.float32]],
    crop_size: int,
    rng: np.random.Generator,
) -> np.ndarray[Any, np.dtype[np.float32]]:
    maximum_y = image.shape[0] - crop_size
    maximum_x = image.shape[1] - crop_size
    y = int(rng.integers(0, maximum_y + 1))
    x = int(rng.integers(0, maximum_x + 1))
    return image[y : y + crop_size, x : x + crop_size].copy()


def shifted_previous(
    current: np.ndarray[Any, np.dtype[np.float32]],
    dx: int,
    dy: int,
) -> tuple[
    np.ndarray[Any, np.dtype[np.float32]],
    np.ndarray[Any, np.dtype[np.float32]],
]:
    height, width = current.shape
    previous = np.zeros_like(current)

    source_x0 = max(0, -dx)
    source_x1 = min(width, width - dx)
    source_y0 = max(0, -dy)
    source_y1 = min(height, height - dy)
    destination_x0 = source_x0 + dx
    destination_x1 = source_x1 + dx
    destination_y0 = source_y0 + dy
    destination_y1 = source_y1 + dy
    previous[
        destination_y0:destination_y1,
        destination_x0:destination_x1,
    ] = current[source_y0:source_y1, source_x0:source_x1]

    x_coordinates = np.arange(width)[None, :] + dx
    y_coordinates = np.arange(height)[:, None] + dy
    valid = (
        (x_coordinates >= 0)
        & (x_coordinates < width)
        & (y_coordinates >= 0)
        & (y_coordinates < height)
    )
    reactive = (~valid).astype(np.float32)
    return previous, reactive


def apply_previous_overlay(
    previous: np.ndarray[Any, np.dtype[np.float32]],
    reactive: np.ndarray[Any, np.dtype[np.float32]],
    dx: int,
    dy: int,
    rng: np.random.Generator,
) -> None:
    height, width = previous.shape
    overlay_width = int(rng.integers(4, max(5, width // 3)))
    overlay_height = int(rng.integers(4, max(5, height // 3)))
    x0 = int(rng.integers(0, width - overlay_width + 1))
    y0 = int(rng.integers(0, height - overlay_height + 1))
    x1 = x0 + overlay_width
    y1 = y0 + overlay_height
    previous[y0:y1, x0:x1] = float(rng.uniform(0.0, 1.0))

    current_x0 = max(0, x0 - dx)
    current_y0 = max(0, y0 - dy)
    current_x1 = min(width, x1 - dx)
    current_y1 = min(height, y1 - dy)
    if current_x0 < current_x1 and current_y0 < current_y1:
        reactive[current_y0:current_y1, current_x0:current_x1] = 1.0


def create_synthetic_example(
    images: Sequence[np.ndarray[Any, np.dtype[np.float32]]],
    crop_size: int,
    rng: np.random.Generator,
) -> tuple[
    np.ndarray[Any, np.dtype[np.float32]],
    np.ndarray[Any, np.dtype[np.float32]],
    np.ndarray[Any, np.dtype[np.float32]],
]:
    current = random_crop(
        images[int(rng.integers(0, len(images)))],
        crop_size,
        rng,
    )
    case = float(rng.random())

    if case < 0.12:
        previous = random_crop(
            images[int(rng.integers(0, len(images)))],
            crop_size,
            rng,
        )
        reactive = np.ones_like(current)
        motion = np.zeros((*current.shape, 2), dtype=np.float32)
    else:
        dx = int(rng.integers(-SEARCH_RADIUS, SEARCH_RADIUS + 1))
        dy = int(rng.integers(-SEARCH_RADIUS, SEARCH_RADIUS + 1))
        if case < 0.3:
            dx = 0
            dy = 0
        previous, reactive = shifted_previous(current, dx, dy)
        motion = np.empty((*current.shape, 2), dtype=np.float32)
        motion[:, :, 0] = float(dx * COARSE_SCALE)
        motion[:, :, 1] = float(dy * COARSE_SCALE)

        if float(rng.random()) < 0.5:
            apply_previous_overlay(previous, reactive, dx, dy, rng)

        exposure = float(rng.uniform(0.86, 1.14))
        offset = float(rng.uniform(-0.03, 0.03))
        previous[:] = np.clip(previous * exposure + offset, 0.0, 1.0)

    motion[reactive >= 0.5] = 0
    difference = current - previous
    features = np.stack(
        (current, previous, difference, np.abs(difference)),
        axis=-1,
    ).astype(np.float32)
    return features, motion, reactive[:, :, None].astype(np.float32)


def create_sequence_example(
    teachers: Sequence[SequenceTeacher],
    crop_size: int,
    rng: np.random.Generator,
) -> tuple[
    np.ndarray[Any, np.dtype[np.float32]],
    np.ndarray[Any, np.dtype[np.float32]],
    np.ndarray[Any, np.dtype[np.float32]],
]:
    teacher = teachers[int(rng.integers(0, len(teachers)))]
    height, width = teacher.reactive.shape[:2]
    maximum_y = height - crop_size
    maximum_x = width - crop_size
    y = int(rng.integers(0, maximum_y + 1))
    x = int(rng.integers(0, maximum_x + 1))
    region = np.s_[y : y + crop_size, x : x + crop_size]
    return (
        teacher.features[region].copy(),
        teacher.motion[region].copy(),
        teacher.reactive[region].copy(),
    )


def create_batch(
    images: Sequence[np.ndarray[Any, np.dtype[np.float32]]],
    teachers: Sequence[SequenceTeacher],
    batch_size: int,
    crop_size: int,
    sequence_probability: float,
    rng: np.random.Generator,
) -> tuple[np.ndarray[Any, Any], np.ndarray[Any, Any], np.ndarray[Any, Any]]:
    examples = []
    for _ in range(batch_size):
        if teachers and float(rng.random()) < sequence_probability:
            example = create_sequence_example(teachers, crop_size, rng)
        else:
            example = create_synthetic_example(images, crop_size, rng)
        examples.append(example)
    return (
        np.stack([example[0] for example in examples]),
        np.stack([example[1] for example in examples]),
        np.stack([example[2] for example in examples]),
    )


def model_loss(
    model: SolFlowReactiveModel,
    inputs: mx.array,
    target_motion: mx.array,
    target_reactive: mx.array,
) -> tuple[mx.array, tuple[mx.array, mx.array]]:
    raw = model(inputs)
    predicted_motion = mx.tanh(raw[:, :, :, :2]) * MOTION_LIMIT
    reactive_logits = raw[:, :, :, 2:3]
    valid = 1.0 - target_reactive

    difference = predicted_motion - target_motion
    absolute = mx.abs(difference)
    huber = mx.where(
        absolute < 1.0,
        0.5 * difference * difference,
        absolute - 0.5,
    )
    valid_motion_values = mx.maximum(mx.sum(valid) * 2.0, 1.0)
    motion_loss = mx.sum(huber * valid) / valid_motion_values / MOTION_LIMIT

    # False negatives reuse invalid history and are more damaging than a
    # conservative false positive, which asks MetalFX to trust the current
    # frame. Keep recall safety-biased.
    reactive_weights = 1.0 + target_reactive * 11.0
    reactive_loss = nn.losses.binary_cross_entropy(
        reactive_logits,
        target_reactive,
        weights=reactive_weights,
        with_logits=True,
        reduction="mean",
    )
    total = motion_loss + reactive_loss * 0.7
    return total, (motion_loss, reactive_loss)


def motion_only_gradients(
    gradients: dict[str, dict[str, mx.array]],
) -> dict[str, dict[str, mx.array]]:
    conv2_weight = gradients["conv2"]["weight"]
    conv2_bias = gradients["conv2"]["bias"]
    return {
        "conv1": {
            "weight": mx.zeros_like(gradients["conv1"]["weight"]),
            "bias": mx.zeros_like(gradients["conv1"]["bias"]),
        },
        "conv2": {
            "weight": mx.concatenate(
                (
                    conv2_weight[:2],
                    mx.zeros_like(conv2_weight[2:3]),
                ),
                axis=0,
            ),
            "bias": mx.concatenate(
                (
                    conv2_bias[:2],
                    mx.zeros_like(conv2_bias[2:3]),
                ),
                axis=0,
            ),
        },
    }


def metrics_for_batch(
    model: SolFlowReactiveModel,
    inputs_np: np.ndarray[Any, Any],
    motion_np: np.ndarray[Any, Any],
    reactive_np: np.ndarray[Any, Any],
) -> dict[str, float]:
    raw = model(mx.array(inputs_np))
    predicted_motion = np.asarray(
        mx.tanh(raw[:, :, :, :2]) * MOTION_LIMIT
    )
    reactive_probability = np.asarray(mx.sigmoid(raw[:, :, :, 2:3]))

    valid = reactive_np < 0.5
    motion_error = np.abs(predicted_motion - motion_np)
    valid_motion = np.repeat(valid, 2, axis=-1)
    motion_mae = (
        float(motion_error[valid_motion].mean())
        if np.any(valid_motion)
        else 0.0
    )
    predicted_reactive = reactive_probability >= 0.5
    expected_reactive = reactive_np >= 0.5
    reactive_accuracy = float(
        np.mean(predicted_reactive == expected_reactive)
    )
    true_positive = float(
        np.sum(predicted_reactive & expected_reactive)
    )
    false_positive = float(
        np.sum(predicted_reactive & ~expected_reactive)
    )
    false_negative = float(
        np.sum(~predicted_reactive & expected_reactive)
    )
    precision = true_positive / max(true_positive + false_positive, 1.0)
    recall = true_positive / max(true_positive + false_negative, 1.0)
    f2 = (
        5.0 * precision * recall
        / max(4.0 * precision + recall, 1e-8)
    )
    return {
        "motionMAE": motion_mae,
        "reactiveAccuracy": reactive_accuracy,
        "reactivePrecision": precision,
        "reactiveRecall": recall,
        "reactiveF2": f2,
    }


def evaluate_synthetic(
    model: SolFlowReactiveModel,
    images: Sequence[np.ndarray[Any, np.dtype[np.float32]]],
    sample_count: int,
    crop_size: int,
    seed: int,
) -> dict[str, float]:
    rng = np.random.default_rng(seed)
    inputs, motion, reactive = create_batch(
        images,
        [],
        sample_count,
        crop_size,
        0,
        rng,
    )
    return metrics_for_batch(model, inputs, motion, reactive)


def evaluate_sequence(
    model: SolFlowReactiveModel,
    teachers: Sequence[SequenceTeacher],
    sample_count: int,
    crop_size: int,
    seed: int,
) -> dict[str, float] | None:
    if not teachers:
        return None
    rng = np.random.default_rng(seed)
    examples = [
        create_sequence_example(teachers, crop_size, rng)
        for _ in range(sample_count)
    ]
    return metrics_for_batch(
        model,
        np.stack([example[0] for example in examples]),
        np.stack([example[1] for example in examples]),
        np.stack([example[2] for example in examples]),
    )


def artifact_model(path: Path) -> SolFlowReactiveModel:
    artifact = json.loads(path.read_text(encoding="utf-8"))
    if artifact.get("schemaVersion") != SCHEMA_VERSION:
        raise ValueError(f"unsupported baseline schema: {path}")
    if artifact.get("architecture") != ARCHITECTURE:
        raise ValueError(f"unsupported baseline architecture: {path}")
    weights = artifact["weights"]
    model = SolFlowReactiveModel()
    model.conv1.weight = mx.array(
        np.asarray(weights["conv1"], dtype=np.float32).reshape(
            tuple(model.conv1.weight.shape)
        )
    )
    model.conv1.bias = mx.array(
        np.asarray(weights["conv1Bias"], dtype=np.float32).reshape(
            tuple(model.conv1.bias.shape)
        )
    )
    model.conv2.weight = mx.array(
        np.asarray(weights["conv2"], dtype=np.float32).reshape(
            tuple(model.conv2.weight.shape)
        )
    )
    model.conv2.bias = mx.array(
        np.asarray(weights["conv2Bias"], dtype=np.float32).reshape(
            tuple(model.conv2.bias.shape)
        )
    )
    mx.eval(model.parameters())
    return model


def floats(values: mx.array) -> list[float]:
    return [
        # More precision than half-float Metal inference can consume, while
        # keeping the bundled artifact compact and reproducible.
        round(float(value), 8)
        for value in np.asarray(values, dtype=np.float32).reshape(-1)
    ]


def write_model(
    path: Path,
    model: SolFlowReactiveModel,
    steps: int,
    split: DatasetSplit,
    validation: dict[str, Any],
    baseline: dict[str, Any] | None,
    seed: int,
    capture_frame_count: int,
    adjacent_pair_count: int,
    fine_tune_mode: str,
) -> None:
    weights = {
        "conv1": floats(model.conv1.weight),
        "conv1Bias": floats(model.conv1.bias),
        "conv2": floats(model.conv2.weight),
        "conv2Bias": floats(model.conv2.bias),
    }
    canonical_weights = json.dumps(
        weights,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    fingerprint = hashlib.sha256(canonical_weights).hexdigest()[:12]
    artifact = {
        "schemaVersion": SCHEMA_VERSION,
        "identifier": f"sol-flow-reactive-v1-{fingerprint}",
        "architecture": ARCHITECTURE,
        "coarseScale": COARSE_SCALE,
        "motionLimit": MOTION_LIMIT,
        "weights": weights,
        "training": {
            "teacher": "hybrid-known-motion-flow-v2",
            "steps": steps,
            "captureFrameCount": capture_frame_count,
            "adjacentPairCount": adjacent_pair_count,
            "seed": seed,
            "fineTuneMode": fine_tune_mode,
            "split": {
                "unit": split.split_unit,
                "holdoutKeys": list(split.holdout_keys),
                "trainingFrameCount": len(split.training_frames),
                "validationFrameCount": len(split.validation_frames),
                "trainingPairCount": len(split.training_pairs),
                "validationPairCount": len(split.validation_pairs),
            },
            "validation": validation,
            "baseline": baseline,
            "privacy": "weights-only-local-captures-not-shipped",
        },
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(artifact, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def format_metrics(label: str, metrics: dict[str, float] | None) -> str:
    if metrics is None:
        return f"{label}: unavailable"
    return (
        f"{label}: motion MAE={metrics['motionMAE']:.3f}px, "
        f"reactive accuracy={metrics['reactiveAccuracy']:.3%}, "
        f"precision={metrics['reactivePrecision']:.3%}, "
        f"recall={metrics['reactiveRecall']:.3%}, "
        f"F2={metrics['reactiveF2']:.3%}"
    )


def default_baseline_path() -> Path:
    return (
        Path(__file__).resolve().parents[2]
        / "Sources"
        / "SolDLSM"
        / "Models"
        / "sol-temporal-v0.json"
    )


def all_finite(metrics: Iterable[dict[str, float] | None]) -> bool:
    return all(
        math.isfinite(value)
        for metric in metrics
        if metric is not None
        for value in metric.values()
    )


def candidate_passes(
    synthetic: dict[str, float],
    sequence: dict[str, float] | None,
    baseline_synthetic: dict[str, float] | None,
    baseline_sequence: dict[str, float] | None,
) -> tuple[bool, str | None]:
    if synthetic["motionMAE"] > 4.0:
        return False, "candidate did not pass the 4-pixel synthetic motion gate"
    if synthetic["reactiveRecall"] < 0.75:
        return False, "candidate did not pass the 75% synthetic reactive-recall gate"
    if synthetic["reactiveAccuracy"] < 0.65:
        return False, "candidate did not pass the 65% synthetic reactive-accuracy gate"
    if synthetic["reactivePrecision"] < 0.10:
        return False, "candidate did not pass the 10% synthetic reactive-precision gate"
    if sequence is not None:
        if sequence["motionMAE"] > 5.0:
            return False, "candidate did not pass the 5-pixel sequence motion gate"
        if baseline_sequence is None:
            if sequence["reactiveRecall"] < 0.75:
                return False, "candidate did not pass the 75% sequence reactive-recall gate"
            if sequence["reactiveAccuracy"] < 0.65:
                return False, "candidate did not pass the 65% sequence reactive-accuracy gate"
            if sequence["reactivePrecision"] < 0.45:
                return False, "candidate did not pass the 45% sequence reactive-precision gate"
    if baseline_synthetic is not None:
        if synthetic["motionMAE"] > baseline_synthetic["motionMAE"] + 0.25:
            return False, "candidate regressed synthetic motion versus the bundled baseline"
        if (
            synthetic["reactiveRecall"]
            < baseline_synthetic["reactiveRecall"] - 0.03
        ):
            return False, "candidate regressed synthetic reactivity versus the bundled baseline"
        if (
            synthetic["reactiveF2"]
            < baseline_synthetic["reactiveF2"] - 0.02
        ):
            return False, "candidate regressed synthetic reactive F2 versus the bundled baseline"
    if sequence is not None and baseline_sequence is not None:
        if (
            sequence["reactiveAccuracy"]
            < baseline_sequence["reactiveAccuracy"] - 0.03
            or sequence["reactiveF2"]
            < baseline_sequence["reactiveF2"] - 0.02
        ):
            return False, "candidate regressed held-out sequence reactivity"
        motion_improved = (
            sequence["motionMAE"]
            <= baseline_sequence["motionMAE"] - 0.05
        )
        reactivity_improved = (
            sequence["reactiveF2"]
            >= baseline_sequence["reactiveF2"] + 0.01
        )
        if not motion_improved and not reactivity_improved:
            return False, "candidate did not improve the held-out sequence teacher"
    return True, None


def main() -> int:
    arguments = parse_arguments()
    try:
        validate_arguments(arguments)
        capture_directories = [
            path.expanduser().resolve(strict=True)
            for path in arguments.capture_directories
        ]
        discovered = [
            discover_dataset(capture_directory)
            for capture_directory in capture_directories
        ]
        frames = [
            frame
            for dataset_frames, _ in discovered
            for frame in dataset_frames
        ]
        pairs = [
            pair
            for _, dataset_pairs in discovered
            for pair in dataset_pairs
        ]
        split = split_dataset(
            frames,
            pairs,
            arguments.holdout_fraction,
            arguments.holdout_group,
            arguments.seed,
        )
        all_images = load_images(frames, arguments.crop_size)
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    training_images = [
        all_images[frame.path]
        for frame in split.training_frames
        if frame.path in all_images
    ]
    validation_images = [
        all_images[frame.path]
        for frame in split.validation_frames
        if frame.path in all_images
    ]
    if len(training_images) < 2 or not validation_images:
        print(
            "error: usable captures did not preserve the train/holdout split",
            file=sys.stderr,
        )
        return 2

    print(
        f"dataset: {len(frames)} frames, {len(pairs)} adjacent pairs; "
        f"holdout by {split.split_unit} "
        f"({len(split.holdout_keys)} key(s))"
    )
    training_teachers = build_sequence_teachers(
        split.training_pairs,
        all_images,
        arguments.max_sequence_pairs,
        arguments.seed,
    )
    validation_teachers = build_sequence_teachers(
        split.validation_pairs,
        all_images,
        arguments.max_sequence_pairs,
        arguments.seed + 1,
    )
    print(
        f"teacher: {len(training_teachers)} training and "
        f"{len(validation_teachers)} holdout adjacent sequences"
    )

    output = arguments.output
    if output is None:
        output = capture_directories[0] / "sol-temporal-v1.json"
    output = output.expanduser().resolve()

    baseline_path = (
        arguments.baseline_model.expanduser().resolve()
        if arguments.baseline_model
        else default_baseline_path()
    )

    np_rng = np.random.default_rng(arguments.seed)
    mx.random.seed(arguments.seed)
    initialized_from_baseline = (
        baseline_path.is_file() and not arguments.from_scratch
    )
    if initialized_from_baseline:
        try:
            model = artifact_model(baseline_path)
        except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
            print(
                f"error: could not initialize from baseline: {error}",
                file=sys.stderr,
            )
            return 2
        print(f"initialization: fine-tuning {baseline_path.name}")
    else:
        model = SolFlowReactiveModel()
        print("initialization: training from scratch")
    motion_only = initialized_from_baseline and not arguments.full_finetune
    fine_tune_mode = "motion-only" if motion_only else "full"
    print(f"fine-tune mode: {fine_tune_mode}")
    optimizer = optim.Adam(
        learning_rate=arguments.learning_rate,
        bias_correction=True,
    )
    loss_and_grad = nn.value_and_grad(model, model_loss)

    for step in range(1, arguments.steps + 1):
        inputs_np, motion_np, reactive_np = create_batch(
            training_images,
            training_teachers,
            arguments.batch_size,
            arguments.crop_size,
            arguments.sequence_probability,
            np_rng,
        )
        (loss, components), gradients = loss_and_grad(
            model,
            mx.array(inputs_np),
            mx.array(motion_np),
            mx.array(reactive_np),
        )
        if motion_only:
            gradients = motion_only_gradients(gradients)
        optimizer.update(model, gradients)
        mx.eval(model.parameters(), optimizer.state, loss, components)

        if step == 1 or step % 50 == 0 or step == arguments.steps:
            print(
                f"step {step:4d}/{arguments.steps}: "
                f"loss={float(loss.item()):.5f} "
                f"motion={float(components[0].item()):.5f} "
                f"reactive={float(components[1].item()):.5f}"
            )

    synthetic_validation = evaluate_synthetic(
        model,
        validation_images,
        arguments.validation_samples,
        arguments.crop_size,
        arguments.seed + 2,
    )
    sequence_validation = evaluate_sequence(
        model,
        validation_teachers,
        arguments.validation_samples,
        arguments.crop_size,
        arguments.seed + 3,
    )
    print(format_metrics("validation synthetic", synthetic_validation))
    print(format_metrics("validation sequence", sequence_validation))

    baseline_synthetic: dict[str, float] | None = None
    baseline_sequence: dict[str, float] | None = None
    baseline_metadata: dict[str, Any] | None = None
    if baseline_path.is_file():
        try:
            baseline_model = artifact_model(baseline_path)
            baseline_synthetic = evaluate_synthetic(
                baseline_model,
                validation_images,
                arguments.validation_samples,
                arguments.crop_size,
                arguments.seed + 2,
            )
            baseline_sequence = evaluate_sequence(
                baseline_model,
                validation_teachers,
                arguments.validation_samples,
                arguments.crop_size,
                arguments.seed + 3,
            )
            baseline_metadata = {
                "artifact": baseline_path.name,
                "synthetic": baseline_synthetic,
                "sequence": baseline_sequence,
            }
            print(format_metrics("baseline synthetic", baseline_synthetic))
            print(format_metrics("baseline sequence", baseline_sequence))
        except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
            print(f"error: could not evaluate baseline: {error}", file=sys.stderr)
            return 2

    if not all_finite(
        (
            synthetic_validation,
            sequence_validation,
            baseline_synthetic,
            baseline_sequence,
        )
    ):
        print("error: validation produced a non-finite metric", file=sys.stderr)
        return 1

    passed, failure_reason = candidate_passes(
        synthetic_validation,
        sequence_validation,
        baseline_synthetic,
        baseline_sequence,
    )
    if not passed:
        print(f"error: {failure_reason}", file=sys.stderr)
        return 1

    validation_metadata = {
        "synthetic": synthetic_validation,
        "sequence": sequence_validation,
    }
    write_model(
        output,
        model,
        arguments.steps,
        split,
        validation_metadata,
        baseline_metadata,
        arguments.seed,
        len(frames),
        len(pairs),
        fine_tune_mode,
    )
    print(f"Wrote Sol Temporal candidate: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
