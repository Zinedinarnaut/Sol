#!/usr/bin/env python3
"""Offline lifecycle and privacy smoke tests for the embedded SolMetal host."""

import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD = ROOT / "script" / "build_solmetal_compatibility_host.sh"
SOURCE = ROOT / "NativeHost" / "SolMetalCompatibilityHost" / "FakeEmbeddedABI.c"
DEFAULT_APP = pathlib.Path("/tmp/sol-derived-data/Build/Products/Debug/Sol.app")


class EmbeddedHostTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="solmetal-embedded-host-")
        self.root = pathlib.Path(self.temporary.name)
        self.host = self.root / "SolMetalCompatibilityHost"
        self.fake_runtime = self.root / "FakeEmbeddedABI.dylib"
        self.game = self.root / "TOP SECRET GAME.xci"
        self.data_directory = self.root / "TOP SECRET DATA"
        self.game.write_bytes(b"fixture")
        self.data_directory.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_checked(self, command: list[str], **kwargs) -> subprocess.CompletedProcess:
        result = subprocess.run(
            command,
            cwd=str(ROOT),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            **kwargs,
        )
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
        return result

    def build_testing_host(self) -> None:
        self.run_checked([str(BUILD), "--testing", "--output", str(self.host)])
        self.run_checked(
            [
                "xcrun",
                "clang",
                "-dynamiclib",
                "-O2",
                "-mmacosx-version-min=15.0",
                str(SOURCE),
                "-o",
                str(self.fake_runtime),
            ]
        )

    def test_fake_runtime_calls_full_abi_and_keeps_paths_private(self) -> None:
        self.build_testing_host()
        environment = os.environ.copy()
        environment["SOL_PRIVATE_GAME_PATH"] = str(self.game)
        environment["SOL_PRIVATE_DATA_PATH"] = str(self.data_directory)
        ambient_benchmark = self.root / "ambient-benchmark-must-not-be-used.json"
        environment["SOL_METAL_GAL_BACKEND"] = "ambient-wrong-backend"
        environment["SOL_BENCHMARK_OUTPUT"] = str(ambient_benchmark)
        environment["SOL_BENCHMARK_LABEL"] = "ambient-wrong-label"
        environment["SOL_BENCHMARK_WARMUP_SECONDS"] = "999"
        environment["SOL_BENCHMARK_DURATION_SECONDS"] = "999"
        result = subprocess.run(
            [
                str(self.host),
                "--test-runtime",
                str(self.fake_runtime),
                "--hidden",
                "--warmup",
                "0",
                "--duration",
                "5",
                "--first-frame-timeout",
                "2",
                "--stop-timeout",
                "2",
            ],
            cwd=str(ROOT),
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
        self.assertEqual(result.stderr, "")
        self.assertNotIn(str(self.game), result.stdout)
        self.assertNotIn(str(self.data_directory), result.stdout)
        self.assertNotIn("TOP SECRET", result.stdout)
        self.assertNotIn("/private/", result.stdout)
        self.assertNotIn(str(ambient_benchmark), result.stdout)
        self.assertFalse(ambient_benchmark.exists())

        events = [json.loads(line) for line in result.stdout.splitlines() if line]
        names = [event["event"] for event in events]
        self.assertIn("host.ready", names)
        self.assertIn("surface.ready", names)
        self.assertIn("engine.start", names)
        self.assertIn("host.stop-requested", names)
        self.assertIn("backend.attestation", names)
        self.assertIn("benchmark.result", names)
        self.assertEqual(names[-1], "host.finished")

        attestation = next(
            event for event in events if event["event"] == "backend.attestation"
        )
        self.assertEqual(attestation["status"], "attested")
        self.assertEqual(attestation["observedBackend"], "solmetal")
        self.assertEqual(events[-1]["status"], "passed")
        self.assertTrue(events[-1]["gracefulStop"])

        logs = list(
            self.data_directory.glob(
                "Developer/SolMetalCompatibility/Run-*/engine.raw.log"
            )
        )
        self.assertEqual(len(logs), 1)
        raw_log = logs[0].read_text(encoding="utf-8")
        self.assertIn(str(self.game), raw_log)
        self.assertIn(str(self.data_directory), raw_log)
        self.assertEqual(stat.S_IMODE(logs[0].stat().st_mode), 0o600)

    @unittest.skipUnless(DEFAULT_APP.is_dir(), "built Sol.app is unavailable")
    def test_built_app_runtime_resolves_without_starting_a_game(self) -> None:
        normal_host = self.root / "SolMetalCompatibilityHost-normal"
        self.run_checked([str(BUILD), "--output", str(normal_host)])
        result = subprocess.run(
            [
                str(normal_host),
                "--runtime-smoke",
                "--app",
                str(DEFAULT_APP),
                "--hidden",
            ],
            cwd=str(ROOT),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
        self.assertEqual(result.stderr, "")
        self.assertNotIn(str(DEFAULT_APP), result.stdout)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["event"], "runtime.smoke")
        self.assertEqual(payload["status"], "passed")
        self.assertEqual(
            payload["managedABI"],
            ["Start", "Pump", "ReadEvent", "SendCommand", "Shutdown"],
        )
        self.assertFalse(payload["pathsDisclosed"])


if __name__ == "__main__":
    unittest.main()
