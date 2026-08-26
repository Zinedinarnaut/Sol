#!/usr/bin/env python3
"""Offline tests for the SolMetal visual-regression companion."""

import binascii
import json
import os
import pathlib
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib


ROOT = pathlib.Path(__file__).resolve().parent.parent
HARNESS = ROOT / "script" / "solmetal_visual_regression.py"


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    checksum = binascii.crc32(kind)
    checksum = binascii.crc32(payload, checksum) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)


def write_png(path: pathlib.Path, width: int, height: int, rgba: bytes) -> None:
    rows = b"".join(
        b"\x00" + rgba[y * width * 4 : (y + 1) * width * 4]
        for y in range(height)
    )
    contents = (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(rows))
        + png_chunk(b"IEND", b"")
    )
    path.write_bytes(contents)


class SolMetalVisualRegressionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="solmetal-visual-test-")
        self.root = pathlib.Path(self.temporary.name)
        self.manifest = self.root / "suite.private.json"
        self.output = self.root / "public.json"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_harness(self, *arguments: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(HARNESS), *arguments],
            cwd=str(ROOT),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

    def write_manifest(self, comparisons: list) -> None:
        self.manifest.write_text(
            json.dumps(
                {"schemaVersion": 1, "private": True, "comparisons": comparisons}
            ),
            encoding="utf-8",
        )
        self.manifest.chmod(0o600)

    def png_spec(self, path: pathlib.Path, title: str, backend: str) -> dict:
        return {
            "title": title,
            "backend": backend,
            "path": str(path),
            "format": "png",
        }

    def test_init_creates_owner_only_manifest_without_disclosing_path(self) -> None:
        result = self.run_harness("init", "--manifest", str(self.manifest))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(stat.S_IMODE(self.manifest.stat().st_mode), 0o600)
        self.assertNotIn(str(self.manifest), result.stdout)
        manifest = json.loads(self.manifest.read_text(encoding="utf-8"))
        self.assertTrue(manifest["private"])
        self.assertEqual(manifest["comparisons"], [])

    def test_exact_png_pair_has_zero_error_and_redacted_output(self) -> None:
        reference = self.root / "Private Reference Name.png"
        candidate = self.root / "Private Candidate Name.png"
        pixels = bytes(
            channel
            for y in range(32)
            for x in range(48)
            for channel in (x * 5 % 256, y * 7 % 256, (x + y) * 3 % 256, 255)
        )
        write_png(reference, 48, 32, pixels)
        write_png(candidate, 48, 32, pixels)
        self.write_manifest(
            [
                {
                    "id": "totk-cave",
                    "scene": "warm-checkpoint",
                    "reference": self.png_spec(reference, "totk", "moltenvk"),
                    "candidate": self.png_spec(candidate, "totk", "solmetal"),
                }
            ]
        )
        result = self.run_harness(
            "compare", "--manifest", str(self.manifest), "--output", str(self.output)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(self.output.read_text(encoding="utf-8"))
        comparison = report["comparisons"][0]
        self.assertEqual(comparison["status"], "exact")
        self.assertEqual(comparison["metrics"]["exactMismatchPixels"], 0)
        self.assertEqual(comparison["metrics"]["meanAbsoluteError"], 0)
        serialized = json.dumps(report)
        self.assertNotIn(str(self.root), serialized)
        self.assertNotIn(reference.name, serialized)
        self.assertNotIn(candidate.name, serialized)
        self.assertNotIn(str(self.root), result.stdout)
        second_output = self.root / "public-again.json"
        second = self.run_harness(
            "compare",
            "--manifest",
            str(self.manifest),
            "--output",
            str(second_output),
        )
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.output.read_bytes(), second_output.read_bytes())

    def test_transfer_regression_detects_srgb_decode_into_unorm(self) -> None:
        result = self.run_harness(
            "transfer-regression", "--output", str(self.output)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(self.output.read_text(encoding="utf-8"))
        self.assertEqual(report["runnerVersion"], "4")
        self.assertEqual(report["status"], "detected")
        self.assertTrue(report["scope"]["syntheticDetectorOnly"])
        self.assertTrue(all(report["checks"].values()))
        self.assertEqual(
            report["expectedSignatures"]["correctBgra8UnormSha256"],
            "f7721524360322232937cff69886be54d18f94dc172627061757855971b5db36",
        )
        self.assertEqual(
            report["expectedSignatures"]["decodedLinearBgra8UnormSha256"],
            "38054d3b7822df8e784644befb2be76c3f98958ebfc799d7294ba5cdada6b142",
        )
        self.assertEqual(
            report["expectedSignatures"]["differenceFingerprint"],
            "a6000a270eecd503d54512dd",
        )
        self.assertEqual(report["baseline"]["status"], "exact")
        mismatch = report["modeledMismatch"]
        self.assertEqual(mismatch["status"], "regression")
        self.assertEqual(mismatch["metrics"]["exactMismatchPixels"], 254)
        self.assertEqual(mismatch["metrics"]["exactMismatchPercent"], 99.21875)
        self.assertEqual(mismatch["metrics"]["meanAbsoluteError"], 0.18897059)
        self.assertEqual(
            mismatch["metrics"]["luminance"]["delta"][
                "retainedBlackPercentagePoints"
            ],
            27.34375,
        )
        self.assertEqual(
            mismatch["metrics"]["luminance"]["delta"]["p50"],
            -0.17529297,
        )
        serialized = json.dumps(report)
        self.assertNotIn(str(self.root), serialized)
        self.assertNotIn(str(self.output), result.stdout)

        second_output = self.root / "transfer-again.json"
        second = self.run_harness(
            "transfer-regression", "--output", str(second_output)
        )
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.output.read_bytes(), second_output.read_bytes())

    def test_changed_png_reports_bounds_channels_tiles_and_regression(self) -> None:
        width = 128
        height = 128
        reference = self.root / "reference.png"
        candidate = self.root / "candidate.png"
        base = bytearray([16, 16, 16, 255] * (width * height))
        changed = bytearray(base)
        for y in range(70, 78):
            for x in range(75, 83):
                offset = (y * width + x) * 4
                changed[offset] = 240
        write_png(reference, width, height, bytes(base))
        write_png(candidate, width, height, bytes(changed))
        self.write_manifest(
            [
                {
                    "id": "mk8-race",
                    "scene": "lap-checkpoint",
                    "tileSize": 64,
                    "reference": self.png_spec(reference, "mk8", "moltenvk"),
                    "candidate": self.png_spec(candidate, "mk8", "solmetal"),
                    "tolerance": {
                        "maxMismatchPercent": 0,
                        "maxMeanAbsoluteError": 0,
                    },
                }
            ]
        )
        result = self.run_harness(
            "compare", "--manifest", str(self.manifest), "--output", str(self.output)
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        comparison = json.loads(self.output.read_text(encoding="utf-8"))["comparisons"][0]
        metrics = comparison["metrics"]
        self.assertEqual(comparison["status"], "regression")
        self.assertEqual(metrics["exactMismatchPixels"], 64)
        self.assertEqual(metrics["differenceBounds"], {"x": 75, "y": 70, "width": 8, "height": 8})
        self.assertEqual(metrics["tiles"]["changed"], 1)
        self.assertEqual(metrics["tiles"]["worst"][0]["tileX"], 1)
        self.assertEqual(metrics["tiles"]["worst"][0]["tileY"], 1)
        self.assertEqual(metrics["tiles"]["worst"][0]["dominantErrorChannel"], "red")
        self.assertGreater(metrics["perceptual"]["meanEdgeError"], 0)

    def test_dark_rectangle_detector_reports_two_deterministic_components(self) -> None:
        width = 128
        height = 96
        reference = self.root / "Private Rectangle Reference.png"
        candidate = self.root / "Private Rectangle Candidate.png"
        baseline = bytearray([96, 96, 96, 255] * (width * height))

        def fill(pixels: bytearray, x: int, y: int, w: int, h: int) -> None:
            for row in range(y, y + h):
                for column in range(x, x + w):
                    offset = (row * width + column) * 4
                    pixels[offset : offset + 4] = bytes((0, 0, 0, 255))

        # An unchanged near-black block proves that absolute scene darkness is
        # not classified as a new artifact.
        fill(baseline, 0, 0, 16, 8)
        changed = bytearray(baseline)
        fill(changed, 12, 16, 32, 20)
        fill(changed, 72, 44, 40, 24)
        write_png(reference, width, height, bytes(baseline))
        write_png(candidate, width, height, bytes(changed))
        self.write_manifest(
            [
                {
                    "id": "scene-dark-rectangles",
                    "scene": "fixed-checkpoint",
                    "reference": self.png_spec(reference, "fixture", "reference"),
                    "candidate": self.png_spec(candidate, "fixture", "candidate"),
                    "tolerance": {"maxDarkRectangles": 0},
                }
            ]
        )

        result = self.run_harness(
            "compare", "--manifest", str(self.manifest), "--output", str(self.output)
        )

        self.assertEqual(result.returncode, 1, result.stderr)
        report = json.loads(self.output.read_text(encoding="utf-8"))
        comparison = report["comparisons"][0]
        diagnostic = comparison["metrics"]["darkRectangles"]
        self.assertEqual(comparison["violations"], ["maxDarkRectangles"])
        self.assertEqual(diagnostic["connectedComponents"], 3)
        self.assertEqual(diagnostic["rectangleCount"], 2)
        self.assertEqual(diagnostic["rectanglePixels"], 1600)
        self.assertEqual(
            diagnostic["darkMaskFingerprint"], "89d81bd35666ac2dbafdf5bc"
        )
        self.assertEqual(
            diagnostic["rectangleMaskFingerprint"], "bb9f6585afbac5c60835e3df"
        )
        self.assertEqual(
            [rectangle["bounds"] for rectangle in diagnostic["rectangles"]],
            [
                {"x": 72, "y": 44, "width": 40, "height": 24},
                {"x": 12, "y": 16, "width": 32, "height": 20},
            ],
        )
        self.assertTrue(
            all(
                rectangle["fillPercent"] == 100
                and rectangle["edgeRegularityPercent"] == 100
                and rectangle["changedPercent"] == 100
                for rectangle in diagnostic["rectangles"]
            )
        )
        serialized = json.dumps(report)
        self.assertNotIn(str(self.root), serialized)
        self.assertNotIn(reference.name, serialized)
        self.assertNotIn(candidate.name, serialized)

        second_output = self.root / "rectangle-again.json"
        second = self.run_harness(
            "compare",
            "--manifest",
            str(self.manifest),
            "--output",
            str(second_output),
        )
        self.assertEqual(second.returncode, 1, second.stderr)
        self.assertEqual(self.output.read_bytes(), second_output.read_bytes())

    def test_dark_rectangle_detector_rejects_unchanged_and_irregular_dark_regions(self) -> None:
        width = 64
        height = 64
        reference = self.root / "Private Shape Reference.png"
        candidate = self.root / "Private Shape Candidate.png"
        baseline = bytearray([96, 96, 96, 255] * (width * height))

        def black(pixels: bytearray, x: int, y: int) -> None:
            offset = (y * width + x) * 4
            pixels[offset : offset + 4] = bytes((0, 0, 0, 255))

        for y in range(8, 24):
            for x in range(8, 24):
                black(baseline, x, y)
        changed = bytearray(baseline)
        for y in range(32, 56):
            for x in range(40, 43):
                black(changed, x, y)
        for y in range(53, 56):
            for x in range(40, 60):
                black(changed, x, y)
        write_png(reference, width, height, bytes(baseline))
        write_png(candidate, width, height, bytes(changed))
        self.write_manifest(
            [
                {
                    "id": "scene-dark-nonrectangles",
                    "scene": "fixed-checkpoint",
                    "reference": self.png_spec(reference, "fixture", "reference"),
                    "candidate": self.png_spec(candidate, "fixture", "candidate"),
                    "tolerance": {"maxDarkRectangles": 0},
                }
            ]
        )

        result = self.run_harness(
            "compare", "--manifest", str(self.manifest), "--output", str(self.output)
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        comparison = json.loads(self.output.read_text(encoding="utf-8"))[
            "comparisons"
        ][0]
        diagnostic = comparison["metrics"]["darkRectangles"]
        self.assertEqual(comparison["status"], "within-tolerance")
        self.assertEqual(comparison["violations"], [])
        self.assertEqual(diagnostic["connectedComponents"], 2)
        self.assertEqual(diagnostic["rectangleCount"], 0)
        self.assertEqual(diagnostic["rectangles"], [])

    def test_png_reports_deterministic_luminance_distribution(self) -> None:
        reference = self.root / "Private Luma Reference.png"
        candidate = self.root / "Private Luma Candidate.png"
        black = bytes((0, 0, 0, 255))
        middle = bytes((128, 128, 128, 255))
        white = bytes((255, 255, 255, 255))
        write_png(reference, 10, 1, black * 2 + middle * 6 + white * 2)
        write_png(candidate, 10, 1, black + middle * 5 + white * 4)
        self.write_manifest(
            [
                {
                    "id": "mk8-luma-png",
                    "scene": "stable-race",
                    "reference": self.png_spec(reference, "mk8", "moltenvk"),
                    "candidate": self.png_spec(candidate, "mk8", "solmetal"),
                }
            ]
        )

        result = self.run_harness(
            "compare", "--manifest", str(self.manifest), "--output", str(self.output)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(self.output.read_text(encoding="utf-8"))
        luminance = report["comparisons"][0]["metrics"]["luminance"]
        self.assertEqual(luminance["quantizationSteps"], 4096)
        self.assertEqual(luminance["reference"]["p1"], 0)
        self.assertEqual(luminance["reference"]["p50"], 0.21582031)
        self.assertEqual(luminance["reference"]["p95"], 1)
        self.assertEqual(luminance["reference"]["p99"], 1)
        self.assertEqual(luminance["reference"]["clippedWhitePercent"], 20)
        self.assertEqual(luminance["candidate"]["clippedWhitePercent"], 40)
        self.assertEqual(luminance["reference"]["retainedBlackPercent"], 20)
        self.assertEqual(luminance["candidate"]["retainedBlackPercent"], 10)
        self.assertEqual(
            luminance["delta"]["clippedWhitePercentagePoints"], 20
        )
        self.assertEqual(
            luminance["delta"]["retainedBlackPercentagePoints"], -10
        )
        serialized = json.dumps(report)
        self.assertNotIn(str(self.root), serialized)
        self.assertNotIn(reference.name, serialized)
        self.assertNotIn(candidate.name, serialized)

    def test_raw_rgba8_reports_luminance_distribution_and_delta(self) -> None:
        reference = self.root / "Private Raw Reference.bin"
        candidate = self.root / "Private Raw Candidate.bin"
        black = bytes((0, 0, 0, 255))
        middle = bytes((128, 128, 128, 255))
        white = bytes((255, 255, 255, 255))
        reference.write_bytes(black * 2 + middle + white)
        candidate.write_bytes(black + middle + white * 2)

        def raw_spec(path: pathlib.Path, backend: str) -> dict:
            return {
                "title": "sm3dw",
                "backend": backend,
                "path": str(path),
                "format": "rgba8",
                "width": 4,
                "height": 1,
            }

        self.write_manifest(
            [
                {
                    "id": "sm3dw-luma-raw",
                    "scene": "level-entrance",
                    "reference": raw_spec(reference, "moltenvk"),
                    "candidate": raw_spec(candidate, "solmetal"),
                }
            ]
        )

        result = self.run_harness(
            "compare", "--manifest", str(self.manifest), "--output", str(self.output)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(self.output.read_text(encoding="utf-8"))
        comparison = report["comparisons"][0]
        luminance = comparison["metrics"]["luminance"]
        self.assertEqual(comparison["format"], "rgba8")
        self.assertEqual(luminance["reference"]["p50"], 0)
        self.assertEqual(luminance["candidate"]["p50"], 0.21582031)
        self.assertEqual(luminance["delta"]["p50"], 0.21582031)
        self.assertEqual(luminance["reference"]["clippedWhitePercent"], 25)
        self.assertEqual(luminance["candidate"]["clippedWhitePercent"], 50)
        self.assertEqual(luminance["reference"]["retainedBlackPercent"], 50)
        self.assertEqual(luminance["candidate"]["retainedBlackPercent"], 25)
        self.assertEqual(
            luminance["delta"]["clippedWhitePercentagePoints"], 25
        )
        self.assertEqual(
            luminance["delta"]["retainedBlackPercentagePoints"], -25
        )

    def test_same_title_guard_rejects_cross_title_pair(self) -> None:
        reference = self.root / "one.png"
        candidate = self.root / "two.png"
        pixels = bytes([0, 0, 0, 255] * 16)
        write_png(reference, 4, 4, pixels)
        write_png(candidate, 4, 4, pixels)
        self.write_manifest(
            [
                {
                    "id": "bad-pair",
                    "scene": "same-scene",
                    "reference": self.png_spec(reference, "totk", "moltenvk"),
                    "candidate": self.png_spec(candidate, "mk8", "solmetal"),
                }
            ]
        )
        result = self.run_harness("validate", "--manifest", str(self.manifest))
        self.assertEqual(result.returncode, 2)
        self.assertIn("different titles", result.stderr)
        self.assertNotIn(str(reference), result.stderr)

    def test_rg11b10_dump_is_compared_as_packed_hdr_pixels(self) -> None:
        width = 64
        height = 32
        reference = self.root / "reference.bin"
        candidate = self.root / "candidate.bin"
        packed_red = 0x000003C0
        packed_green = 0x001E0000
        baseline = bytearray(struct.pack("<I", packed_red) * (width * height))
        changed = bytearray(baseline)
        changed_pixel = 17 * width + 33
        struct.pack_into("<I", changed, changed_pixel * 4, packed_green)
        reference.write_bytes(baseline)
        candidate.write_bytes(changed)
        frame = lambda path, backend: {
            "title": "arceus",
            "backend": backend,
            "path": str(path),
            "format": "rg11b10float",
            "width": width,
            "height": height,
        }
        self.write_manifest(
            [
                {
                    "id": "arceus-hdr",
                    "scene": "field-checkpoint",
                    "reference": frame(reference, "moltenvk"),
                    "candidate": frame(candidate, "solmetal"),
                }
            ]
        )
        result = self.run_harness(
            "compare",
            "--strict",
            "--manifest",
            str(self.manifest),
            "--output",
            str(self.output),
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        comparison = json.loads(self.output.read_text(encoding="utf-8"))["comparisons"][0]
        self.assertEqual(comparison["format"], "rg11b10float")
        self.assertEqual(comparison["status"], "changed-unrated")
        self.assertEqual(comparison["metrics"]["exactMismatchPixels"], 1)
        self.assertEqual(
            comparison["metrics"]["differenceBounds"],
            {"x": 33, "y": 17, "width": 1, "height": 1},
        )

    def test_validate_rejects_manifest_with_public_permissions(self) -> None:
        self.write_manifest([])
        self.manifest.chmod(0o644)
        result = self.run_harness("validate", "--manifest", str(self.manifest))
        self.assertEqual(result.returncode, 2)
        self.assertIn("owner-only", result.stderr)


if __name__ == "__main__":
    unittest.main()
