#!/usr/bin/env python3
"""Offline, privacy-safe visual comparisons for SolMetal compatibility runs."""

import argparse
import binascii
import hashlib
import json
import math
import os
import pathlib
import re
import secrets
import stat
import struct
import sys
import zlib
from array import array
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Sequence, Tuple


SCHEMA_VERSION = 1
RUNNER_VERSION = "4"
ROOT_DIR = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_PRIVATE_ROOT = (
    pathlib.Path.home()
    / "Library"
    / "Application Support"
    / "Sol"
    / "Developer"
    / "SolMetalVisualRegression"
)
DEFAULT_MANIFEST = DEFAULT_PRIVATE_ROOT / "suite.private.json"
DEFAULT_PUBLIC_OUTPUT = pathlib.Path("solmetal-visual-results.json")
SAFE_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
RAW_FORMATS = {"rgba8", "bgra8", "rg11b10float", "rgba16float"}
SUPPORTED_FORMATS = {"auto", "png", *RAW_FORMATS}
MAX_INPUT_BYTES = 512 * 1024 * 1024
MAX_PIXELS = 100_000_000
HISTOGRAM_BINS = 4096
LUMA_PERCENTILES = (
    ("p1", 0.01),
    ("p50", 0.50),
    ("p95", 0.95),
    ("p99", 0.99),
)
CLIPPED_WHITE_LUMA = 0.98
RETAINED_BLACK_LUMA = 0.02
TRANSFER_RAMP_LEVELS = 256
TRANSFER_CORRECT_SIGNATURE = (
    "f7721524360322232937cff69886be54d18f94dc172627061757855971b5db36"
)
TRANSFER_MISMATCH_SIGNATURE = (
    "38054d3b7822df8e784644befb2be76c3f98958ebfc799d7294ba5cdada6b142"
)
TRANSFER_DIFFERENCE_FINGERPRINT = "a6000a270eecd503d54512dd"
TRANSFER_MIN_MISMATCH_PERCENT = 99.0
TRANSFER_MIN_MEAN_ABSOLUTE_ERROR = 0.18
TRANSFER_MIN_RETAINED_BLACK_PERCENTAGE_POINTS = 25.0
TRANSFER_MAX_P50_LUMA_DELTA = -0.17
DARK_RECTANGLE_DETECTOR_VERSION = 1
DARK_RECTANGLE_MAX_CANDIDATE_LUMA = 0.02
DARK_RECTANGLE_MIN_WIDTH = 8
DARK_RECTANGLE_MIN_HEIGHT = 8
DARK_RECTANGLE_MIN_PIXELS = 64
DARK_RECTANGLE_MIN_FILL_RATIO = 0.90
DARK_RECTANGLE_MIN_EDGE_REGULARITY = 0.90
DARK_RECTANGLE_MIN_CHANGED_PERCENT = 80.0
DARK_RECTANGLE_MIN_MEAN_LUMA_DROP = 0.04
DARK_RECTANGLE_MAX_REPORTED = 8


class HarnessError(RuntimeError):
    pass


@dataclass
class Frame:
    width: int
    height: int
    format: str
    exact_pixels: bytes
    exact_stride: int
    samples: array
    non_finite_samples: int


def is_inside(child: pathlib.Path, parent: pathlib.Path) -> bool:
    try:
        child.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def require_private_location(path: pathlib.Path, kind: str) -> None:
    if is_inside(path, ROOT_DIR):
        raise HarnessError(
            "%s must live outside the repository so it cannot be committed." % kind
        )


def write_json_atomic(path: pathlib.Path, value: Any, private: bool) -> None:
    path = path.expanduser()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700 if private else 0o755)
    if private:
        os.chmod(str(path.parent), 0o700)
    temporary = path.with_name(path.name + ".tmp-" + secrets.token_hex(4))
    descriptor = os.open(
        str(temporary),
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        0o600 if private else 0o644,
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(str(temporary), str(path))
        os.chmod(str(path), 0o600 if private else 0o644)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def read_json(path: pathlib.Path) -> Any:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError):
        raise HarnessError("The private visual manifest could not be read.")


def safe_identifier(value: Any, field: str) -> str:
    if not isinstance(value, str) or not SAFE_ID.fullmatch(value):
        raise HarnessError(
            "%s must use lowercase letters, numbers, dots, dashes, or underscores."
            % field
        )
    return value


def positive_integer(value: Any, field: str, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise HarnessError("%s must be an integer." % field)
    if not 1 <= value <= maximum:
        raise HarnessError("%s must be between 1 and %d." % (field, maximum))
    return value


def nonnegative_number(value: Any, field: str, maximum: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise HarnessError("%s must be numeric." % field)
    result = float(value)
    if not math.isfinite(result) or not 0.0 <= result <= maximum:
        raise HarnessError("%s must be between 0 and %s." % (field, maximum))
    return result


def validate_frame_spec(raw: Any, comparison_id: str, role: str) -> Dict[str, Any]:
    if not isinstance(raw, dict):
        raise HarnessError("%s %s capture is missing." % (comparison_id, role))
    title = safe_identifier(raw.get("title"), "%s %s title" % (comparison_id, role))
    backend = safe_identifier(
        raw.get("backend"), "%s %s backend" % (comparison_id, role)
    )
    path_raw = raw.get("path")
    if not isinstance(path_raw, str) or not path_raw:
        raise HarnessError("%s %s capture has no private path." % (comparison_id, role))
    path = pathlib.Path(path_raw).expanduser().resolve()
    require_private_location(path, "%s %s capture" % (comparison_id, role))
    if not path.is_file():
        raise HarnessError("%s %s capture is unavailable." % (comparison_id, role))
    try:
        size = path.stat().st_size
    except OSError:
        raise HarnessError("%s %s capture is unavailable." % (comparison_id, role))
    if size <= 0 or size > MAX_INPUT_BYTES:
        raise HarnessError("%s %s capture has an unsafe size." % (comparison_id, role))

    format_name = str(raw.get("format") or "auto").casefold()
    if format_name not in SUPPORTED_FORMATS:
        raise HarnessError("%s %s capture has an unsupported format." % (comparison_id, role))
    if format_name == "auto":
        if path.suffix.casefold() != ".png":
            raise HarnessError(
                "%s %s raw capture needs an explicit format." % (comparison_id, role)
            )
        format_name = "png"

    width = raw.get("width")
    height = raw.get("height")
    row_bytes = raw.get("rowBytes")
    if format_name in RAW_FORMATS:
        width = positive_integer(width, "%s %s width" % (comparison_id, role), 32768)
        height = positive_integer(
            height, "%s %s height" % (comparison_id, role), 32768
        )
        if width * height > MAX_PIXELS:
            raise HarnessError("%s %s capture is too large." % (comparison_id, role))
        bytes_per_pixel = 8 if format_name == "rgba16float" else 4
        minimum_row_bytes = width * bytes_per_pixel
        if row_bytes is None:
            row_bytes = minimum_row_bytes
        row_bytes = positive_integer(
            row_bytes,
            "%s %s rowBytes" % (comparison_id, role),
            MAX_INPUT_BYTES,
        )
        if row_bytes < minimum_row_bytes or row_bytes * height != size:
            raise HarnessError(
                "%s %s raw dimensions do not match its byte count."
                % (comparison_id, role)
            )
    else:
        if width is not None or height is not None or row_bytes is not None:
            raise HarnessError(
                "%s %s PNG dimensions must come from the image."
                % (comparison_id, role)
            )

    flip_y = raw.get("flipY", False)
    if not isinstance(flip_y, bool):
        raise HarnessError("%s %s flipY must be true or false." % (comparison_id, role))
    return {
        "title": title,
        "backend": backend,
        "path": path,
        "format": format_name,
        "width": width,
        "height": height,
        "rowBytes": row_bytes,
        "flipY": flip_y,
    }


def validate_tolerance(raw: Any, comparison_id: str) -> Dict[str, Any]:
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise HarnessError("%s tolerance must be an object." % comparison_id)
    allowed = {
        "maxMismatchPercent": 100.0,
        "maxMeanAbsoluteError": 1.0,
        "maxP95ColorDistance": 1.0,
        "maxMeanLumaError": 1.0,
    }
    integer_fields = {"maxChangedTiles", "maxDarkRectangles"}
    unknown = set(raw) - (set(allowed) | integer_fields)
    if unknown:
        raise HarnessError("%s tolerance has an unknown field." % comparison_id)
    result: Dict[str, Any] = {}
    for key, maximum in allowed.items():
        if key in raw:
            result[key] = nonnegative_number(
                raw[key], "%s %s" % (comparison_id, key), maximum
            )
    for key in sorted(integer_fields):
        if key not in raw:
            continue
        value = raw[key]
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise HarnessError("%s %s must be nonnegative." % (comparison_id, key))
        result[key] = value
    return result


def load_manifest(path: pathlib.Path, require_cases: bool) -> List[Dict[str, Any]]:
    path = path.expanduser().resolve()
    require_private_location(path, "The private visual manifest")
    if not path.is_file():
        raise HarnessError("The private visual manifest is unavailable.")
    if stat.S_IMODE(path.stat().st_mode) & 0o077:
        raise HarnessError("The private visual manifest must use owner-only permissions.")
    raw = read_json(path)
    if not isinstance(raw, dict) or raw.get("schemaVersion") != SCHEMA_VERSION:
        raise HarnessError("The private visual manifest has an unsupported schema version.")
    if raw.get("private") is not True or not isinstance(raw.get("comparisons"), list):
        raise HarnessError("The private visual manifest is missing required fields.")
    if require_cases and not raw["comparisons"]:
        raise HarnessError("The private visual manifest has no comparisons.")

    comparisons: List[Dict[str, Any]] = []
    identifiers = set()
    for index, item in enumerate(raw["comparisons"]):
        if not isinstance(item, dict):
            raise HarnessError("Comparison %d is not an object." % (index + 1))
        identifier = safe_identifier(item.get("id"), "comparison id")
        if identifier in identifiers:
            raise HarnessError("The private visual manifest repeats a comparison id.")
        identifiers.add(identifier)
        scene = safe_identifier(item.get("scene"), "%s scene" % identifier)
        tile_size = item.get("tileSize", 64)
        tile_size = positive_integer(tile_size, "%s tileSize" % identifier, 512)
        if tile_size < 8 or tile_size & (tile_size - 1):
            raise HarnessError("%s tileSize must be a power of two from 8 to 512." % identifier)
        reference = validate_frame_spec(item.get("reference"), identifier, "reference")
        candidate = validate_frame_spec(item.get("candidate"), identifier, "candidate")
        if reference["title"] != candidate["title"]:
            raise HarnessError("%s compares captures from different titles." % identifier)
        if reference["path"] == candidate["path"]:
            raise HarnessError("%s reference and candidate must be separate captures." % identifier)
        comparisons.append(
            {
                "id": identifier,
                "scene": scene,
                "title": reference["title"],
                "tileSize": tile_size,
                "reference": reference,
                "candidate": candidate,
                "tolerance": validate_tolerance(item.get("tolerance"), identifier),
            }
        )
    return comparisons


def read_capture(path: pathlib.Path) -> bytes:
    try:
        return path.read_bytes()
    except OSError:
        raise HarnessError("A private capture could not be read.")


def paeth(left: int, above: int, upper_left: int) -> int:
    estimate = left + above - upper_left
    left_distance = abs(estimate - left)
    above_distance = abs(estimate - above)
    upper_left_distance = abs(estimate - upper_left)
    if left_distance <= above_distance and left_distance <= upper_left_distance:
        return left
    return above if above_distance <= upper_left_distance else upper_left


def decode_png(data: bytes, flip_y: bool) -> Frame:
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise HarnessError("A PNG capture has an invalid signature.")
    offset = 8
    header: Optional[Tuple[int, int, int, int, int, int, int]] = None
    palette: Optional[bytes] = None
    transparency: Optional[bytes] = None
    compressed = bytearray()
    saw_end = False
    while offset + 12 <= len(data):
        length = struct.unpack_from(">I", data, offset)[0]
        chunk_type = data[offset + 4 : offset + 8]
        chunk_end = offset + 12 + length
        if chunk_end > len(data):
            raise HarnessError("A PNG capture has a truncated chunk.")
        chunk = data[offset + 8 : offset + 8 + length]
        expected_crc = struct.unpack_from(">I", data, offset + 8 + length)[0]
        actual_crc = binascii.crc32(chunk_type)
        actual_crc = binascii.crc32(chunk, actual_crc) & 0xFFFFFFFF
        if expected_crc != actual_crc:
            raise HarnessError("A PNG capture failed its CRC check.")
        if chunk_type == b"IHDR":
            if header is not None or length != 13:
                raise HarnessError("A PNG capture has an invalid header.")
            header = struct.unpack(">IIBBBBB", chunk)
        elif chunk_type == b"PLTE":
            palette = bytes(chunk)
        elif chunk_type == b"tRNS":
            transparency = bytes(chunk)
        elif chunk_type == b"IDAT":
            compressed.extend(chunk)
        elif chunk_type == b"acTL":
            raise HarnessError("Animated PNG captures are not supported.")
        elif chunk_type == b"IEND":
            saw_end = True
            break
        offset = chunk_end
    if header is None or not saw_end or not compressed:
        raise HarnessError("A PNG capture is incomplete.")
    width, height, depth, color_type, compression, filtering, interlace = header
    if width <= 0 or height <= 0 or width * height > MAX_PIXELS:
        raise HarnessError("A PNG capture has unsafe dimensions.")
    if depth != 8 or compression != 0 or filtering != 0 or interlace != 0:
        raise HarnessError("Only non-interlaced 8-bit PNG captures are supported.")
    channels_by_type = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
    channels = channels_by_type.get(color_type)
    if channels is None:
        raise HarnessError("A PNG capture has an unsupported color type.")
    if color_type == 3 and (
        palette is None or len(palette) == 0 or len(palette) % 3 != 0
    ):
        raise HarnessError("An indexed PNG capture has no valid palette.")
    row_size = width * channels
    expected_size = height * (row_size + 1)
    try:
        filtered = zlib.decompress(bytes(compressed))
    except zlib.error:
        raise HarnessError("A PNG capture has an invalid compressed stream.")
    if len(filtered) != expected_size:
        raise HarnessError("A PNG capture has an unexpected decoded size.")

    rows: List[bytes] = []
    previous = bytearray(row_size)
    cursor = 0
    for _ in range(height):
        filter_type = filtered[cursor]
        encoded = filtered[cursor + 1 : cursor + 1 + row_size]
        cursor += row_size + 1
        if filter_type > 4:
            raise HarnessError("A PNG capture uses an unknown row filter.")
        decoded = bytearray(row_size)
        for index, byte in enumerate(encoded):
            left = decoded[index - channels] if index >= channels else 0
            above = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            if filter_type == 0:
                predictor = 0
            elif filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = above
            elif filter_type == 3:
                predictor = (left + above) // 2
            else:
                predictor = paeth(left, above, upper_left)
            decoded[index] = (byte + predictor) & 0xFF
        rows.append(bytes(decoded))
        previous = decoded
    if flip_y:
        rows.reverse()

    rgba = bytearray(width * height * 4)
    output = 0
    transparent_gray = None
    transparent_rgb = None
    if color_type == 0 and transparency is not None and len(transparency) == 2:
        transparent_gray = struct.unpack(">H", transparency)[0] & 0xFF
    if color_type == 2 and transparency is not None and len(transparency) == 6:
        transparent_rgb = tuple(value & 0xFF for value in struct.unpack(">HHH", transparency))
    for row in rows:
        for x in range(width):
            source = x * channels
            if color_type == 0:
                gray = row[source]
                pixel = (gray, gray, gray, 0 if gray == transparent_gray else 255)
            elif color_type == 2:
                rgb = (row[source], row[source + 1], row[source + 2])
                pixel = (*rgb, 0 if rgb == transparent_rgb else 255)
            elif color_type == 3:
                palette_index = row[source]
                palette_offset = palette_index * 3
                if palette is None or palette_offset + 3 > len(palette):
                    raise HarnessError("An indexed PNG capture references a missing color.")
                alpha = (
                    transparency[palette_index]
                    if transparency is not None and palette_index < len(transparency)
                    else 255
                )
                pixel = (
                    palette[palette_offset],
                    palette[palette_offset + 1],
                    palette[palette_offset + 2],
                    alpha,
                )
            elif color_type == 4:
                gray = row[source]
                pixel = (gray, gray, gray, row[source + 1])
            else:
                pixel = tuple(row[source : source + 4])
            rgba[output : output + 4] = bytes(pixel)
            output += 4
    samples = array("f", (value / 255.0 for value in rgba))
    return Frame(width, height, "png-rgba8", bytes(rgba), 4, samples, 0)


def compact_rows(data: bytes, width: int, height: int, row_bytes: int, stride: int,
                 flip_y: bool) -> bytes:
    compact = width * stride
    rows = [data[y * row_bytes : y * row_bytes + compact] for y in range(height)]
    if flip_y:
        rows.reverse()
    return b"".join(rows)


def hdr_display_value(value: float) -> Tuple[float, int]:
    if math.isnan(value):
        return 0.0, 1
    if math.isinf(value):
        return (1.0 if value > 0 else 0.0), 1
    value = max(0.0, value)
    mapped = value / (1.0 + value)
    if mapped <= 0.0031308:
        return mapped * 12.92, 0
    return 1.055 * math.pow(mapped, 1.0 / 2.4) - 0.055, 0


def decode_unsigned_float(bits: int, mantissa_bits: int) -> float:
    exponent = bits >> mantissa_bits
    fraction = bits & ((1 << mantissa_bits) - 1)
    if exponent == 0:
        return fraction * math.pow(2.0, 1 - 15 - mantissa_bits)
    if exponent == 31:
        return float("nan") if fraction else float("inf")
    return (1.0 + fraction / float(1 << mantissa_bits)) * math.pow(2.0, exponent - 15)


def decode_raw(data: bytes, spec: Dict[str, Any]) -> Frame:
    width = spec["width"]
    height = spec["height"]
    format_name = spec["format"]
    stride = 8 if format_name == "rgba16float" else 4
    exact = compact_rows(
        data, width, height, spec["rowBytes"], stride, spec["flipY"]
    )
    samples = array("f")
    non_finite = 0
    if format_name in {"rgba8", "bgra8"}:
        rgba = bytearray(len(exact))
        for offset in range(0, len(exact), 4):
            if format_name == "rgba8":
                red, green, blue, alpha = exact[offset : offset + 4]
            else:
                blue, green, red, alpha = exact[offset : offset + 4]
            rgba[offset : offset + 4] = bytes((red, green, blue, alpha))
        exact = bytes(rgba)
        samples.extend(value / 255.0 for value in exact)
        resolved_format = format_name
        stride = 4
    elif format_name == "rg11b10float":
        for offset in range(0, len(exact), 4):
            packed = struct.unpack_from("<I", exact, offset)[0]
            linear = (
                decode_unsigned_float(packed & 0x7FF, 6),
                decode_unsigned_float((packed >> 11) & 0x7FF, 6),
                decode_unsigned_float((packed >> 22) & 0x3FF, 5),
            )
            for value in linear:
                display, invalid = hdr_display_value(value)
                samples.append(display)
                non_finite += invalid
            samples.append(1.0)
        resolved_format = format_name
    else:
        for offset in range(0, len(exact), 8):
            values = struct.unpack_from("<4e", exact, offset)
            for value in values[:3]:
                display, invalid = hdr_display_value(float(value))
                samples.append(display)
                non_finite += invalid
            alpha = float(values[3])
            if not math.isfinite(alpha):
                non_finite += 1
                alpha = 0.0
            samples.append(min(1.0, max(0.0, alpha)))
        resolved_format = format_name
    return Frame(width, height, resolved_format, exact, stride, samples, non_finite)


def load_frame(spec: Dict[str, Any]) -> Frame:
    data = read_capture(spec["path"])
    return decode_png(data, spec["flipY"]) if spec["format"] == "png" else decode_raw(data, spec)


def srgb_to_linear(value: float) -> float:
    if value <= 0.04045:
        return value / 12.92
    return math.pow((value + 0.055) / 1.055, 2.4)


def rounded(value: float) -> float:
    return round(float(value), 8)


def histogram_percentile(histogram: List[int], count: int, percentile: float) -> float:
    if count <= 0:
        return 0.0
    target = max(1, int(math.ceil(count * percentile)))
    seen = 0
    for index, bucket in enumerate(histogram):
        seen += bucket
        if seen >= target:
            return index / float(len(histogram) - 1)
    return 1.0


def luma_histogram_index(value: float) -> int:
    return min(HISTOGRAM_BINS, max(0, int(value * HISTOGRAM_BINS)))


def luminance_distribution(
    histogram: List[int], pixels: int, clipped_white: int, retained_black: int
) -> Dict[str, Any]:
    result = {
        name: rounded(histogram_percentile(histogram, pixels, percentile))
        for name, percentile in LUMA_PERCENTILES
    }
    result.update(
        {
            "clippedWhitePixels": clipped_white,
            "clippedWhitePercent": rounded(clipped_white * 100.0 / pixels),
            "retainedBlackPixels": retained_black,
            "retainedBlackPercent": rounded(retained_black * 100.0 / pixels),
        }
    )
    return result


def normalized_rgba8_frame(width: int, height: int, pixels: bytes) -> Frame:
    expected_bytes = width * height * 4
    if len(pixels) != expected_bytes:
        raise HarnessError("The generated transfer fixture has an invalid byte count.")
    return Frame(
        width,
        height,
        "bgra8",
        pixels,
        4,
        array("f", (value / 255.0 for value in pixels)),
        0,
    )


def srgb_gray_ramp_frames() -> Tuple[Frame, Frame]:
    correct = bytearray()
    decoded_linear_unorm = bytearray()
    for encoded in range(TRANSFER_RAMP_LEVELS):
        correct.extend((encoded, encoded, encoded, 255))
        linear = srgb_to_linear(encoded / 255.0)
        # Python's round is nearest-even, matching normalized Metal conversion
        # at the modeled linear-to-UNORM boundary.
        mismatched = max(0, min(255, int(round(linear * 255.0))))
        decoded_linear_unorm.extend((mismatched, mismatched, mismatched, 255))
    return (
        normalized_rgba8_frame(TRANSFER_RAMP_LEVELS, 1, bytes(correct)),
        normalized_rgba8_frame(
            TRANSFER_RAMP_LEVELS, 1, bytes(decoded_linear_unorm)
        ),
    )


def transfer_case(identifier: str, candidate_backend: str) -> Dict[str, Any]:
    return {
        "id": identifier,
        "title": "presentation",
        "scene": "srgb-gray-ramp",
        "tileSize": 64,
        "reference": {"backend": "encoded-srgb-reference"},
        "candidate": {"backend": candidate_backend},
        "tolerance": {
            "maxMismatchPercent": 0.0,
            "maxMeanAbsoluteError": 0.0,
            "maxP95ColorDistance": 0.0,
            "maxMeanLumaError": 0.0,
            "maxChangedTiles": 0,
        },
    }


def dark_rectangle_diagnostics(
    reference: Frame,
    candidate: Frame,
    reference_luma: array,
    candidate_luma: array,
) -> Dict[str, Any]:
    width = reference.width
    height = reference.height
    pixels = width * height
    mask = bytearray(pixels)
    for pixel in range(pixels):
        mask[pixel] = candidate_luma[pixel] <= DARK_RECTANGLE_MAX_CANDIDATE_LUMA

    mask_pixels = sum(mask)
    mask_fingerprint = hashlib.sha256()
    mask_fingerprint.update(
        (
            "solmetal-dark-mask-v%d:%dx%d:%.8f"
            % (
                DARK_RECTANGLE_DETECTOR_VERSION,
                width,
                height,
                DARK_RECTANGLE_MAX_CANDIDATE_LUMA,
            )
        ).encode("ascii")
    )
    mask_fingerprint.update(mask)

    visited = bytearray(pixels)
    connected_components = 0
    rectangle_count = 0
    rectangle_pixels = 0
    reported_rectangles: List[Dict[str, Any]] = []
    rectangle_fingerprint = hashlib.sha256()
    rectangle_fingerprint.update(
        ("solmetal-dark-rectangles-v%d:%dx%d" % (
            DARK_RECTANGLE_DETECTOR_VERSION,
            width,
            height,
        )).encode("ascii")
    )

    for seed in range(pixels):
        if not mask[seed] or visited[seed]:
            continue
        connected_components += 1
        visited[seed] = 1
        stack = [seed]
        area = 0
        changed_pixels = 0
        minimum_x = width
        minimum_y = height
        maximum_x = 0
        maximum_y = 0
        perimeter_edges = 0
        reference_luma_sum = 0.0
        candidate_luma_sum = 0.0
        candidate_luma_minimum = 1.0
        candidate_luma_maximum = 0.0
        candidate_rgb_sum = [0.0, 0.0, 0.0]
        component_fingerprint = hashlib.sha256()
        component_fingerprint.update(
            ("component-v%d:%dx%d" % (
                DARK_RECTANGLE_DETECTOR_VERSION,
                width,
                height,
            )).encode("ascii")
        )

        while stack:
            pixel = stack.pop()
            x = pixel % width
            y = pixel // width
            area += 1
            minimum_x = min(minimum_x, x)
            minimum_y = min(minimum_y, y)
            maximum_x = max(maximum_x, x)
            maximum_y = max(maximum_y, y)
            component_fingerprint.update(struct.pack("<Q", pixel))

            exact = pixel * reference.exact_stride
            exact_end = exact + reference.exact_stride
            changed_pixels += (
                reference.exact_pixels[exact:exact_end]
                != candidate.exact_pixels[exact:exact_end]
            )
            reference_value = reference_luma[pixel]
            candidate_value = candidate_luma[pixel]
            reference_luma_sum += reference_value
            candidate_luma_sum += candidate_value
            candidate_luma_minimum = min(candidate_luma_minimum, candidate_value)
            candidate_luma_maximum = max(candidate_luma_maximum, candidate_value)
            sample = pixel * 4
            for channel in range(3):
                candidate_rgb_sum[channel] += candidate.samples[sample + channel]

            neighbors = (
                pixel - 1 if x > 0 else None,
                pixel + 1 if x + 1 < width else None,
                pixel - width if y > 0 else None,
                pixel + width if y + 1 < height else None,
            )
            for neighbor in neighbors:
                if neighbor is None or not mask[neighbor]:
                    perimeter_edges += 1
                elif not visited[neighbor]:
                    visited[neighbor] = 1
                    stack.append(neighbor)

        bounds_width = maximum_x - minimum_x + 1
        bounds_height = maximum_y - minimum_y + 1
        bounds_area = bounds_width * bounds_height
        fill_ratio = area / bounds_area
        ideal_perimeter = 2 * (bounds_width + bounds_height)
        edge_regularity = min(
            1.0, ideal_perimeter / perimeter_edges if perimeter_edges else 0.0
        )
        changed_percent = changed_pixels * 100.0 / area
        reference_mean_luma = reference_luma_sum / area
        candidate_mean_luma = candidate_luma_sum / area
        mean_luma_drop = reference_mean_luma - candidate_mean_luma
        is_rectangle = (
            bounds_width >= DARK_RECTANGLE_MIN_WIDTH
            and bounds_height >= DARK_RECTANGLE_MIN_HEIGHT
            and area >= DARK_RECTANGLE_MIN_PIXELS
            and fill_ratio >= DARK_RECTANGLE_MIN_FILL_RATIO
            and edge_regularity >= DARK_RECTANGLE_MIN_EDGE_REGULARITY
            and changed_percent >= DARK_RECTANGLE_MIN_CHANGED_PERCENT
            and mean_luma_drop >= DARK_RECTANGLE_MIN_MEAN_LUMA_DROP
        )
        if not is_rectangle:
            continue

        component_signature = component_fingerprint.hexdigest()[:24]
        rectangle = {
            "bounds": {
                "x": minimum_x,
                "y": minimum_y,
                "width": bounds_width,
                "height": bounds_height,
            },
            "areaPixels": area,
            "fillPercent": rounded(fill_ratio * 100.0),
            "edgeRegularityPercent": rounded(edge_regularity * 100.0),
            "perimeterEdges": perimeter_edges,
            "changedPixels": changed_pixels,
            "changedPercent": rounded(changed_percent),
            "interior": {
                "referenceMeanLuma": rounded(reference_mean_luma),
                "candidateMeanLuma": rounded(candidate_mean_luma),
                "candidateMinimumLuma": rounded(candidate_luma_minimum),
                "candidateMaximumLuma": rounded(candidate_luma_maximum),
                "meanLumaDrop": rounded(mean_luma_drop),
                "candidateMeanRgb": {
                    "red": rounded(candidate_rgb_sum[0] / area),
                    "green": rounded(candidate_rgb_sum[1] / area),
                    "blue": rounded(candidate_rgb_sum[2] / area),
                },
            },
            "componentFingerprint": component_signature,
        }
        rectangle_count += 1
        rectangle_pixels += area
        rectangle_fingerprint.update(
            struct.pack(
                "<IIIII",
                minimum_x,
                minimum_y,
                bounds_width,
                bounds_height,
                area,
            )
        )
        rectangle_fingerprint.update(component_signature.encode("ascii"))
        reported_rectangles.append(rectangle)
        reported_rectangles.sort(
            key=lambda item: (
                -item["areaPixels"],
                item["bounds"]["y"],
                item["bounds"]["x"],
            )
        )
        del reported_rectangles[DARK_RECTANGLE_MAX_REPORTED:]

    return {
        "detectorVersion": DARK_RECTANGLE_DETECTOR_VERSION,
        "luminanceSpace": "linear-rec709-after-display-mapping",
        "maskRule": {
            "candidateLumaAtMost": DARK_RECTANGLE_MAX_CANDIDATE_LUMA,
            "connectivity": 4,
        },
        "rectangleRule": {
            "minimumWidth": DARK_RECTANGLE_MIN_WIDTH,
            "minimumHeight": DARK_RECTANGLE_MIN_HEIGHT,
            "minimumPixels": DARK_RECTANGLE_MIN_PIXELS,
            "minimumFillPercent": rounded(DARK_RECTANGLE_MIN_FILL_RATIO * 100.0),
            "minimumEdgeRegularityPercent": rounded(
                DARK_RECTANGLE_MIN_EDGE_REGULARITY * 100.0
            ),
            "minimumChangedPercent": DARK_RECTANGLE_MIN_CHANGED_PERCENT,
            "minimumMeanLumaDrop": DARK_RECTANGLE_MIN_MEAN_LUMA_DROP,
        },
        "darkMaskPixels": mask_pixels,
        "darkMaskPercent": rounded(mask_pixels * 100.0 / pixels),
        "connectedComponents": connected_components,
        "rectangleCount": rectangle_count,
        "rectanglePixels": rectangle_pixels,
        "darkMaskFingerprint": mask_fingerprint.hexdigest()[:24],
        "rectangleMaskFingerprint": rectangle_fingerprint.hexdigest()[:24],
        "rectanglesReported": len(reported_rectangles),
        "rectanglesTruncated": rectangle_count > len(reported_rectangles),
        "rectangles": reported_rectangles,
    }


def compare_frames(case: Dict[str, Any], reference: Frame, candidate: Frame) -> Dict[str, Any]:
    if reference.format != candidate.format:
        raise HarnessError("%s captures use different decoded formats." % case["id"])
    if reference.width != candidate.width or reference.height != candidate.height:
        raise HarnessError("%s captures use different dimensions." % case["id"])
    if reference.exact_stride != candidate.exact_stride:
        raise HarnessError("%s captures use incompatible pixel layouts." % case["id"])

    width = reference.width
    height = reference.height
    pixels = width * height
    tile_size = case["tileSize"]
    tiles_wide = (width + tile_size - 1) // tile_size
    tiles_high = (height + tile_size - 1) // tile_size
    tile_stats = [
        {
            "pixels": 0,
            "mismatches": 0,
            "color": 0.0,
            "luma": 0.0,
            "max": 0.0,
            "channels": [0.0, 0.0, 0.0],
        }
        for _ in range(tiles_wide * tiles_high)
    ]
    channel_sum = [0.0, 0.0, 0.0, 0.0]
    channel_signed = [0.0, 0.0, 0.0, 0.0]
    channel_max = [0.0, 0.0, 0.0, 0.0]
    color_sum = 0.0
    color_max = 0.0
    luma_sum = 0.0
    luma_max = 0.0
    mismatch_count = 0
    minimum_x = width
    minimum_y = height
    maximum_x = 0
    maximum_y = 0
    color_histogram = [0] * (HISTOGRAM_BINS + 1)
    reference_luma_histogram = [0] * (HISTOGRAM_BINS + 1)
    candidate_luma_histogram = [0] * (HISTOGRAM_BINS + 1)
    reference_clipped_white = 0
    candidate_clipped_white = 0
    reference_retained_black = 0
    candidate_retained_black = 0
    reference_luma = array("f", [0.0]) * pixels
    candidate_luma = array("f", [0.0]) * pixels
    fingerprint = hashlib.sha256()
    fingerprint.update(
        ("%s:%dx%d" % (reference.format, width, height)).encode("ascii")
    )

    for pixel in range(pixels):
        x = pixel % width
        y = pixel // width
        sample = pixel * 4
        exact = pixel * reference.exact_stride
        exact_end = exact + reference.exact_stride
        changed = (
            reference.exact_pixels[exact:exact_end]
            != candidate.exact_pixels[exact:exact_end]
        )
        if changed:
            mismatch_count += 1
            minimum_x = min(minimum_x, x)
            minimum_y = min(minimum_y, y)
            maximum_x = max(maximum_x, x)
            maximum_y = max(maximum_y, y)
            fingerprint.update(struct.pack("<Q", pixel))
            fingerprint.update(reference.exact_pixels[exact:exact_end])
            fingerprint.update(candidate.exact_pixels[exact:exact_end])

        differences = [
            candidate.samples[sample + channel] - reference.samples[sample + channel]
            for channel in range(4)
        ]
        absolutes = [abs(value) for value in differences]
        for channel in range(4):
            channel_sum[channel] += absolutes[channel]
            channel_signed[channel] += differences[channel]
            channel_max[channel] = max(channel_max[channel], absolutes[channel])
        color_distance = math.sqrt(
            0.2126 * differences[0] * differences[0]
            + 0.7152 * differences[1] * differences[1]
            + 0.0722 * differences[2] * differences[2]
        )
        color_sum += color_distance
        color_max = max(color_max, color_distance)
        color_histogram_index = min(
            HISTOGRAM_BINS, int(color_distance * HISTOGRAM_BINS)
        )
        color_histogram[color_histogram_index] += 1

        ref_luma = (
            0.2126 * srgb_to_linear(reference.samples[sample])
            + 0.7152 * srgb_to_linear(reference.samples[sample + 1])
            + 0.0722 * srgb_to_linear(reference.samples[sample + 2])
        )
        cand_luma = (
            0.2126 * srgb_to_linear(candidate.samples[sample])
            + 0.7152 * srgb_to_linear(candidate.samples[sample + 1])
            + 0.0722 * srgb_to_linear(candidate.samples[sample + 2])
        )
        reference_luma[pixel] = ref_luma
        candidate_luma[pixel] = cand_luma
        reference_luma_histogram[luma_histogram_index(ref_luma)] += 1
        candidate_luma_histogram[luma_histogram_index(cand_luma)] += 1
        reference_clipped_white += ref_luma >= CLIPPED_WHITE_LUMA
        candidate_clipped_white += cand_luma >= CLIPPED_WHITE_LUMA
        reference_retained_black += ref_luma <= RETAINED_BLACK_LUMA
        candidate_retained_black += cand_luma <= RETAINED_BLACK_LUMA
        luma_error = abs(cand_luma - ref_luma)
        luma_sum += luma_error
        luma_max = max(luma_max, luma_error)

        tile_index = (y // tile_size) * tiles_wide + (x // tile_size)
        tile = tile_stats[tile_index]
        tile["pixels"] += 1
        tile["mismatches"] += 1 if changed else 0
        tile["color"] += color_distance
        tile["luma"] += luma_error
        tile["max"] = max(tile["max"], max(absolutes[:3]))
        for channel in range(3):
            tile["channels"][channel] += absolutes[channel]

    edge_sum = 0.0
    edge_max = 0.0
    edge_samples = 0
    for y in range(height):
        for x in range(width):
            index = y * width + x
            if x > 0:
                error = abs(
                    (candidate_luma[index] - candidate_luma[index - 1])
                    - (reference_luma[index] - reference_luma[index - 1])
                )
                edge_sum += error
                edge_max = max(edge_max, error)
                edge_samples += 1
            if y > 0:
                error = abs(
                    (candidate_luma[index] - candidate_luma[index - width])
                    - (reference_luma[index] - reference_luma[index - width])
                )
                edge_sum += error
                edge_max = max(edge_max, error)
                edge_samples += 1

    channel_names = ("red", "green", "blue", "alpha")
    channels = {}
    for index, name in enumerate(channel_names):
        channels[name] = {
            "meanAbsoluteError": rounded(channel_sum[index] / pixels),
            "maxAbsoluteError": rounded(channel_max[index]),
            "signedMeanError": rounded(channel_signed[index] / pixels),
        }

    changed_tiles = 0
    fully_changed_tiles = 0
    ranked_tiles = []
    for tile_y in range(tiles_high):
        for tile_x in range(tiles_wide):
            tile = tile_stats[tile_y * tiles_wide + tile_x]
            if tile["mismatches"] == 0:
                continue
            changed_tiles += 1
            fully_changed_tiles += tile["mismatches"] == tile["pixels"]
            dominant_index = max(range(3), key=lambda index: tile["channels"][index])
            ranked_tiles.append(
                {
                    "tileX": tile_x,
                    "tileY": tile_y,
                    "x": tile_x * tile_size,
                    "y": tile_y * tile_size,
                    "width": min(tile_size, width - tile_x * tile_size),
                    "height": min(tile_size, height - tile_y * tile_size),
                    "mismatchPixels": tile["mismatches"],
                    "mismatchPercent": rounded(
                        tile["mismatches"] * 100.0 / tile["pixels"]
                    ),
                    "meanColorDistance": rounded(tile["color"] / tile["pixels"]),
                    "meanLumaError": rounded(tile["luma"] / tile["pixels"]),
                    "maxChannelError": rounded(tile["max"]),
                    "dominantErrorChannel": channel_names[dominant_index],
                }
            )
    ranked_tiles.sort(
        key=lambda tile: (
            -tile["meanColorDistance"],
            -tile["mismatchPercent"],
            tile["tileY"],
            tile["tileX"],
        )
    )

    mismatch_percent = mismatch_count * 100.0 / pixels
    mean_absolute_error = sum(channel_sum[:3]) / (pixels * 3)
    p95_color = histogram_percentile(color_histogram, pixels, 0.95)
    reference_distribution = luminance_distribution(
        reference_luma_histogram,
        pixels,
        reference_clipped_white,
        reference_retained_black,
    )
    candidate_distribution = luminance_distribution(
        candidate_luma_histogram,
        pixels,
        candidate_clipped_white,
        candidate_retained_black,
    )
    luminance_delta = {
        name: rounded(candidate_distribution[name] - reference_distribution[name])
        for name, _ in LUMA_PERCENTILES
    }
    luminance_delta.update(
        {
            "clippedWhitePixels": (
                candidate_clipped_white - reference_clipped_white
            ),
            "clippedWhitePercentagePoints": rounded(
                candidate_distribution["clippedWhitePercent"]
                - reference_distribution["clippedWhitePercent"]
            ),
            "retainedBlackPixels": (
                candidate_retained_black - reference_retained_black
            ),
            "retainedBlackPercentagePoints": rounded(
                candidate_distribution["retainedBlackPercent"]
                - reference_distribution["retainedBlackPercent"]
            ),
        }
    )
    dark_rectangles = dark_rectangle_diagnostics(
        reference,
        candidate,
        reference_luma,
        candidate_luma,
    )
    metrics = {
        "pixels": pixels,
        "exactMismatchPixels": mismatch_count,
        "exactMismatchPercent": rounded(mismatch_percent),
        "differenceBounds": None
        if mismatch_count == 0
        else {
            "x": minimum_x,
            "y": minimum_y,
            "width": maximum_x - minimum_x + 1,
            "height": maximum_y - minimum_y + 1,
        },
        "meanAbsoluteError": rounded(mean_absolute_error),
        "maxAbsoluteError": rounded(max(channel_max[:3])),
        "channels": channels,
        "perceptual": {
            "meanColorDistance": rounded(color_sum / pixels),
            "p95ColorDistance": rounded(p95_color),
            "maxColorDistance": rounded(color_max),
            "meanLumaError": rounded(luma_sum / pixels),
            "maxLumaError": rounded(luma_max),
            "meanEdgeError": rounded(edge_sum / edge_samples if edge_samples else 0.0),
            "maxEdgeError": rounded(edge_max),
        },
        "luminance": {
            "space": "linear-rec709-after-display-mapping",
            "quantizationSteps": HISTOGRAM_BINS,
            "clippedWhiteThreshold": CLIPPED_WHITE_LUMA,
            "retainedBlackThreshold": RETAINED_BLACK_LUMA,
            "reference": reference_distribution,
            "candidate": candidate_distribution,
            "delta": luminance_delta,
        },
        "darkRectangles": dark_rectangles,
        "tiles": {
            "tileSize": tile_size,
            "columns": tiles_wide,
            "rows": tiles_high,
            "changed": changed_tiles,
            "fullyChanged": fully_changed_tiles,
            "worst": ranked_tiles[:8],
        },
        "nonFiniteSamples": {
            "reference": reference.non_finite_samples,
            "candidate": candidate.non_finite_samples,
        },
        "differenceFingerprint": fingerprint.hexdigest()[:24],
    }

    tolerance = case["tolerance"]
    violations = []
    checks = {
        "maxMismatchPercent": mismatch_percent,
        "maxMeanAbsoluteError": mean_absolute_error,
        "maxP95ColorDistance": p95_color,
        "maxMeanLumaError": luma_sum / pixels,
        "maxChangedTiles": changed_tiles,
        "maxDarkRectangles": dark_rectangles["rectangleCount"],
    }
    for key, limit in tolerance.items():
        if checks[key] > limit:
            violations.append(key)
    if mismatch_count == 0:
        status = "exact"
    elif not tolerance:
        status = "changed-unrated"
    elif violations:
        status = "regression"
    else:
        status = "within-tolerance"
    return {
        "id": case["id"],
        "title": case["title"],
        "scene": case["scene"],
        "referenceBackend": case["reference"]["backend"],
        "candidateBackend": case["candidate"]["backend"],
        "format": reference.format,
        "width": width,
        "height": height,
        "status": status,
        "tolerance": tolerance,
        "violations": violations,
        "metrics": metrics,
    }


def assert_public_result_clean(
    result: Dict[str, Any], comparisons: Sequence[Dict[str, Any]]
) -> None:
    serialized = json.dumps(result, sort_keys=True)
    secrets_to_reject = []
    for comparison in comparisons:
        for role in ("reference", "candidate"):
            path = comparison[role]["path"]
            secrets_to_reject.extend((str(path), path.name, str(path.parent)))
    if any(secret and secret in serialized for secret in secrets_to_reject):
        raise HarnessError("The public visual result failed its private-path scan.")
    if re.search(r"/(?:Users|Volumes|private|tmp|var/folders)/", serialized):
        raise HarnessError("The public visual result contains a local path.")


def command_init(args: argparse.Namespace) -> int:
    path = pathlib.Path(args.manifest).expanduser()
    require_private_location(path, "The private visual manifest")
    if path.exists():
        raise HarnessError("The private visual manifest already exists.")
    write_json_atomic(
        path,
        {"schemaVersion": SCHEMA_VERSION, "private": True, "comparisons": []},
        private=True,
    )
    print(json.dumps({"created": True, "pathsDisclosed": False}, sort_keys=True))
    return 0


def command_validate(args: argparse.Namespace) -> int:
    comparisons = load_manifest(pathlib.Path(args.manifest), require_cases=False)
    print(
        json.dumps(
            {
                "valid": True,
                "comparisons": len(comparisons),
                "pathsDisclosed": False,
            },
            sort_keys=True,
        )
    )
    return 0


def command_compare(args: argparse.Namespace) -> int:
    comparisons = load_manifest(pathlib.Path(args.manifest), require_cases=True)
    results = []
    for comparison in comparisons:
        try:
            reference = load_frame(comparison["reference"])
            candidate = load_frame(comparison["candidate"])
        except HarnessError as error:
            raise HarnessError("%s: %s" % (comparison["id"], error))
        results.append(compare_frames(comparison, reference, candidate))
    summary = {
        "comparisons": len(results),
        "exact": sum(item["status"] == "exact" for item in results),
        "withinTolerance": sum(
            item["status"] == "within-tolerance" for item in results
        ),
        "changedUnrated": sum(
            item["status"] == "changed-unrated" for item in results
        ),
        "regressions": sum(item["status"] == "regression" for item in results),
    }
    public_result = {
        "schemaVersion": SCHEMA_VERSION,
        "runnerVersion": RUNNER_VERSION,
        "privacy": {
            "containsLocalPaths": False,
            "rawCapturesIncluded": False,
            "captureNamesIncluded": False,
        },
        "scope": {
            "offlineOnly": True,
            "launchesGames": False,
            "resizesOrColorMatchesCaptures": False,
        },
        "summary": summary,
        "comparisons": results,
    }
    assert_public_result_clean(public_result, comparisons)
    output = pathlib.Path(args.output).expanduser()
    if output.resolve() in {
        comparison[role]["path"]
        for comparison in comparisons
        for role in ("reference", "candidate")
    }:
        raise HarnessError("The public output cannot overwrite a private capture.")
    write_json_atomic(output, public_result, private=False)
    print(
        json.dumps(
            {"complete": True, "summary": summary, "pathsDisclosed": False},
            sort_keys=True,
        )
    )
    failed = summary["regressions"] > 0 or (
        args.strict and summary["changedUnrated"] > 0
    )
    return 1 if failed else 0


def command_transfer_regression(args: argparse.Namespace) -> int:
    correct, mismatched = srgb_gray_ramp_frames()
    baseline = compare_frames(
        transfer_case("srgb-gray-ramp-baseline", "bgra8unorm-correct"),
        correct,
        correct,
    )
    mismatch = compare_frames(
        transfer_case(
            "srgb-gray-ramp-decoded-linear",
            "decoded-linear-written-to-bgra8unorm",
        ),
        correct,
        mismatched,
    )
    signatures = {
        "encodedSrgbRampSha256": hashlib.sha256(
            correct.exact_pixels
        ).hexdigest(),
        "correctBgra8UnormSha256": hashlib.sha256(
            correct.exact_pixels
        ).hexdigest(),
        "decodedLinearBgra8UnormSha256": hashlib.sha256(
            mismatched.exact_pixels
        ).hexdigest(),
        "differenceFingerprint": mismatch["metrics"]["differenceFingerprint"],
    }
    mismatch_metrics = mismatch["metrics"]
    mismatch_luma_delta = mismatch_metrics["luminance"]["delta"]
    checks = {
        "baselineIsExact": baseline["status"] == "exact",
        "correctSignatureMatches": (
            signatures["correctBgra8UnormSha256"]
            == TRANSFER_CORRECT_SIGNATURE
        ),
        "mismatchSignatureMatches": (
            signatures["decodedLinearBgra8UnormSha256"]
            == TRANSFER_MISMATCH_SIGNATURE
        ),
        "differenceFingerprintMatches": (
            signatures["differenceFingerprint"]
            == TRANSFER_DIFFERENCE_FINGERPRINT
        ),
        "mismatchPercentDetected": (
            mismatch_metrics["exactMismatchPercent"]
            >= TRANSFER_MIN_MISMATCH_PERCENT
        ),
        "meanErrorDetected": (
            mismatch_metrics["meanAbsoluteError"]
            >= TRANSFER_MIN_MEAN_ABSOLUTE_ERROR
        ),
        "retainedBlackShiftDetected": (
            mismatch_luma_delta["retainedBlackPercentagePoints"]
            >= TRANSFER_MIN_RETAINED_BLACK_PERCENTAGE_POINTS
        ),
        "medianLumaShiftDetected": (
            mismatch_luma_delta["p50"] <= TRANSFER_MAX_P50_LUMA_DELTA
        ),
    }
    detected = all(checks.values())
    public_result = {
        "schemaVersion": SCHEMA_VERSION,
        "runnerVersion": RUNNER_VERSION,
        "privacy": {
            "containsLocalPaths": False,
            "rawCapturesIncluded": False,
            "captureNamesIncluded": False,
        },
        "scope": {
            "offlineOnly": True,
            "launchesGames": False,
            "usesGpu": False,
            "syntheticDetectorOnly": True,
        },
        "contract": {
            "name": "srgb-source-to-bgra8unorm-gray-ramp",
            "levels": TRANSFER_RAMP_LEVELS,
            "correctBehavior": (
                "encoded sRGB gray values remain encoded in BGRA8Unorm"
            ),
            "modeledFailure": (
                "sRGB sampling decodes to linear and writes those values "
                "directly to BGRA8Unorm without re-encoding"
            ),
            "normalizedRounding": "nearest-even",
        },
        "expectedSignatures": {
            "correctBgra8UnormSha256": TRANSFER_CORRECT_SIGNATURE,
            "decodedLinearBgra8UnormSha256": TRANSFER_MISMATCH_SIGNATURE,
            "differenceFingerprint": TRANSFER_DIFFERENCE_FINGERPRINT,
        },
        "thresholds": {
            "minimumMismatchPercent": TRANSFER_MIN_MISMATCH_PERCENT,
            "minimumMeanAbsoluteError": TRANSFER_MIN_MEAN_ABSOLUTE_ERROR,
            "minimumRetainedBlackPercentagePointIncrease": (
                TRANSFER_MIN_RETAINED_BLACK_PERCENTAGE_POINTS
            ),
            "maximumP50LumaDelta": TRANSFER_MAX_P50_LUMA_DELTA,
        },
        "observedSignatures": signatures,
        "checks": checks,
        "status": "detected" if detected else "not-detected",
        "baseline": baseline,
        "modeledMismatch": mismatch,
    }
    serialized = json.dumps(public_result, sort_keys=True)
    if re.search(r"/(?:Users|Volumes|private|tmp|var/folders)/", serialized):
        raise HarnessError("The transfer-regression result contains a local path.")
    output = pathlib.Path(args.output).expanduser()
    write_json_atomic(output, public_result, private=False)
    print(
        json.dumps(
            {
                "complete": True,
                "status": public_result["status"],
                "pathsDisclosed": False,
            },
            sort_keys=True,
        )
    )
    return 0 if detected else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Compare paired SolMetal captures without launching a game."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    initialize = subparsers.add_parser("init", help="Create an owner-only manifest.")
    initialize.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    initialize.set_defaults(function=command_init)
    validate = subparsers.add_parser("validate", help="Validate private pair metadata.")
    validate.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    validate.set_defaults(function=command_validate)
    compare = subparsers.add_parser("compare", help="Run every offline image comparison.")
    compare.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    compare.add_argument("--output", default=str(DEFAULT_PUBLIC_OUTPUT))
    compare.add_argument(
        "--strict",
        action="store_true",
        help="Fail when a changed comparison has no explicit tolerance.",
    )
    compare.set_defaults(function=command_compare)
    transfer = subparsers.add_parser(
        "transfer-regression",
        help="Verify the offline sRGB-to-UNORM mismatch detector.",
    )
    transfer.add_argument(
        "--output",
        default="solmetal-color-transfer-results.json",
    )
    transfer.set_defaults(function=command_transfer_regression)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return int(args.function(args))
    except HarnessError as error:
        print("solmetal-visual-regression: %s" % error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
