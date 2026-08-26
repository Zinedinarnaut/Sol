#!/usr/bin/env python3
"""Offline integration tests for the SolMetal compatibility runner."""

import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
HARNESS = ROOT / "script" / "solmetal_compatibility.py"


class SolMetalCompatibilityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="solmetal-compat-test-")
        self.root = pathlib.Path(self.temporary.name)
        self.library = self.root / "private-library"
        self.data_directory = self.root / "private-data"
        self.library.mkdir()
        self.data_directory.mkdir()
        self.game = self.library / "Secret Local Game.xci"
        self.game.write_bytes(b"fixture")
        self.manifest = self.root / "suite.private.json"
        self.public_result = self.root / "public-results.json"
        self.solmetal_library = self.root / "SolMetal.dylib"
        self.solmetal_library.write_bytes(b"fixture")
        self.sol_app = self.root / "Sol.app"
        managed = self.sol_app / "Contents" / "Resources" / "SolEngineManaged"
        frameworks = self.sol_app / "Contents" / "Frameworks"
        hostfxr = (
            self.sol_app
            / "Contents"
            / "Resources"
            / "Dotnet"
            / "host"
            / "fxr"
            / "10.0.9"
        )
        managed.mkdir(parents=True)
        frameworks.mkdir(parents=True)
        hostfxr.mkdir(parents=True)
        (managed / "Sol.Engine.dll").write_bytes(b"fixture")
        (managed / "Sol.Engine.runtimeconfig.json").write_text(
            "{}", encoding="utf-8"
        )
        (frameworks / "SolMetal.dylib").write_bytes(b"fixture")
        (hostfxr / "libhostfxr.dylib").write_bytes(b"fixture")
        self.embedded_host = self.root / "fake-embedded-host"
        self.embedded_audit = self.root / "embedded-command.private.json"
        self.bin_directory = self.root / "bin"
        self.bin_directory.mkdir()
        self.write_executable(
            self.bin_directory / "pgrep",
            "#!/bin/sh\nexit 1\n",
        )
        self.environment = os.environ.copy()
        self.environment["PATH"] = str(self.bin_directory) + os.pathsep + self.environment["PATH"]
        self.environment["FAKE_EMBEDDED_AUDIT"] = str(self.embedded_audit)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_executable(self, path: pathlib.Path, contents: str) -> None:
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)

    def run_harness(self, *arguments: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(HARNESS), *arguments],
            cwd=str(ROOT),
            env=self.environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

    def discover(self) -> dict:
        result = self.run_harness(
            "discover",
            "--library",
            str(self.library),
            "--data-directory",
            str(self.data_directory),
            "--manifest",
            str(self.manifest),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(self.manifest.read_text(encoding="utf-8"))

    def write_fake_embedded_host(self) -> None:
        self.write_executable(
            self.embedded_host,
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import json
                import os
                import pathlib
                import signal
                import sys
                import time

                mode = os.environ.get("FAKE_EMBEDDED_MODE", "success")
                stopping = False
                if mode == "wait-for-signal":
                    def request_stop(signum, frame):
                        global stopping
                        stopping = True
                    signal.signal(signal.SIGINT, request_stop)
                game = os.environ.get("SOL_PRIVATE_GAME_PATH")
                data = os.environ.get("SOL_PRIVATE_DATA_PATH")
                audit = {
                    "arguments": sys.argv[1:],
                    "privateGame": game,
                    "privateData": data,
                    "ambientMetal": os.environ.get("SOL_METAL_GAL_BACKEND"),
                    "directMutationBatching": os.environ.get(
                        "SOL_METAL_DIRECT_MUTATION_BATCHING"
                    ),
                    "ambientBenchmark": os.environ.get("SOL_BENCHMARK_OUTPUT"),
                    "ambientDlsm": os.environ.get("SOL_DLSM_MODE"),
                }
                pathlib.Path(os.environ["FAKE_EMBEDDED_AUDIT"]).write_text(
                    json.dumps(audit), encoding="utf-8"
                )
                print("private game=" + str(game), file=sys.stderr, flush=True)
                print("private data=" + str(data), file=sys.stderr, flush=True)

                sequence = 0
                def emit(event, **fields):
                    global sequence
                    sequence += 1
                    fields.update({
                        "schemaVersion": 1,
                        "source": "solmetal-embedded-host",
                        "sequence": sequence,
                        "event": event,
                    })
                    print(json.dumps(fields, sort_keys=True), flush=True)

                emit("host.ready", developerOnly=True, requestedBackend="solmetal")
                emit("surface.ready", width=1280, height=720, pixelFormat="bgra8unorm")
                emit("engine.start", result=0)
                emit(
                    "engine.event",
                    managed={
                        "protocol": 1,
                        "event": "launch.progress",
                        "loadStage": "starting-solmetal-gal",
                    },
                )
                emit(
                    "engine.event",
                    managed={
                        "protocol": 1,
                        "event": "launch.first-frame",
                        "width": 1280,
                        "height": 720,
                    },
                )
                if mode == "wait-for-signal":
                    while not stopping:
                        time.sleep(0.01)
                emit(
                    "host.stop-requested",
                    reason="benchmark-complete",
                    commandAccepted=True,
                    shutdownAccepted=True,
                )
                emit(
                    "engine.event",
                    managed={
                        "protocol": 1,
                        "event": "embedded.terminated",
                        "exitCode": 0,
                    },
                )
                emit(
                    "backend.attestation",
                    requestedBackend="solmetal",
                    observedBackend="solmetal",
                    status="attested",
                    engineLaunchStage=True,
                    benchmarkReport=True,
                )
                emit(
                    "benchmark.result",
                    backend="MoltenVK" if mode == "mislabeled" else "solmetal",
                    completed=True,
                    configuredWarmupSeconds=0,
                    configuredDurationSeconds=5,
                    measuredSeconds=5.01,
                    presentedFrames=301,
                    presentedFramesPerSecond=60.0,
                    presentFrameTimeMilliseconds={
                        "samples": 300,
                        "median": 16.67,
                        "p95": 17.0,
                    },
                )
                emit(
                    "host.finished",
                    status="passed",
                    engineExitCode=0,
                    firstFrame=True,
                    benchmarkCompleted=True,
                    backendAttested=True,
                    gracefulStop=True,
                )
                """
            ),
        )

    def test_discover_writes_private_manifest_without_printing_paths(self) -> None:
        manifest = self.discover()
        self.assertEqual(len(manifest["games"]), 1)
        self.assertEqual(manifest["games"][0]["privateName"], "Secret Local Game")
        self.assertEqual(stat.S_IMODE(self.manifest.stat().st_mode), 0o600)
        command_output = self.run_harness(
            "validate", "--manifest", str(self.manifest)
        )
        self.assertEqual(command_output.returncode, 0, command_output.stderr)
        self.assertNotIn(str(self.game), command_output.stdout)
        self.assertNotIn("Secret Local Game", command_output.stdout)

    def test_dry_run_is_redacted_and_requires_execute(self) -> None:
        manifest = self.discover()
        identifier = manifest["games"][0]["id"]
        result = self.run_harness(
            "run",
            "--manifest",
            str(self.manifest),
            "--only",
            identifier,
            "--backend",
            "both",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertTrue(plan["executeRequired"])
        self.assertFalse(plan["allCasesExecutable"])
        self.assertEqual(len(plan["cases"]), 2)
        solmetal_case = next(
            case for case in plan["cases"] if case["backend"] == "solmetal"
        )
        self.assertFalse(solmetal_case["executionSupported"])
        self.assertFalse(solmetal_case["directMutationBatching"])
        self.assertTrue(solmetal_case["requiresEmbeddedMetalSurface"])
        self.assertNotIn(str(self.game), result.stdout)
        self.assertNotIn("Secret Local Game", result.stdout)

    def test_repeated_only_runs_in_user_supplied_order(self) -> None:
        alpha = self.library / "Alpha Private Game.nsp"
        zulu = self.library / "Zulu Private Game.xci"
        alpha.write_bytes(b"alpha")
        zulu.write_bytes(b"zulu")
        manifest = self.discover()
        identifiers = {
            game["privateName"]: game["id"] for game in manifest["games"]
        }
        expected = [
            identifiers["Zulu Private Game"],
            identifiers["Alpha Private Game"],
            identifiers["Secret Local Game"],
        ]

        result = self.run_harness(
            "run",
            "--manifest",
            str(self.manifest),
            "--only",
            expected[0],
            "--only",
            expected[1],
            "--only",
            expected[2],
            "--backend",
            "moltenvk",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual(plan["games"], 3)
        self.assertEqual([case["game"] for case in plan["cases"]], expected)
        for private_path in (self.game, alpha, zulu):
            self.assertNotIn(str(private_path), result.stdout)
            self.assertNotIn(private_path.stem, result.stdout)

    def test_repeated_only_ignores_duplicate_ids_after_first_occurrence(self) -> None:
        alpha = self.library / "Alpha Private Game.nsp"
        alpha.write_bytes(b"alpha")
        manifest = self.discover()
        identifiers = {
            game["privateName"]: game["id"] for game in manifest["games"]
        }
        secret_id = identifiers["Secret Local Game"]
        alpha_id = identifiers["Alpha Private Game"]

        result = self.run_harness(
            "run",
            "--manifest",
            str(self.manifest),
            "--only",
            secret_id,
            "--only",
            alpha_id,
            "--only",
            secret_id,
            "--only",
            alpha_id,
            "--backend",
            "moltenvk",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual(plan["games"], 2)
        self.assertEqual(
            [case["game"] for case in plan["cases"]],
            [secret_id, alpha_id],
        )

    def test_repeated_only_rejects_a_missing_id_before_planning(self) -> None:
        manifest = self.discover()
        identifier = manifest["games"][0]["id"]

        result = self.run_harness(
            "run",
            "--manifest",
            str(self.manifest),
            "--only",
            identifier,
            "--only",
            "game-missing",
            "--backend",
            "moltenvk",
        )

        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("Unknown game id: game-missing", result.stderr)
        self.assertNotIn(str(self.game), result.stderr)
        self.assertNotIn("Secret Local Game", result.stderr)

    def test_only_rejects_a_path_without_disclosing_it(self) -> None:
        self.discover()

        result = self.run_harness(
            "run",
            "--manifest",
            str(self.manifest),
            "--only",
            str(self.game),
            "--backend",
            "moltenvk",
        )

        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("A selected game id is invalid.", result.stderr)
        self.assertNotIn(str(self.game), result.stderr)
        self.assertNotIn("Secret Local Game", result.stderr)

    def test_successful_fake_engine_produces_path_free_structured_result(self) -> None:
        manifest = self.discover()
        identifier = manifest["games"][0]["id"]
        engine = self.root / "fake-engine"
        self.write_executable(
            engine,
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import json
                import os
                import pathlib
                import sys
                import time

                prefix = "@@SOL_ENGINE@@"
                hypervisor_index = sys.argv.index("--use-hypervisor")
                if sys.argv[hypervisor_index + 1] != "false":
                    sys.exit(9)
                def event(value):
                    print(prefix + json.dumps(value), flush=True)

                event({"protocol": 1, "event": "host.ready"})
                event({"protocol": 1, "event": "session.state", "phase": "launching"})
                event({"protocol": 1, "event": "launch.progress", "loadStage": "loading-configuration"})
                print("Application Loaded: private title from " + sys.argv[-1], flush=True)
                print("00:00:00.527 |E| .NET TP Worker [mvk-info] MoltenVK version 1.4.2", flush=True)
                print("00:00:00.527 |E| .NET TP Worker                 VK_KHR_surface v25", flush=True)
                print("00:00:00.528 |E| .NET TP Worker [mvk-warn] Routine portability notice", flush=True)
                print("00:00:00.529 |I| Gpu PrintGpuInformation: Fixture Apple GPU (Vulkan v1.2.0)", flush=True)
                time.sleep(0.2)
                report = {
                    "schemaVersion": 1,
                    "label": os.environ["SOL_BENCHMARK_LABEL"],
                    "backend": "MoltenVK",
                    "rendererName": "Fixture Apple GPU",
                    "startedAtUtc": "2026-01-01T00:00:00Z",
                    "completed": True,
                    "configuredWarmupSeconds": 0,
                    "configuredDurationSeconds": 5,
                    "measuredSeconds": 5.1,
                    "presentedFrames": 306,
                    "presentedFramesPerSecond": 60.0,
                    "sourceFramesPerSecond": {"samples": 3, "mean": 60.0, "median": 60.0, "p95": 60.0, "p99": 60.0, "minimum": 60.0, "maximum": 60.0},
                    "presentFrameTimeMilliseconds": {"samples": 305, "mean": 16.67, "median": 16.67, "p95": 17.1, "p99": 18.0, "minimum": 16.0, "maximum": 20.0},
                    "fifoPercent": {"samples": 3, "mean": 50.0, "median": 50.0, "p95": 55.0, "p99": 56.0, "minimum": 45.0, "maximum": 57.0},
                    "processCpuPercent": {"samples": 3, "mean": 80.0, "median": 80.0, "p95": 85.0, "p99": 86.0, "minimum": 75.0, "maximum": 87.0},
                    "workingSetBytes": {"samples": 3, "median": 500000000, "p95": 510000000, "minimum": 490000000, "maximum": 520000000}
                }
                pathlib.Path(os.environ["SOL_BENCHMARK_OUTPUT"]).write_text(json.dumps(report), encoding="utf-8")
                sys.stdin.readline()
                sys.exit(0)
                """
            ),
        )
        result = self.run_harness(
            "run",
            "--execute",
            "--manifest",
            str(self.manifest),
            "--engine",
            str(engine),
            "--solmetal-library",
            str(self.solmetal_library),
            "--output",
            str(self.public_result),
            "--only",
            identifier,
            "--backend",
            "moltenvk",
            "--first-frame-timeout",
            "2",
            "--case-timeout",
            "3",
            "--stop-timeout",
            "1",
            "--cooldown",
            "0",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(self.public_result.read_text(encoding="utf-8"))
        case = report["cases"][0]
        self.assertEqual(case["status"], "passed")
        self.assertEqual(case["requestedBackend"], "moltenvk")
        self.assertEqual(case["backend"], "moltenvk")
        self.assertEqual(case["backendAttestation"]["status"], "attested")
        self.assertEqual(
            case["milestones"]["firstFrameEvidence"], "completed-benchmark"
        )
        self.assertNotIn("firstFrameSeconds", case["milestones"])
        self.assertEqual(case["diagnostics"]["engineErrorLines"], 0)
        self.assertEqual(case["diagnostics"]["moltenvkInfoLines"], 1)
        self.assertEqual(case["diagnostics"]["moltenvkWarningLines"], 1)
        self.assertEqual(case["diagnostics"]["moltenvkContinuationLines"], 1)
        self.assertEqual(case["benchmark"]["presentedFramesPerSecond"], 60.0)
        serialized = json.dumps(report)
        self.assertNotIn(str(self.game), serialized)
        self.assertNotIn(str(self.data_directory), serialized)
        self.assertNotIn("Secret Local Game", serialized)
        private_logs = list((self.manifest.parent / "runs").glob("*/engine.raw.log"))
        self.assertEqual(len(private_logs), 1)
        self.assertIn(str(self.game), private_logs[0].read_text(encoding="utf-8"))
        self.assertEqual(stat.S_IMODE(private_logs[0].stat().st_mode), 0o600)

    def test_first_frame_timeout_stops_only_owned_child_and_reports_failure(self) -> None:
        manifest = self.discover()
        identifier = manifest["games"][0]["id"]
        engine = self.root / "timeout-engine"
        self.write_executable(
            engine,
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import json
                import sys
                print("@@SOL_ENGINE@@" + json.dumps({"protocol": 1, "event": "host.ready"}), flush=True)
                command = sys.stdin.readline()
                sys.exit(0 if '"stop"' in command else 3)
                """
            ),
        )
        result = self.run_harness(
            "run",
            "--execute",
            "--manifest",
            str(self.manifest),
            "--engine",
            str(engine),
            "--solmetal-library",
            str(self.solmetal_library),
            "--output",
            str(self.public_result),
            "--only",
            identifier,
            "--first-frame-timeout",
            "0.2",
            "--case-timeout",
            "1",
            "--stop-timeout",
            "0.5",
            "--cooldown",
            "0",
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        case = json.loads(self.public_result.read_text(encoding="utf-8"))["cases"][0]
        self.assertEqual(case["status"], "failed")
        self.assertEqual(case["timeout"], "first-frame")
        self.assertTrue(case["gracefulStop"])
        self.assertFalse(case["forcedTermination"])

    def test_solmetal_execute_fails_before_engine_launch(self) -> None:
        manifest = self.discover()
        identifier = manifest["games"][0]["id"]
        sentinel = self.root / "engine-launched"
        engine = self.root / "must-not-run-engine"
        self.write_executable(
            engine,
            "#!/bin/sh\ntouch %s\n" % sentinel,
        )
        result = self.run_harness(
            "run",
            "--execute",
            "--manifest",
            str(self.manifest),
            "--engine",
            str(engine),
            "--output",
            str(self.public_result),
            "--only",
            identifier,
            "--backend",
            "solmetal",
            "--cooldown",
            "0",
        )
        self.assertEqual(result.returncode, 2)
        self.assertFalse(sentinel.exists())
        self.assertFalse(self.public_result.exists())
        self.assertIn("embedded AppKit host", result.stderr)
        self.assertNotIn(str(self.game), result.stderr)
        self.assertNotIn("Secret Local Game", result.stderr)

    def test_direct_mutation_batching_requires_embedded_solmetal(self) -> None:
        manifest = self.discover()
        identifier = manifest["games"][0]["id"]
        result = self.run_harness(
            "run",
            "--execute",
            "--manifest",
            str(self.manifest),
            "--output",
            str(self.public_result),
            "--only",
            identifier,
            "--backend",
            "moltenvk",
            "--solmetal-direct-mutation-batching",
            "--cooldown",
            "0",
        )
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.public_result.exists())
        self.assertIn("requires an embedded SolMetal run", result.stderr)
        self.assertNotIn(str(self.game), result.stderr)
        self.assertNotIn("Secret Local Game", result.stderr)

    def test_explicit_embedded_solmetal_builds_private_command_and_attests(self) -> None:
        manifest = self.discover()
        identifier = manifest["games"][0]["id"]
        self.write_fake_embedded_host()
        self.environment["FAKE_EMBEDDED_MODE"] = "success"
        self.environment["SOL_METAL_GAL_BACKEND"] = "ambient-contamination"
        self.environment["SOL_METAL_DIRECT_MUTATION_BATCHING"] = (
            "ambient-contamination"
        )
        self.environment["SOL_BENCHMARK_OUTPUT"] = "/private/ambient-benchmark"
        self.environment["SOL_DLSM_MODE"] = "temporal"

        result = self.run_harness(
            "run",
            "--execute",
            "--manifest",
            str(self.manifest),
            "--output",
            str(self.public_result),
            "--only",
            identifier,
            "--backend",
            "solmetal",
            "--embedded-solmetal",
            "--solmetal-direct-mutation-batching",
            "--embedded-host",
            str(self.embedded_host),
            "--sol-app",
            str(self.sol_app),
            "--warmup",
            "0",
            "--duration",
            "5",
            "--first-frame-timeout",
            "2",
            "--case-timeout",
            "3",
            "--stop-timeout",
            "1",
            "--cooldown",
            "0",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(self.public_result.read_text(encoding="utf-8"))
        case = report["cases"][0]
        self.assertEqual(case["executionMode"], "embedded-appkit")
        self.assertEqual(case["requestedBackend"], "solmetal")
        self.assertEqual(case["backend"], "solmetal")
        self.assertEqual(case["backendAttestation"]["status"], "attested")
        self.assertEqual(
            case["backendAttestation"]["evidence"],
            ["embedded-launch-event", "benchmark-report"],
        )
        self.assertEqual(
            case["backendAttestation"]["embeddedHost"]["status"], "attested"
        )
        self.assertEqual(case["status"], "passed")
        self.assertTrue(case["gracefulStop"])
        self.assertTrue(case["stopRequestSent"])
        self.assertTrue(case["sessionStopAcknowledged"], case)
        self.assertFalse(case["forcedTermination"])
        self.assertEqual(case["hostTeardown"], "natural-exit")
        self.assertEqual(report["scope"]["executionModes"], ["embedded-appkit"])
        self.assertFalse(report["scope"]["standaloneEngine"])
        self.assertTrue(report["scope"]["solmetalDirectMutationBatching"])
        self.assertTrue(case["experiments"]["directMutationBatching"])

        audit = json.loads(self.embedded_audit.read_text(encoding="utf-8"))
        self.assertEqual(audit["privateGame"], str(self.game.resolve()))
        self.assertEqual(audit["privateData"], str(self.data_directory.resolve()))
        self.assertIsNone(audit["ambientMetal"])
        self.assertEqual(audit["directMutationBatching"], "1")
        self.assertIsNone(audit["ambientBenchmark"])
        self.assertIsNone(audit["ambientDlsm"])
        self.assertNotIn(str(self.game), audit["arguments"])
        self.assertNotIn(str(self.data_directory), audit["arguments"])
        self.assertEqual(
            audit["arguments"],
            [
                "--app",
                str(self.sol_app.resolve()),
                "--warmup",
                "0.0",
                "--duration",
                "5.0",
                "--first-frame-timeout",
                "2.0",
                "--stop-timeout",
                "1.0",
            ],
        )

        serialized = json.dumps(report)
        self.assertNotIn(str(self.game), serialized)
        self.assertNotIn(str(self.data_directory), serialized)
        self.assertNotIn("Secret Local Game", serialized)
        raw_logs = list(
            (self.manifest.parent / "runs").glob("*/embedded-host.raw.log")
        )
        self.assertEqual(len(raw_logs), 1)
        self.assertIn(str(self.game), raw_logs[0].read_text(encoding="utf-8"))
        self.assertEqual(stat.S_IMODE(raw_logs[0].stat().st_mode), 0o600)

    def test_embedded_host_cannot_mislabel_moltenvk_as_solmetal(self) -> None:
        manifest = self.discover()
        identifier = manifest["games"][0]["id"]
        self.write_fake_embedded_host()
        self.environment["FAKE_EMBEDDED_MODE"] = "mislabeled"

        result = self.run_harness(
            "run",
            "--execute",
            "--manifest",
            str(self.manifest),
            "--output",
            str(self.public_result),
            "--only",
            identifier,
            "--backend",
            "solmetal",
            "--embedded-solmetal",
            "--embedded-host",
            str(self.embedded_host),
            "--sol-app",
            str(self.sol_app),
            "--warmup",
            "0",
            "--duration",
            "5",
            "--first-frame-timeout",
            "2",
            "--case-timeout",
            "3",
            "--stop-timeout",
            "1",
            "--cooldown",
            "0",
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        case = json.loads(self.public_result.read_text(encoding="utf-8"))["cases"][0]
        self.assertEqual(case["status"], "failed")
        self.assertEqual(case["backendAttestation"]["status"], "conflict")
        self.assertEqual(case["backendAttestation"]["observedBackend"], "solmetal")
        self.assertEqual(case["backendAttestation"]["benchmarkBackend"], "moltenvk")
        self.assertEqual(case["benchmark"]["backend"], "moltenvk")

    def test_embedded_case_timeout_requests_graceful_host_shutdown(self) -> None:
        manifest = self.discover()
        identifier = manifest["games"][0]["id"]
        self.write_fake_embedded_host()
        self.environment["FAKE_EMBEDDED_MODE"] = "wait-for-signal"

        result = self.run_harness(
            "run",
            "--execute",
            "--manifest",
            str(self.manifest),
            "--output",
            str(self.public_result),
            "--only",
            identifier,
            "--backend",
            "solmetal",
            "--embedded-solmetal",
            "--embedded-host",
            str(self.embedded_host),
            "--sol-app",
            str(self.sol_app),
            "--warmup",
            "0",
            "--duration",
            "5",
            "--first-frame-timeout",
            "2",
            "--case-timeout",
            "1",
            "--stop-timeout",
            "2",
            "--cooldown",
            "0",
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        case = json.loads(self.public_result.read_text(encoding="utf-8"))["cases"][0]
        self.assertEqual(case["status"], "failed")
        self.assertEqual(case["timeout"], "case")
        self.assertTrue(case["stopRequestSent"])
        self.assertTrue(case["sessionStopAcknowledged"], case)
        self.assertTrue(case["gracefulStop"])
        self.assertFalse(case["forcedTermination"])
        self.assertEqual(case["hostTeardown"], "natural-exit")

    def test_backend_attestation_mismatch_fails_closed(self) -> None:
        manifest = self.discover()
        identifier = manifest["games"][0]["id"]
        engine = self.root / "mismatch-engine"
        self.write_executable(
            engine,
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import json
                import os
                import pathlib
                import sys

                print("SolMetal accepted its first native guest draw.", flush=True)
                report = {
                    "schemaVersion": 1,
                    "backend": "MoltenVK",
                    "rendererName": "Fixture Apple GPU",
                    "completed": True,
                    "measuredSeconds": 1.0,
                    "presentedFrames": 30,
                    "presentedFramesPerSecond": 30.0
                }
                pathlib.Path(os.environ["SOL_BENCHMARK_OUTPUT"]).write_text(json.dumps(report), encoding="utf-8")
                command = sys.stdin.readline()
                sys.exit(0 if '"stop"' in command else 3)
                """
            ),
        )
        result = self.run_harness(
            "run",
            "--execute",
            "--manifest",
            str(self.manifest),
            "--engine",
            str(engine),
            "--output",
            str(self.public_result),
            "--only",
            identifier,
            "--backend",
            "moltenvk",
            "--first-frame-timeout",
            "2",
            "--case-timeout",
            "3",
            "--stop-timeout",
            "1",
            "--cooldown",
            "0",
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        case = json.loads(self.public_result.read_text(encoding="utf-8"))["cases"][0]
        self.assertEqual(case["status"], "failed")
        self.assertEqual(case["requestedBackend"], "moltenvk")
        self.assertEqual(case["backend"], "solmetal")
        self.assertEqual(case["backendAttestation"]["status"], "conflict")

    def test_idle_acknowledgement_is_graceful_for_persistent_host(self) -> None:
        manifest = self.discover()
        identifier = manifest["games"][0]["id"]
        engine = self.root / "persistent-engine"
        self.write_executable(
            engine,
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import json
                import os
                import pathlib
                import sys
                import time

                prefix = "@@SOL_ENGINE@@"
                print("00:00:00.527 |E| .NET TP Worker [mvk-info] MoltenVK version 1.4.2", flush=True)
                report = {
                    "schemaVersion": 1,
                    "backend": "MoltenVK",
                    "rendererName": "Fixture Apple GPU",
                    "completed": True,
                    "measuredSeconds": 1.0,
                    "presentedFrames": 30,
                    "presentedFramesPerSecond": 30.0
                }
                pathlib.Path(os.environ["SOL_BENCHMARK_OUTPUT"]).write_text(json.dumps(report), encoding="utf-8")
                command = sys.stdin.readline()
                if '"stop"' not in command:
                    sys.exit(3)
                print(prefix + json.dumps({"protocol": 1, "event": "session.state", "phase": "idle"}), flush=True)
                print("00:00:01.000 |E| SurfaceFlinger Post-stop cleanup diagnostic", flush=True)
                while True:
                    time.sleep(1)
                """
            ),
        )
        result = self.run_harness(
            "run",
            "--execute",
            "--manifest",
            str(self.manifest),
            "--engine",
            str(engine),
            "--output",
            str(self.public_result),
            "--only",
            identifier,
            "--backend",
            "moltenvk",
            "--first-frame-timeout",
            "2",
            "--case-timeout",
            "3",
            "--stop-timeout",
            "1",
            "--cooldown",
            "0",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        case = json.loads(self.public_result.read_text(encoding="utf-8"))["cases"][0]
        self.assertEqual(case["status"], "passed")
        self.assertTrue(case["gracefulStop"])
        self.assertTrue(case["sessionStopAcknowledged"])
        self.assertFalse(case["forcedTermination"])
        self.assertEqual(case["hostTeardown"], "terminate-after-session-idle")
        self.assertEqual(case["diagnostics"]["engineErrorLines"], 0)
        self.assertEqual(case["diagnostics"]["shutdownErrorLines"], 1)


if __name__ == "__main__":
    unittest.main()
