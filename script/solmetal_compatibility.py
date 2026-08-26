#!/usr/bin/env python3
"""Privacy-conscious, opt-in Sol Engine compatibility and pacing runner.

The private manifest contains game and Sol data paths. Public result files are
built from an allowlist and are rejected if a local path or private title leaks.
Games are always launched one at a time and only a process started by this
runner may be stopped.
"""

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import pathlib
import queue
import re
import secrets
import signal
import shutil
import subprocess
import sys
import threading
import time
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple


SCHEMA_VERSION = 1
RUNNER_VERSION = "3"
PROTOCOL_PREFIX = "@@SOL_ENGINE@@"
SUPPORTED_GAME_SUFFIXES = {".xci", ".nsp", ".nca", ".pfs0", ".nro"}
SAFE_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
ROOT_DIR = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_ENGINE = ROOT_DIR / "NativeHost" / "artifacts" / "engine" / "Sol.Engine"
DEFAULT_SOLMETAL_LIBRARY = (
    ROOT_DIR / "NativeHost" / "artifacts" / "sol-metal" / "SolMetal.dylib"
)
DEFAULT_EMBEDDED_HOST = (
    ROOT_DIR
    / "NativeHost"
    / "artifacts"
    / "compatibility-host"
    / "SolMetalCompatibilityHost"
)
DEFAULT_SOL_APP = pathlib.Path(
    "/tmp/sol-derived-data/Build/Products/Debug/Sol.app"
)
DEFAULT_PRIVATE_ROOT = (
    pathlib.Path.home()
    / "Library"
    / "Application Support"
    / "Sol"
    / "Developer"
    / "SolMetalCompatibility"
)
DEFAULT_MANIFEST = DEFAULT_PRIVATE_ROOT / "suite.private.json"
DEFAULT_DATA_DIRECTORY = pathlib.Path.home() / "Library" / "Application Support" / "Sol"


class HarnessError(RuntimeError):
    pass


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


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
    parent_existed = path.parent.exists()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700 if private else 0o755)
    if private and not parent_existed:
        os.chmod(str(path.parent), 0o700)
    temporary = path.with_name(path.name + ".tmp-" + secrets.token_hex(4))
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    descriptor = os.open(str(temporary), flags, 0o600 if private else 0o644)
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
    except (OSError, json.JSONDecodeError) as error:
        raise HarnessError("Could not read the private manifest: %s" % error) from error


def configured_sol_library() -> Optional[pathlib.Path]:
    defaults = shutil.which("defaults")
    if not defaults:
        return None
    result = subprocess.run(
        [defaults, "read", "com.solemu.app", "gamesDirectory"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return None
    return pathlib.Path(result.stdout.strip()).expanduser()


def discover_candidates(library: pathlib.Path) -> List[Dict[str, Any]]:
    candidates: List[Dict[str, Any]] = []
    for directory, subdirectories, files in os.walk(str(library), followlinks=False):
        subdirectories[:] = sorted(subdirectories)
        for filename in sorted(files):
            path = pathlib.Path(directory) / filename
            suffix = path.suffix.lower()
            if suffix not in SUPPORTED_GAME_SUFFIXES or path.is_symlink():
                continue
            try:
                stat = path.stat()
            except OSError:
                continue
            if not path.is_file():
                continue
            candidates.append(
                {
                    "path": str(path.resolve()),
                    "privateName": path.stem,
                    "fileType": suffix[1:],
                    "sizeBytes": stat.st_size,
                }
            )
    candidates.sort(key=lambda item: (item["privateName"].casefold(), item["path"]))
    return candidates


def command_discover(args: argparse.Namespace) -> int:
    manifest_path = pathlib.Path(args.manifest).expanduser()
    require_private_location(manifest_path, "The private manifest")
    library = pathlib.Path(args.library).expanduser() if args.library else configured_sol_library()
    if library is None or not library.is_dir():
        raise HarnessError(
            "Sol has no readable library selection. Pass --library to a private local folder."
        )
    data_directory = pathlib.Path(args.data_directory).expanduser()
    if not data_directory.is_dir():
        raise HarnessError("The selected Sol data directory is unavailable.")

    existing_by_path: Dict[str, Dict[str, Any]] = {}
    salt = secrets.token_hex(16)
    if manifest_path.exists():
        existing = read_json(manifest_path)
        if isinstance(existing, dict):
            salt = str(existing.get("privateSalt") or salt)
            for game in existing.get("games", []):
                if isinstance(game, dict) and isinstance(game.get("path"), str):
                    existing_by_path[game["path"]] = game

    games: List[Dict[str, Any]] = []
    used_ids = set()
    for candidate in discover_candidates(library):
        previous = existing_by_path.get(candidate["path"], {})
        identifier = previous.get("id")
        if not isinstance(identifier, str) or not SAFE_ID.fullmatch(identifier):
            digest = hashlib.sha256(
                (salt + "\0" + candidate["path"]).encode("utf-8")
            ).hexdigest()
            identifier = "game-" + digest[:10]
        suffix = 2
        base_identifier = identifier
        while identifier in used_ids:
            identifier = "%s-%d" % (base_identifier, suffix)
            suffix += 1
        used_ids.add(identifier)
        games.append(
            {
                "id": identifier,
                "enabled": bool(previous.get("enabled", True)),
                "publicLabel": previous.get("publicLabel"),
                "privateName": candidate["privateName"],
                "path": candidate["path"],
                "fileType": candidate["fileType"],
                "sizeBytes": candidate["sizeBytes"],
                "warmupSeconds": previous.get("warmupSeconds", 20),
                "durationSeconds": previous.get("durationSeconds", 30),
            }
        )

    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "private": True,
        "privateSalt": salt,
        "dataDirectory": str(data_directory.resolve()),
        "games": games,
    }
    write_json_atomic(manifest_path, manifest, private=True)
    print(
        json.dumps(
            {
                "candidates": len(games),
                "manifestWritten": True,
                "pathsDisclosed": False,
            },
            sort_keys=True,
        )
    )
    return 0


def number_in_range(value: Any, field: str, minimum: float, maximum: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise HarnessError("%s must be numeric." % field)
    result = float(value)
    if not minimum <= result <= maximum:
        raise HarnessError("%s must be between %s and %s." % (field, minimum, maximum))
    return result


def load_manifest(path: pathlib.Path) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
    require_private_location(path, "The private manifest")
    manifest = read_json(path)
    if not isinstance(manifest, dict) or manifest.get("schemaVersion") != SCHEMA_VERSION:
        raise HarnessError("The private manifest has an unsupported schema version.")
    data_directory_raw = manifest.get("dataDirectory")
    games_raw = manifest.get("games")
    if not isinstance(data_directory_raw, str) or not isinstance(games_raw, list):
        raise HarnessError("The private manifest is missing required fields.")
    data_directory = pathlib.Path(data_directory_raw).expanduser()
    if not data_directory.is_dir():
        raise HarnessError("The private Sol data directory is unavailable.")

    validated: List[Dict[str, Any]] = []
    identifiers = set()
    for index, raw in enumerate(games_raw):
        if not isinstance(raw, dict):
            raise HarnessError("Game entry %d is not an object." % (index + 1))
        identifier = raw.get("id")
        if not isinstance(identifier, str) or not SAFE_ID.fullmatch(identifier):
            raise HarnessError("Game entry %d has an unsafe id." % (index + 1))
        if identifier in identifiers:
            raise HarnessError("The private manifest repeats game id %s." % identifier)
        identifiers.add(identifier)
        game_path_raw = raw.get("path")
        if not isinstance(game_path_raw, str):
            raise HarnessError("Game %s has no private path." % identifier)
        game_path = pathlib.Path(game_path_raw).expanduser()
        if not game_path.is_file():
            raise HarnessError("The private path for %s is unavailable." % identifier)
        if game_path.suffix.lower() not in SUPPORTED_GAME_SUFFIXES:
            raise HarnessError("Game %s has an unsupported file type." % identifier)
        public_label = raw.get("publicLabel")
        if public_label is not None:
            if not isinstance(public_label, str) or not public_label.strip():
                raise HarnessError("Game %s has an invalid public label." % identifier)
            if len(public_label) > 80 or any(char in public_label for char in "\r\n/\\"):
                raise HarnessError("Game %s has an unsafe public label." % identifier)
            public_label = public_label.strip()
        validated.append(
            {
                "id": identifier,
                "enabled": bool(raw.get("enabled", True)),
                "publicLabel": public_label,
                "privateName": str(raw.get("privateName") or ""),
                "path": game_path.resolve(),
                "fileType": game_path.suffix.lower()[1:],
                "sizeBytes": game_path.stat().st_size,
                "warmupSeconds": number_in_range(
                    raw.get("warmupSeconds", 20),
                    "%s warmupSeconds" % identifier,
                    0,
                    600,
                ),
                "durationSeconds": number_in_range(
                    raw.get("durationSeconds", 30),
                    "%s durationSeconds" % identifier,
                    5,
                    600,
                ),
            }
        )
    private = {
        "dataDirectory": data_directory.resolve(),
        "manifestPath": path.resolve(),
    }
    return private, validated


def command_validate(args: argparse.Namespace) -> int:
    _, games = load_manifest(pathlib.Path(args.manifest).expanduser())
    enabled = sum(1 for game in games if game["enabled"])
    print(
        json.dumps(
            {
                "valid": True,
                "games": len(games),
                "enabled": enabled,
                "pathsDisclosed": False,
            },
            sort_keys=True,
        )
    )
    return 0


def selected_backends(raw: Sequence[str]) -> List[str]:
    # The standalone executable has no Cocoa view or CAMetalLayer, so the
    # managed renderer gate cannot select SolMetal. Keep SolMetal as a parser
    # choice for an explicit fail-closed diagnostic, but never make it the
    # default executable case.
    values = list(raw) if raw else ["moltenvk"]
    expanded: List[str] = []
    for value in values:
        candidates = ["solmetal", "moltenvk"] if value == "both" else [value]
        for candidate in candidates:
            if candidate not in expanded:
                expanded.append(candidate)
    return expanded


def selected_games(
    all_games: Sequence[Dict[str, Any]], raw_ids: Optional[Sequence[str]]
) -> List[Dict[str, Any]]:
    if not raw_ids:
        return [game for game in all_games if game["enabled"]]

    ordered_ids: List[str] = []
    seen_ids = set()
    for identifier in raw_ids:
        # Do not echo arbitrary command-line values: a pasted private path must
        # never escape through the public runner output or diagnostics.
        if not isinstance(identifier, str) or not SAFE_ID.fullmatch(identifier):
            raise HarnessError("A selected game id is invalid.")
        if identifier not in seen_ids:
            ordered_ids.append(identifier)
            seen_ids.add(identifier)

    games_by_id = {game["id"]: game for game in all_games}
    for identifier in ordered_ids:
        if identifier not in games_by_id:
            raise HarnessError("Unknown game id: %s" % identifier)

    return [
        games_by_id[identifier]
        for identifier in ordered_ids
        if games_by_id[identifier]["enabled"]
    ]


def public_game_label(game: Dict[str, Any]) -> str:
    return game["publicLabel"] or game["id"]


def process_named(name: str) -> bool:
    pgrep = shutil.which("pgrep")
    if not pgrep:
        return False
    result = subprocess.run(
        [pgrep, "-x", name],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def redacted_plan(
    games: Sequence[Dict[str, Any]],
    backends: Sequence[str],
    repeat: int,
    args: argparse.Namespace,
) -> Dict[str, Any]:
    cases = []
    total_seconds = 0.0
    embedded_solmetal = bool(getattr(args, "embedded_solmetal", False))
    direct_mutation_batching = bool(
        getattr(args, "solmetal_direct_mutation_batching", False)
    )
    for game in games:
        warmup = args.warmup if args.warmup is not None else game["warmupSeconds"]
        duration = args.duration if args.duration is not None else game["durationSeconds"]
        for backend in backends:
            for repetition in range(1, repeat + 1):
                cases.append(
                    {
                        "game": public_game_label(game),
                        "backend": backend,
                        "executionMode": (
                            "embedded-appkit" if backend == "solmetal" else "standalone"
                        ),
                        "executionSupported": (
                            backend == "moltenvk"
                            or (backend == "solmetal" and embedded_solmetal)
                        ),
                        "requiresEmbeddedMetalSurface": backend == "solmetal",
                        "directMutationBatching": (
                            direct_mutation_batching if backend == "solmetal" else False
                        ),
                        "repetition": repetition,
                        "warmupSeconds": warmup,
                        "durationSeconds": duration,
                    }
                )
                total_seconds += args.first_frame_timeout + warmup + duration
    return {
        "executeRequired": True,
        "allCasesExecutable": all(
            case["executionSupported"] for case in cases
        ),
        "games": len(games),
        "cases": cases,
        "estimatedMaximumSecondsBeforeCooldowns": total_seconds,
        "pathsDisclosed": False,
    }


def stream_reader(
    stream: Any,
    stream_name: str,
    started: float,
    messages: "queue.Queue[Tuple[float, str, Optional[str]]]",
) -> None:
    try:
        for raw in iter(stream.readline, b""):
            messages.put(
                (
                    time.monotonic() - started,
                    stream_name,
                    raw.decode("utf-8", errors="replace").rstrip("\r\n"),
                )
            )
    finally:
        messages.put((time.monotonic() - started, stream_name, None))


def error_category(text: str) -> str:
    lowered = text.casefold()
    if "not supported" in lowered or "unsupported" in lowered:
        return "unsupported-graphics-contract"
    if "prod.keys" in lowered or "keys not found" in lowered:
        return "missing-keys"
    if "firmware" in lowered:
        return "firmware-or-content"
    if "outofmemory" in lowered or "out of memory" in lowered:
        return "out-of-memory"
    if "timeout" in lowered:
        return "timeout"
    return "engine-error"


def moltenvk_log_classification(
    line: str, continuation_timestamp: Optional[str]
) -> Tuple[Optional[str], Optional[str]]:
    """Classify MoltenVK's stderr-to-error-logger bridge.

    MoltenVK info and warning callbacks are routed through Ryubing's `|E|`
    logger even when they are not fatal. Multiline capability dumps retain the
    first callback's timestamp and thread but omit the `[mvk-*]` marker.
    """
    lowered = line.casefold()
    timestamp_match = re.match(
        r"^(\d\d:\d\d:\d\d\.\d+)\s+\|e\|\s+\.net tp worker\s+",
        lowered,
    )
    timestamp = timestamp_match.group(1) if timestamp_match else None
    severity_match = re.search(r"\[mvk-(debug|info|warn|error)\]", lowered)
    if severity_match:
        severity = severity_match.group(1)
        if severity in {"debug", "info", "warn"}:
            return severity, timestamp
        return "error", None
    if timestamp is not None and timestamp == continuation_timestamp:
        return "continuation", continuation_timestamp
    return None, None


def runtime_backend_signal(line: str) -> Optional[str]:
    lowered = line.casefold()
    if (
        re.search(r"\[mvk-(?:debug|info|warn|error)\]", lowered)
        or "moltenvk version" in lowered
        or re.search(r"printgpuinformation:.*\(vulkan\s+v", lowered)
    ):
        return "moltenvk"
    if (
        "starting-solmetal-gal" in lowered
        or "starting the experimental native metal renderer" in lowered
        or "solmetal completed its first native guest draw" in lowered
        or "solmetal accepted its first native guest draw" in lowered
        or "solmetal presented its first native guest frame" in lowered
    ):
        return "solmetal"
    return None


def canonical_backend(value: Any) -> Optional[str]:
    if not isinstance(value, str):
        return None
    compact = re.sub(r"[^a-z0-9]", "", value.casefold())
    if compact == "solmetal":
        return "solmetal"
    if compact in {"moltenvk", "vulkan"}:
        return "moltenvk"
    return None


def backend_attestation(
    requested: str,
    runtime_signals: Sequence[str],
    benchmark: Optional[Dict[str, Any]],
) -> Dict[str, Any]:
    runtime_backends = sorted(set(runtime_signals))
    benchmark_backend = canonical_backend(
        benchmark.get("backend") if benchmark else None
    )
    observed_backend = (
        runtime_backends[0] if len(runtime_backends) == 1 else None
    )
    if len(runtime_backends) > 1:
        status = "conflict"
    elif observed_backend is None or benchmark_backend is None:
        status = "missing"
    elif observed_backend != benchmark_backend:
        status = "conflict"
    elif observed_backend != requested:
        status = "mismatch"
    else:
        status = "attested"
    evidence = []
    if observed_backend is not None:
        evidence.append("runtime-log")
    if benchmark_backend is not None:
        evidence.append("benchmark-report")
    return {
        "status": status,
        "requestedBackend": requested,
        "observedBackend": observed_backend,
        "benchmarkBackend": benchmark_backend,
        "evidence": evidence,
    }


def benchmark_has_frame(benchmark: Optional[Dict[str, Any]]) -> bool:
    if not benchmark or benchmark.get("completed") is not True:
        return False
    presented = benchmark.get("presentedFrames")
    return (
        isinstance(presented, (int, float))
        and not isinstance(presented, bool)
        and math.isfinite(float(presented))
        and float(presented) > 0
    )


def error_fingerprint(category: str, text: str, secrets_to_remove: Iterable[str]) -> str:
    normalized = text
    for secret in sorted((value for value in secrets_to_remove if value), key=len, reverse=True):
        normalized = normalized.replace(secret, "<private>")
    normalized = re.sub(r"file://\S+", "<path>", normalized)
    normalized = re.sub(r"/(?:Users|Volumes|private|tmp)/\S+", "<path>", normalized)
    normalized = re.sub(r"\s+", " ", normalized).strip().casefold()
    return hashlib.sha256((category + "\0" + normalized).encode("utf-8")).hexdigest()[:16]


def safe_benchmark(raw: Any) -> Optional[Dict[str, Any]]:
    if not isinstance(raw, dict):
        return None
    scalar_fields = (
        "schemaVersion",
        "backend",
        "rendererName",
        "completed",
        "configuredWarmupSeconds",
        "configuredDurationSeconds",
        "measuredSeconds",
        "presentedFrames",
        "presentedFramesPerSecond",
    )
    distribution_fields = (
        "sourceFramesPerSecond",
        "presentFrameTimeMilliseconds",
        "fifoPercent",
        "processCpuPercent",
        "workingSetBytes",
    )
    result: Dict[str, Any] = {}
    for field in scalar_fields:
        value = raw.get(field)
        if isinstance(value, (str, bool, int, float)) and not (
            isinstance(value, float) and (value != value or abs(value) == float("inf"))
        ):
            result[field] = value
    allowed_distribution_fields = {
        "samples",
        "mean",
        "median",
        "p95",
        "p99",
        "minimum",
        "maximum",
    }
    for field in distribution_fields:
        value = raw.get(field)
        if not isinstance(value, dict):
            continue
        cleaned = {
            key: item
            for key, item in value.items()
            if key in allowed_distribution_fields
            and isinstance(item, (int, float))
            and not isinstance(item, bool)
        }
        result[field] = cleaned
    return result


def safe_embedded_benchmark(raw: Any) -> Optional[Dict[str, Any]]:
    benchmark = safe_benchmark(raw)
    if benchmark is None:
        return None
    backend = canonical_backend(benchmark.get("backend"))
    if backend is None:
        benchmark.pop("backend", None)
    else:
        benchmark["backend"] = backend
    # The developer host intentionally does not publish arbitrary renderer
    # labels. Keep the runner equally strict if a replacement host adds one.
    benchmark.pop("rendererName", None)
    return benchmark


def read_benchmark(path: pathlib.Path) -> Optional[Dict[str, Any]]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return safe_benchmark(json.load(handle))
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return None


def write_private_line(handle: Any, elapsed: float, stream_name: str, line: str) -> None:
    handle.write("[%09.3f] [%s] %s\n" % (elapsed, stream_name, line))
    handle.flush()


def request_owned_process_stop(process: subprocess.Popen) -> bool:
    if process.poll() is not None:
        return False
    try:
        if process.stdin:
            process.stdin.write(b'{"command":"stop"}\n')
            process.stdin.flush()
            return True
    except (BrokenPipeError, OSError):
        return False
    return False


def terminate_owned_process(process: subprocess.Popen, timeout: float) -> str:
    """Tear down only the child owned by this case and describe how it ended."""
    if process.poll() is not None:
        return "natural-exit"
    process.terminate()
    try:
        process.wait(timeout=min(5.0, timeout))
        return "terminate"
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5.0)
        return "kill"


def run_case(
    engine: pathlib.Path,
    private: Dict[str, Any],
    game: Dict[str, Any],
    backend: str,
    repetition: int,
    warmup: float,
    duration: float,
    first_frame_timeout: float,
    case_timeout: float,
    stop_timeout: float,
    keep_awake: bool,
    private_run_root: pathlib.Path,
) -> Dict[str, Any]:
    if backend != "moltenvk":
        raise HarnessError(
            "The standalone compatibility host cannot execute SolMetal without "
            "an embedded Cocoa view and CAMetalLayer."
        )
    case_token = "%s-%s-r%d-%s" % (
        game["id"],
        backend,
        repetition,
        secrets.token_hex(4),
    )
    case_root = private_run_root / case_token
    case_root.mkdir(parents=True, exist_ok=False, mode=0o700)
    os.chmod(str(case_root), 0o700)
    raw_log = case_root / "engine.raw.log"
    benchmark_path = case_root / "benchmark.raw.json"

    environment = os.environ.copy()
    for name in list(environment):
        if name.startswith(("SOL_METAL_", "SOL_DLSM_", "SOL_BENCHMARK_")):
            environment.pop(name, None)
    environment.update(
        {
            "DOTNET_CLI_TELEMETRY_OPTOUT": "1",
            "DOTNET_NOLOGO": "1",
            "SOL_BENCHMARK_OUTPUT": str(benchmark_path),
            "SOL_BENCHMARK_LABEL": "%s-%s-r%d"
            % (game["id"], backend, repetition),
            "SOL_BENCHMARK_WARMUP_SECONDS": str(warmup),
            "SOL_BENCHMARK_DURATION_SECONDS": str(duration),
        }
    )
    environment.pop("SOL_METAL_GAL_BACKEND", None)

    command = [
        str(engine),
        "--use-main-config",
        "--use-hypervisor",
        "false",
        "--root-data-dir",
        str(private["dataDirectory"]),
        str(game["path"]),
    ]
    started = time.monotonic()
    messages: "queue.Queue[Tuple[float, str, Optional[str]]]" = queue.Queue()
    process = subprocess.Popen(
        command,
        cwd=str(engine.parent),
        env=environment,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    readers = [
        threading.Thread(
            target=stream_reader,
            args=(process.stdout, "stdout", started, messages),
            daemon=True,
        ),
        threading.Thread(
            target=stream_reader,
            args=(process.stderr, "stderr", started, messages),
            daemon=True,
        ),
    ]
    for reader in readers:
        reader.start()

    caffeinate = None
    if keep_awake and shutil.which("caffeinate"):
        caffeinate = subprocess.Popen(
            ["caffeinate", "-d", "-i", "-m", "-s", "-w", str(process.pid)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    milestones: Dict[str, Any] = {}
    launch_progress: List[Dict[str, Any]] = []
    errors: List[Dict[str, Any]] = []
    slow_gpu_warnings = 0
    engine_error_lines = 0
    maximum_draw_milestone = 0
    timeout_reason: Optional[str] = None
    benchmark: Optional[Dict[str, Any]] = None
    streams_closed = 0
    graceful_stop = False
    forced_termination = False
    stop_requested = False
    stop_request_sent = False
    stop_requested_at: Optional[float] = None
    session_stop_acknowledged = False
    session_idle_at: Optional[float] = None
    host_teardown: Optional[str] = None
    runtime_backend_signals: List[str] = []
    mvk_continuation_timestamp: Optional[str] = None
    moltenvk_debug_lines = 0
    moltenvk_info_lines = 0
    moltenvk_warning_lines = 0
    moltenvk_continuation_lines = 0
    shutdown_error_lines = 0
    secrets_to_remove = [
        str(game["path"]),
        str(private["dataDirectory"]),
        str(private["manifestPath"]),
        str(pathlib.Path.home()),
        game.get("privateName", ""),
    ]

    with os.fdopen(os.open(str(raw_log), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w", encoding="utf-8") as raw_handle:
        try:
            while True:
                elapsed = time.monotonic() - started
                try:
                    line_elapsed, stream_name, line = messages.get(timeout=0.05)
                except queue.Empty:
                    line_elapsed, stream_name, line = elapsed, "", None
                if stream_name and line is None:
                    streams_closed += 1
                elif line is not None:
                    write_private_line(raw_handle, line_elapsed, stream_name, line)
                    if line.startswith(PROTOCOL_PREFIX):
                        try:
                            event = json.loads(line[len(PROTOCOL_PREFIX) :])
                        except json.JSONDecodeError:
                            event = None
                        if isinstance(event, dict):
                            event_name = event.get("event")
                            if event_name == "host.ready":
                                milestones.setdefault("hostReadySeconds", round(line_elapsed, 3))
                            elif event_name == "launch.progress":
                                stage = event.get("loadStage")
                                if isinstance(stage, str) and len(stage) <= 80:
                                    item: Dict[str, Any] = {
                                        "stage": stage,
                                        "atSeconds": round(line_elapsed, 3),
                                    }
                                    for source, target in (
                                        ("progressCurrent", "current"),
                                        ("progressTotal", "total"),
                                    ):
                                        if isinstance(event.get(source), int):
                                            item[target] = event[source]
                                    launch_progress.append(item)
                            elif event_name == "session.state":
                                phase = event.get("phase")
                                if isinstance(phase, str) and phase in {
                                    "idle",
                                    "launching",
                                    "running",
                                    "paused",
                                    "stopping",
                                    "stopped",
                                }:
                                    milestones.setdefault(
                                        "phase.%sSeconds" % phase, round(line_elapsed, 3)
                                    )
                                    if (
                                        stop_requested
                                        and stop_requested_at is not None
                                        and line_elapsed >= stop_requested_at
                                        and phase in {"idle", "stopped"}
                                    ):
                                        session_stop_acknowledged = True
                                        graceful_stop = True
                                        session_idle_at = line_elapsed
                            elif event_name == "launch.first-frame":
                                milestones.setdefault("firstFrameSeconds", round(line_elapsed, 3))
                                milestones.setdefault("firstFrameEvidence", "protocol-event")
                                if isinstance(event.get("width"), int):
                                    milestones["firstFrameWidth"] = event["width"]
                                if isinstance(event.get("height"), int):
                                    milestones["firstFrameHeight"] = event["height"]
                            elif event_name == "host.error":
                                message = str(event.get("message") or "")
                                category = error_category(message)
                                errors.append(
                                    {
                                        "atSeconds": round(line_elapsed, 3),
                                        "source": "protocol",
                                        "category": category,
                                        "fingerprint": error_fingerprint(
                                            category, message, secrets_to_remove
                                        ),
                                    }
                                )

                    lowered = line.casefold()
                    backend_signal = runtime_backend_signal(line)
                    if backend_signal is not None:
                        runtime_backend_signals.append(backend_signal)
                    mvk_classification, continuation = moltenvk_log_classification(
                        line, mvk_continuation_timestamp
                    )
                    if mvk_classification in {"debug", "info", "warn"}:
                        mvk_continuation_timestamp = continuation
                        if mvk_classification == "debug":
                            moltenvk_debug_lines += 1
                        elif mvk_classification == "info":
                            moltenvk_info_lines += 1
                        else:
                            moltenvk_warning_lines += 1
                    elif mvk_classification == "continuation":
                        moltenvk_continuation_lines += 1
                    else:
                        mvk_continuation_timestamp = None
                    if "application loaded:" in lowered:
                        milestones.setdefault("applicationLoadedSeconds", round(line_elapsed, 3))
                    if (
                        "solmetal completed its first native guest draw" in lowered
                        or "solmetal accepted its first native guest draw" in lowered
                    ):
                        milestones.setdefault("firstDrawSeconds", round(line_elapsed, 3))
                        maximum_draw_milestone = max(maximum_draw_milestone, 1)
                    draw_match = re.search(
                        r"solmetal completed ([0-9,]+) native guest draws", lowered
                    )
                    if draw_match:
                        maximum_draw_milestone = max(
                            maximum_draw_milestone,
                            int(draw_match.group(1).replace(",", "")),
                        )
                    if "solmetal presented its first native guest frame" in lowered:
                        milestones.setdefault("firstFrameSeconds", round(line_elapsed, 3))
                        milestones.setdefault("firstFrameEvidence", "renderer-log")
                    if "solmetal sustained 60 native guest presentations" in lowered:
                        milestones.setdefault("sixtyPresentationsSeconds", round(line_elapsed, 3))
                    if "gpu processing thread is too slow" in lowered:
                        slow_gpu_warnings += 1
                    log_is_error = (
                        "unhandled exception caught" in lowered or "|e|" in lowered
                    )
                    routine_mvk_line = mvk_classification in {
                        "debug",
                        "info",
                        "warn",
                        "continuation",
                    }
                    if log_is_error and not routine_mvk_line:
                        after_stop = (
                            stop_requested
                            and stop_requested_at is not None
                            and line_elapsed >= stop_requested_at
                        )
                        if after_stop:
                            shutdown_error_lines += 1
                        else:
                            engine_error_lines += 1
                            category = error_category(line)
                            fingerprint = error_fingerprint(
                                category, line, secrets_to_remove
                            )
                            if (
                                len(errors) < 50
                                and not any(
                                    error["fingerprint"] == fingerprint for error in errors
                                )
                            ):
                                errors.append(
                                    {
                                        "atSeconds": round(line_elapsed, 3),
                                        "source": "engine-log",
                                        "category": category,
                                        "fingerprint": fingerprint,
                                    }
                                )

                benchmark = read_benchmark(benchmark_path) or benchmark
                if benchmark_has_frame(benchmark):
                    milestones.setdefault("firstFrameEvidence", "completed-benchmark")
                    milestones.setdefault("benchmarkCompletedSeconds", round(elapsed, 3))
                if (
                    benchmark
                    and benchmark.get("completed")
                    and not stop_requested
                ):
                    stop_requested = True
                    stop_requested_at = time.monotonic() - started
                    stop_request_sent = request_owned_process_stop(process)
                    continue
                if (
                    not stop_requested
                    and not benchmark_has_frame(benchmark)
                    and "firstFrameSeconds" not in milestones
                    and elapsed >= first_frame_timeout
                ):
                    timeout_reason = "first-frame"
                    stop_requested = True
                    stop_requested_at = time.monotonic() - started
                    stop_request_sent = request_owned_process_stop(process)
                    continue
                if not stop_requested and elapsed >= case_timeout:
                    timeout_reason = "case"
                    stop_requested = True
                    stop_requested_at = time.monotonic() - started
                    stop_request_sent = request_owned_process_stop(process)
                    continue
                if (
                    stop_requested
                    and session_idle_at is not None
                    and process.poll() is None
                    and elapsed - session_idle_at >= 0.1
                ):
                    teardown = terminate_owned_process(process, stop_timeout)
                    host_teardown = "%s-after-session-idle" % teardown
                    continue
                if (
                    stop_requested
                    and stop_requested_at is not None
                    and process.poll() is None
                    and elapsed - stop_requested_at >= stop_timeout
                ):
                    forced_termination = True
                    teardown = terminate_owned_process(process, stop_timeout)
                    host_teardown = "%s-after-stop-timeout" % teardown
                    continue
                if process.poll() is not None and streams_closed >= 2 and messages.empty():
                    if host_teardown is None:
                        host_teardown = "natural-exit"
                    if stop_requested and process.returncode == 0:
                        graceful_stop = True
                    break
        except KeyboardInterrupt:
            timeout_reason = "interrupted"
            if not stop_requested:
                stop_requested = True
                stop_requested_at = time.monotonic() - started
                stop_request_sent = request_owned_process_stop(process)
            if process.poll() is None:
                forced_termination = True
                teardown = terminate_owned_process(process, stop_timeout)
                host_teardown = "%s-after-interrupt" % teardown
            raise
        finally:
            if process.poll() is None:
                if session_stop_acknowledged:
                    teardown = terminate_owned_process(process, stop_timeout)
                    host_teardown = "%s-after-session-idle" % teardown
                else:
                    forced_termination = True
                    teardown = terminate_owned_process(process, stop_timeout)
                    host_teardown = "%s-after-cleanup" % teardown
            if caffeinate is not None and caffeinate.poll() is None:
                caffeinate.terminate()
                try:
                    caffeinate.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    caffeinate.kill()
            for reader in readers:
                reader.join(timeout=1)
            while True:
                try:
                    line_elapsed, stream_name, line = messages.get_nowait()
                except queue.Empty:
                    break
                if line is not None:
                    write_private_line(raw_handle, line_elapsed, stream_name, line)

    benchmark = read_benchmark(benchmark_path) or benchmark
    exit_code = process.returncode
    if maximum_draw_milestone:
        milestones["maximumDrawMilestone"] = maximum_draw_milestone

    categories = {error["category"] for error in errors}
    benchmark_complete = bool(benchmark and benchmark.get("completed"))
    first_frame = "firstFrameSeconds" in milestones or benchmark_has_frame(benchmark)
    attestation = backend_attestation(backend, runtime_backend_signals, benchmark)
    observed_backend = attestation["observedBackend"] or "unattested"
    clean_session_stop = (
        graceful_stop
        and not forced_termination
        and (
            (host_teardown == "natural-exit" and exit_code == 0)
            or (
                session_stop_acknowledged
                and host_teardown
                in {"terminate-after-session-idle", "kill-after-session-idle"}
            )
        )
    )
    if "unsupported-graphics-contract" in categories:
        status = "unsupported"
    elif attestation["status"] != "attested":
        status = "failed"
    elif (
        first_frame
        and benchmark_complete
        and attestation["status"] == "attested"
        and not errors
        and engine_error_lines == 0
        and clean_session_stop
    ):
        status = "passed"
    elif first_frame:
        status = "partial"
    else:
        status = "failed"

    return {
        "game": public_game_label(game),
        "caseId": "%s-%s-r%d" % (game["id"], backend, repetition),
        "executionMode": "standalone",
        "requestedBackend": backend,
        "backend": observed_backend,
        "backendAttestation": attestation,
        "repetition": repetition,
        "status": status,
        "visualStatus": "not-reviewed",
        "visualReviewRequired": True,
        "timeout": timeout_reason,
        "exitCode": exit_code,
        "gracefulStop": graceful_stop,
        "forcedTermination": forced_termination,
        "stopRequestSent": stop_request_sent,
        "sessionStopAcknowledged": session_stop_acknowledged,
        "hostTeardown": host_teardown,
        "milestones": milestones,
        "launchProgress": launch_progress,
        "diagnostics": {
            "hostErrors": errors,
            "engineErrorLines": engine_error_lines,
            "shutdownErrorLines": shutdown_error_lines,
            "moltenvkDebugLines": moltenvk_debug_lines,
            "moltenvkInfoLines": moltenvk_info_lines,
            "moltenvkWarningLines": moltenvk_warning_lines,
            "moltenvkContinuationLines": moltenvk_continuation_lines,
            "slowGpuWarnings": slow_gpu_warnings,
        },
        "benchmark": benchmark,
    }


def request_embedded_host_stop(process: subprocess.Popen) -> bool:
    """Ask only the owned AppKit host to run its embedded shutdown path."""
    if process.poll() is not None:
        return False
    try:
        process.send_signal(signal.SIGINT)
        return True
    except OSError:
        return False


def parse_embedded_host_event(line: str) -> Optional[Dict[str, Any]]:
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        return None
    if (
        not isinstance(event, dict)
        or event.get("schemaVersion") != 1
        or event.get("source") != "solmetal-embedded-host"
        or not isinstance(event.get("event"), str)
    ):
        return None
    return event


def run_embedded_solmetal_case(
    embedded_host: pathlib.Path,
    sol_app: pathlib.Path,
    private: Dict[str, Any],
    game: Dict[str, Any],
    repetition: int,
    warmup: float,
    duration: float,
    first_frame_timeout: float,
    case_timeout: float,
    stop_timeout: float,
    keep_awake: bool,
    private_run_root: pathlib.Path,
    direct_mutation_batching: bool = False,
) -> Dict[str, Any]:
    case_token = "%s-solmetal-r%d-%s" % (
        game["id"],
        repetition,
        secrets.token_hex(4),
    )
    case_root = private_run_root / case_token
    case_root.mkdir(parents=True, exist_ok=False, mode=0o700)
    os.chmod(str(case_root), 0o700)
    raw_log = case_root / "embedded-host.raw.log"

    environment = os.environ.copy()
    for name in list(environment):
        if name.startswith(
            ("SOL_METAL_", "SOL_DLSM_", "SOL_BENCHMARK_", "SOL_PRIVATE_")
        ):
            environment.pop(name, None)
    environment.update(
        {
            "DOTNET_CLI_TELEMETRY_OPTOUT": "1",
            "DOTNET_NOLOGO": "1",
            # Private paths stay out of the process argument list. The embedded
            # host consumes these at runtime and quarantines managed output.
            "SOL_PRIVATE_GAME_PATH": str(game["path"]),
            "SOL_PRIVATE_DATA_PATH": str(private["dataDirectory"]),
        }
    )
    if direct_mutation_batching:
        environment["SOL_METAL_DIRECT_MUTATION_BATCHING"] = "1"
    command = [
        str(embedded_host),
        "--app",
        str(sol_app),
        "--warmup",
        str(warmup),
        "--duration",
        str(duration),
        "--first-frame-timeout",
        str(first_frame_timeout),
        "--stop-timeout",
        str(stop_timeout),
    ]

    started = time.monotonic()
    messages: "queue.Queue[Tuple[float, str, Optional[str]]]" = queue.Queue()
    try:
        process = subprocess.Popen(
            command,
            cwd=str(embedded_host.parent),
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except OSError as error:
        raise HarnessError("The embedded SolMetal host could not start.") from error

    readers = [
        threading.Thread(
            target=stream_reader,
            args=(process.stdout, "stdout", started, messages),
            daemon=True,
        ),
        threading.Thread(
            target=stream_reader,
            args=(process.stderr, "stderr", started, messages),
            daemon=True,
        ),
    ]
    for reader in readers:
        reader.start()

    caffeinate = None
    if keep_awake and shutil.which("caffeinate"):
        caffeinate = subprocess.Popen(
            ["caffeinate", "-d", "-i", "-m", "-s", "-w", str(process.pid)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    milestones: Dict[str, Any] = {}
    launch_progress: List[Dict[str, Any]] = []
    errors: List[Dict[str, Any]] = []
    runtime_backend_signals: List[str] = []
    benchmark: Optional[Dict[str, Any]] = None
    embedded_attestation: Optional[Dict[str, Any]] = None
    host_finished: Optional[Dict[str, Any]] = None
    engine_exit_code: Optional[int] = None
    streams_closed = 0
    invalid_json_lines = 0
    timeout_reason: Optional[str] = None
    stop_requested_at: Optional[float] = None
    stop_request_sent = False
    shutdown_accepted = False
    session_stop_acknowledged = False
    forced_termination = False
    host_teardown: Optional[str] = None

    secrets_to_remove = [
        str(game["path"]),
        str(private["dataDirectory"]),
        str(private["manifestPath"]),
        str(pathlib.Path.home()),
        game.get("privateName", ""),
    ]

    with os.fdopen(
        os.open(str(raw_log), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600),
        "w",
        encoding="utf-8",
    ) as raw_handle:
        try:
            while True:
                elapsed = time.monotonic() - started
                try:
                    line_elapsed, stream_name, line = messages.get(timeout=0.05)
                except queue.Empty:
                    line_elapsed, stream_name, line = elapsed, "", None

                if stream_name and line is None:
                    streams_closed += 1
                elif line is not None:
                    write_private_line(raw_handle, line_elapsed, stream_name, line)
                    event = parse_embedded_host_event(line)
                    if event is None:
                        invalid_json_lines += 1
                    else:
                        event_name = event["event"]
                        if event_name == "host.ready":
                            milestones.setdefault("hostReadySeconds", round(line_elapsed, 3))
                        elif event_name == "surface.ready":
                            milestones.setdefault("surfaceReadySeconds", round(line_elapsed, 3))
                        elif event_name == "engine.start":
                            milestones.setdefault("engineStartSeconds", round(line_elapsed, 3))
                            if event.get("result") != 0:
                                errors.append(
                                    {
                                        "atSeconds": round(line_elapsed, 3),
                                        "source": "embedded-host",
                                        "category": "engine-start",
                                        "fingerprint": error_fingerprint(
                                            "engine-start",
                                            "embedded engine start failed",
                                            secrets_to_remove,
                                        ),
                                    }
                                )
                        elif event_name == "engine.event":
                            managed = event.get("managed")
                            if isinstance(managed, dict):
                                managed_name = managed.get("event")
                                if managed_name == "launch.progress":
                                    stage = managed.get("loadStage")
                                    if isinstance(stage, str) and len(stage) <= 80:
                                        item: Dict[str, Any] = {
                                            "stage": stage,
                                            "atSeconds": round(line_elapsed, 3),
                                        }
                                        for source, target in (
                                            ("progressCurrent", "current"),
                                            ("progressTotal", "total"),
                                        ):
                                            if isinstance(managed.get(source), int):
                                                item[target] = managed[source]
                                        launch_progress.append(item)
                                        if stage == "starting-solmetal-gal":
                                            runtime_backend_signals.append("solmetal")
                                elif managed_name == "launch.first-frame":
                                    milestones.setdefault(
                                        "firstFrameSeconds", round(line_elapsed, 3)
                                    )
                                    milestones.setdefault(
                                        "firstFrameEvidence", "embedded-protocol-event"
                                    )
                                    if isinstance(managed.get("width"), int):
                                        milestones["firstFrameWidth"] = managed["width"]
                                    if isinstance(managed.get("height"), int):
                                        milestones["firstFrameHeight"] = managed["height"]
                                elif managed_name == "embedded.terminated":
                                    session_stop_acknowledged = True
                                    if isinstance(managed.get("exitCode"), int):
                                        engine_exit_code = managed["exitCode"]
                                elif managed_name == "host.error":
                                    category = "engine-error"
                                    errors.append(
                                        {
                                            "atSeconds": round(line_elapsed, 3),
                                            "source": "embedded-engine",
                                            "category": category,
                                            "fingerprint": error_fingerprint(
                                                category,
                                                "embedded engine error",
                                                secrets_to_remove,
                                            ),
                                        }
                                    )
                        elif event_name == "host.stop-requested":
                            stop_requested_at = stop_requested_at or line_elapsed
                            stop_request_sent = event.get("commandAccepted") is True
                            shutdown_accepted = event.get("shutdownAccepted") is True
                        elif event_name == "backend.attestation":
                            embedded_attestation = {
                                "status": event.get("status")
                                if event.get("status") in {"attested", "missing", "conflict"}
                                else "invalid",
                                "requestedBackend": canonical_backend(
                                    event.get("requestedBackend")
                                ),
                                "observedBackend": canonical_backend(
                                    event.get("observedBackend")
                                ),
                                "engineLaunchStage": event.get("engineLaunchStage") is True,
                                "benchmarkReport": event.get("benchmarkReport") is True,
                            }
                        elif event_name == "benchmark.result":
                            benchmark = safe_embedded_benchmark(event)
                            if benchmark_has_frame(benchmark):
                                milestones.setdefault(
                                    "benchmarkCompletedSeconds", round(line_elapsed, 3)
                                )
                                milestones.setdefault(
                                    "firstFrameEvidence", "completed-benchmark"
                                )
                        elif event_name == "host.finished":
                            host_finished = {
                                "status": event.get("status")
                                if event.get("status") in {"passed", "failed"}
                                else "invalid",
                                "engineExitCode": event.get("engineExitCode")
                                if isinstance(event.get("engineExitCode"), int)
                                else None,
                                "firstFrame": event.get("firstFrame") is True,
                                "benchmarkCompleted": event.get("benchmarkCompleted") is True,
                                "backendAttested": event.get("backendAttested") is True,
                                "gracefulStop": event.get("gracefulStop") is True,
                            }
                        elif event_name == "host.error":
                            code = event.get("code")
                            category = (
                                code
                                if isinstance(code, str)
                                and re.fullmatch(r"[a-z0-9_-]{1,80}", code)
                                else "embedded-host-error"
                            )
                            errors.append(
                                {
                                    "atSeconds": round(line_elapsed, 3),
                                    "source": "embedded-host",
                                    "category": category,
                                    "fingerprint": error_fingerprint(
                                        category, category, secrets_to_remove
                                    ),
                                }
                            )

                if (
                    process.poll() is None
                    and stop_requested_at is None
                    and elapsed >= case_timeout
                ):
                    timeout_reason = "case"
                    stop_requested_at = elapsed
                    stop_request_sent = request_embedded_host_stop(process)
                    continue
                if (
                    process.poll() is None
                    and stop_requested_at is not None
                    and elapsed - stop_requested_at >= stop_timeout
                ):
                    forced_termination = True
                    teardown = terminate_owned_process(process, stop_timeout)
                    host_teardown = "%s-after-stop-timeout" % teardown
                    continue
                if process.poll() is not None and streams_closed >= 2 and messages.empty():
                    if host_teardown is None:
                        host_teardown = "natural-exit"
                    break
        except KeyboardInterrupt:
            timeout_reason = "interrupted"
            if process.poll() is None:
                stop_requested_at = time.monotonic() - started
                stop_request_sent = request_embedded_host_stop(process)
                try:
                    process.wait(timeout=stop_timeout)
                except subprocess.TimeoutExpired:
                    forced_termination = True
                    teardown = terminate_owned_process(process, stop_timeout)
                    host_teardown = "%s-after-interrupt" % teardown
            raise
        finally:
            if process.poll() is None:
                if stop_requested_at is None:
                    stop_request_sent = request_embedded_host_stop(process)
                try:
                    process.wait(timeout=stop_timeout)
                except subprocess.TimeoutExpired:
                    forced_termination = True
                    teardown = terminate_owned_process(process, stop_timeout)
                    host_teardown = "%s-after-cleanup" % teardown
            if caffeinate is not None and caffeinate.poll() is None:
                caffeinate.terminate()
                try:
                    caffeinate.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    caffeinate.kill()
            for reader in readers:
                reader.join(timeout=1)
            while True:
                try:
                    line_elapsed, stream_name, line = messages.get_nowait()
                except queue.Empty:
                    break
                if line is not None:
                    write_private_line(raw_handle, line_elapsed, stream_name, line)

    attestation = backend_attestation(
        "solmetal", runtime_backend_signals, benchmark
    )
    if "runtime-log" in attestation["evidence"]:
        attestation["evidence"].remove("runtime-log")
        attestation["evidence"].insert(0, "embedded-launch-event")
    embedded_host_attested = bool(
        embedded_attestation
        and embedded_attestation["status"] == "attested"
        and embedded_attestation["requestedBackend"] == "solmetal"
        and embedded_attestation["observedBackend"] == "solmetal"
        and embedded_attestation["engineLaunchStage"]
        and embedded_attestation["benchmarkReport"]
    )
    attestation["embeddedHost"] = embedded_attestation or {
        "status": "missing",
        "requestedBackend": None,
        "observedBackend": None,
        "engineLaunchStage": False,
        "benchmarkReport": False,
    }
    benchmark_complete = bool(benchmark and benchmark.get("completed"))
    first_frame = "firstFrameSeconds" in milestones or benchmark_has_frame(benchmark)
    graceful_stop = bool(
        session_stop_acknowledged
        and stop_request_sent
        and shutdown_accepted
        and host_finished
        and host_finished["gracefulStop"]
        and engine_exit_code == 0
        and host_finished["engineExitCode"] == 0
        and not forced_termination
    )
    clean_host_exit = bool(
        process.returncode == 0
        and host_teardown == "natural-exit"
        and host_finished
        and host_finished["status"] == "passed"
        and host_finished["firstFrame"]
        and host_finished["benchmarkCompleted"]
        and host_finished["backendAttested"]
    )
    categories = {error["category"] for error in errors}
    if "unsupported-graphics-contract" in categories:
        status = "unsupported"
    elif attestation["status"] != "attested" or not embedded_host_attested:
        status = "failed"
    elif timeout_reason is not None:
        status = "failed"
    elif (
        first_frame
        and benchmark_complete
        and not errors
        and graceful_stop
        and clean_host_exit
        and timeout_reason is None
    ):
        status = "passed"
    elif first_frame:
        status = "partial"
    else:
        status = "failed"

    return {
        "game": public_game_label(game),
        "caseId": "%s-solmetal-r%d" % (game["id"], repetition),
        "executionMode": "embedded-appkit",
        "requestedBackend": "solmetal",
        "backend": attestation["observedBackend"] or "unattested",
        "backendAttestation": attestation,
        "repetition": repetition,
        "status": status,
        "visualStatus": "not-reviewed",
        "visualReviewRequired": True,
        "experiments": {
            "directMutationBatching": direct_mutation_batching,
        },
        "timeout": timeout_reason,
        "exitCode": process.returncode,
        "gracefulStop": graceful_stop,
        "forcedTermination": forced_termination,
        "stopRequestSent": stop_request_sent,
        "sessionStopAcknowledged": session_stop_acknowledged,
        "hostTeardown": host_teardown,
        "milestones": milestones,
        "launchProgress": launch_progress,
        "diagnostics": {
            "hostErrors": errors,
            "engineErrorLines": 0,
            "shutdownErrorLines": 0,
            "moltenvkDebugLines": 0,
            "moltenvkInfoLines": 0,
            "moltenvkWarningLines": 0,
            "moltenvkContinuationLines": 0,
            "slowGpuWarnings": 0,
            "invalidEmbeddedHostLines": invalid_json_lines,
            "shutdownAccepted": shutdown_accepted,
        },
        "benchmark": benchmark,
    }


def assert_public_result_clean(
    result: Dict[str, Any], private: Dict[str, Any], games: Sequence[Dict[str, Any]]
) -> None:
    serialized = json.dumps(result, sort_keys=True)
    secrets_to_check = [
        str(private["dataDirectory"]),
        str(private["manifestPath"]),
        str(pathlib.Path.home()),
    ]
    explicit_labels = {game["publicLabel"] for game in games if game["publicLabel"]}
    for game in games:
        secrets_to_check.append(str(game["path"]))
        private_name = game.get("privateName")
        if private_name and private_name not in explicit_labels:
            secrets_to_check.append(private_name)
    for secret in secrets_to_check:
        if secret and secret in serialized:
            raise HarnessError("The public-result privacy gate rejected private data.")
    forbidden = (
        "/Users/",
        "/Volumes/",
        "/private/var/",
        "/var/folders/",
        "file://",
        "prod.keys",
    )
    if any(token in serialized for token in forbidden):
        raise HarnessError("The public-result privacy gate rejected a local path.")


def finite_number(value: Any) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    result = float(value)
    if result != result or abs(result) == float("inf"):
        return None
    return result


def nested_number(value: Dict[str, Any], *keys: str) -> Optional[float]:
    current: Any = value
    for key in keys:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return finite_number(current)


def percent_delta(candidate: Optional[float], baseline: Optional[float]) -> Optional[float]:
    if candidate is None or baseline is None or baseline == 0:
        return None
    return round((candidate - baseline) / baseline * 100, 3)


def build_backend_comparisons(cases: Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]:
    grouped: Dict[Tuple[str, int], Dict[str, Dict[str, Any]]] = {}
    for case in cases:
        if (case.get("backendAttestation") or {}).get("status") != "attested":
            continue
        grouped.setdefault((case["game"], case["repetition"]), {})[
            case["backend"]
        ] = case
    comparisons: List[Dict[str, Any]] = []
    for (game, repetition), group in sorted(grouped.items()):
        solmetal = group.get("solmetal")
        moltenvk = group.get("moltenvk")
        if not solmetal or not moltenvk:
            continue
        if solmetal["status"] != "passed" or moltenvk["status"] != "passed":
            comparisons.append(
                {
                    "game": game,
                    "repetition": repetition,
                    "comparable": False,
                    "solmetalStatus": solmetal["status"],
                    "moltenvkStatus": moltenvk["status"],
                }
            )
            continue
        sol_benchmark = solmetal.get("benchmark") or {}
        mvk_benchmark = moltenvk.get("benchmark") or {}
        deltas = {
            "presentedFpsPercent": percent_delta(
                nested_number(sol_benchmark, "presentedFramesPerSecond"),
                nested_number(mvk_benchmark, "presentedFramesPerSecond"),
            ),
            "presentFrameP95Percent": percent_delta(
                nested_number(sol_benchmark, "presentFrameTimeMilliseconds", "p95"),
                nested_number(mvk_benchmark, "presentFrameTimeMilliseconds", "p95"),
            ),
            "cpuMedianPercent": percent_delta(
                nested_number(sol_benchmark, "processCpuPercent", "median"),
                nested_number(mvk_benchmark, "processCpuPercent", "median"),
            ),
            "workingSetMedianPercent": percent_delta(
                nested_number(sol_benchmark, "workingSetBytes", "median"),
                nested_number(mvk_benchmark, "workingSetBytes", "median"),
            ),
        }
        comparisons.append(
            {
                "game": game,
                "repetition": repetition,
                "comparable": True,
                "solmetalVersusMoltenvkPercent": {
                    key: value for key, value in deltas.items() if value is not None
                },
            }
        )
    return comparisons


def command_run(args: argparse.Namespace) -> int:
    private, all_games = load_manifest(pathlib.Path(args.manifest).expanduser())
    games = selected_games(all_games, args.only)
    if not games:
        raise HarnessError("No enabled games were selected.")
    backends = selected_backends(args.backend)
    if args.warmup is not None and args.warmup > 600:
        raise HarnessError("--warmup must not exceed 600 seconds.")
    if args.duration is not None and not 5 <= args.duration <= 600:
        raise HarnessError("--duration must be between 5 and 600 seconds.")
    plan = redacted_plan(games, backends, args.repeat, args)
    if not args.execute:
        print(json.dumps(plan, indent=2, sort_keys=True))
        return 0

    if "solmetal" in backends and not args.embedded_solmetal:
        raise HarnessError(
            "Standalone SolMetal execution is unavailable: the renderer requires "
            "Sol's embedded AppKit host to supply a Cocoa view and CAMetalLayer. "
            "Use --backend moltenvk, or explicitly opt into --embedded-solmetal."
        )
    if args.embedded_solmetal and "solmetal" not in backends:
        raise HarnessError(
            "--embedded-solmetal requires --backend solmetal or --backend both."
        )
    if args.solmetal_direct_mutation_batching and (
        not args.embedded_solmetal or "solmetal" not in backends
    ):
        raise HarnessError(
            "--solmetal-direct-mutation-batching requires an embedded SolMetal run."
        )

    if process_named("Sol") or process_named("Sol.Engine"):
        raise HarnessError(
            "Sol is already running. Stop it normally before starting an isolated suite."
        )
    engine = pathlib.Path(args.engine).expanduser().resolve()
    if "moltenvk" in backends and (
        not engine.is_file() or not os.access(str(engine), os.X_OK)
    ):
        raise HarnessError("The built Sol Engine executable is unavailable.")

    embedded_host: Optional[pathlib.Path] = None
    sol_app: Optional[pathlib.Path] = None
    if "solmetal" in backends:
        embedded_host = pathlib.Path(args.embedded_host).expanduser().resolve()
        sol_app = pathlib.Path(args.sol_app).expanduser().resolve()
        if not embedded_host.is_file() or not os.access(str(embedded_host), os.X_OK):
            raise HarnessError("The built embedded SolMetal host is unavailable.")
        if process_named(embedded_host.name):
            raise HarnessError(
                "The embedded SolMetal host is already running. Stop it normally first."
            )
        required_app_paths = (
            sol_app / "Contents" / "Resources" / "SolEngineManaged" / "Sol.Engine.dll",
            sol_app
            / "Contents"
            / "Resources"
            / "SolEngineManaged"
            / "Sol.Engine.runtimeconfig.json",
            sol_app / "Contents" / "Frameworks" / "SolMetal.dylib",
        )
        hostfxr_candidates = list(
            (sol_app / "Contents" / "Resources" / "Dotnet" / "host" / "fxr").glob(
                "*/libhostfxr.dylib"
            )
        )
        if (
            sol_app.suffix != ".app"
            or not all(path.is_file() for path in required_app_paths)
            or not hostfxr_candidates
        ):
            raise HarnessError("The selected Sol.app has no complete embedded runtime.")

    output = pathlib.Path(args.output).expanduser()
    private_run_root = private["manifestPath"].parent / "runs"
    require_private_location(private_run_root, "Raw compatibility artifacts")
    private_run_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(str(private_run_root), 0o700)

    suite_id = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + secrets.token_hex(4)
    cases: List[Dict[str, Any]] = []
    try:
        for game in games:
            warmup = args.warmup if args.warmup is not None else game["warmupSeconds"]
            duration = args.duration if args.duration is not None else game["durationSeconds"]
            automatic_timeout = args.first_frame_timeout + warmup + duration + 45
            case_timeout = args.case_timeout or automatic_timeout
            for backend in backends:
                for repetition in range(1, args.repeat + 1):
                    if backend == "solmetal":
                        assert embedded_host is not None and sol_app is not None
                        case = run_embedded_solmetal_case(
                            embedded_host=embedded_host,
                            sol_app=sol_app,
                            private=private,
                            game=game,
                            repetition=repetition,
                            warmup=warmup,
                            duration=duration,
                            first_frame_timeout=args.first_frame_timeout,
                            case_timeout=case_timeout,
                            stop_timeout=args.stop_timeout,
                            keep_awake=args.keep_awake,
                            private_run_root=private_run_root,
                            direct_mutation_batching=(
                                args.solmetal_direct_mutation_batching
                            ),
                        )
                    else:
                        case = run_case(
                            engine=engine,
                            private=private,
                            game=game,
                            backend=backend,
                            repetition=repetition,
                            warmup=warmup,
                            duration=duration,
                            first_frame_timeout=args.first_frame_timeout,
                            case_timeout=case_timeout,
                            stop_timeout=args.stop_timeout,
                            keep_awake=args.keep_awake,
                            private_run_root=private_run_root,
                        )
                    cases.append(case)
                    print(
                        "%s %s r%d: %s"
                        % (
                            public_game_label(game),
                            backend,
                            repetition,
                            case["status"],
                        )
                    )
                    if args.cooldown > 0 and not (
                        game is games[-1]
                        and backend == backends[-1]
                        and repetition == args.repeat
                    ):
                        time.sleep(args.cooldown)
    except KeyboardInterrupt:
        raise HarnessError("The suite was interrupted after stopping its active child.")

    summary = {
        "cases": len(cases),
        "passed": sum(case["status"] == "passed" for case in cases),
        "partial": sum(case["status"] == "partial" for case in cases),
        "unsupported": sum(case["status"] == "unsupported" for case in cases),
        "failed": sum(case["status"] == "failed" for case in cases),
    }
    result = {
        "schemaVersion": SCHEMA_VERSION,
        "runnerVersion": RUNNER_VERSION,
        "suiteId": suite_id,
        "generatedAtUtc": utc_now(),
        "privacy": {
            "containsLocalPaths": False,
            "containsKeyFirmwareOrSavePaths": False,
            "rawLogsIncluded": False,
            "gameNamesAreExplicitPublicLabelsOnly": True,
        },
        "scope": {
            "standaloneEngine": all(
                case["executionMode"] == "standalone" for case in cases
            ),
            "executionModes": sorted(
                {case["executionMode"] for case in cases}
            ),
            "visualCorrectnessAutomated": False,
            "requestedBackends": backends,
            "supportedBackends": [
                backend
                for backend in backends
                if backend == "moltenvk"
                or (backend == "solmetal" and args.embedded_solmetal)
            ],
            "repeat": args.repeat,
            "solmetalDirectMutationBatching": (
                args.solmetal_direct_mutation_batching
            ),
        },
        "summary": summary,
        "backendComparisons": build_backend_comparisons(cases),
        "cases": cases,
    }
    assert_public_result_clean(result, private, games)
    write_json_atomic(output, result, private=False)
    print(json.dumps({"complete": True, "summary": summary, "pathsDisclosed": False}, sort_keys=True))
    return 0 if summary["passed"] == len(cases) else 1


def positive_float(value: str) -> float:
    result = float(value)
    if result <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return result


def nonnegative_float(value: str) -> float:
    result = float(value)
    if result < 0:
        raise argparse.ArgumentTypeError("must not be negative")
    return result


def bounded_repeat(value: str) -> int:
    result = int(value)
    if not 1 <= result <= 10:
        raise argparse.ArgumentTypeError("must be between 1 and 10")
    return result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run privacy-safe, sequential Sol Engine compatibility checks."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    discover = subparsers.add_parser(
        "discover", help="Create or refresh the private game manifest."
    )
    discover.add_argument("--library", help="Private local game library folder.")
    discover.add_argument(
        "--data-directory", default=str(DEFAULT_DATA_DIRECTORY), help=argparse.SUPPRESS
    )
    discover.add_argument("--manifest", default=str(DEFAULT_MANIFEST), help=argparse.SUPPRESS)
    discover.set_defaults(function=command_discover)

    validate = subparsers.add_parser(
        "validate", help="Check private inputs without launching a game."
    )
    validate.add_argument("--manifest", default=str(DEFAULT_MANIFEST), help=argparse.SUPPRESS)
    validate.set_defaults(function=command_validate)

    run = subparsers.add_parser(
        "run", help="Print a redacted plan; add --execute to launch it."
    )
    run.add_argument("--manifest", default=str(DEFAULT_MANIFEST), help=argparse.SUPPRESS)
    run.add_argument("--engine", default=str(DEFAULT_ENGINE), help=argparse.SUPPRESS)
    run.add_argument(
        "--solmetal-library", default=str(DEFAULT_SOLMETAL_LIBRARY), help=argparse.SUPPRESS
    )
    run.add_argument("--output", default="solmetal-compatibility-results.json")
    run.add_argument(
        "--backend",
        action="append",
        choices=("solmetal", "moltenvk", "both"),
        help=(
            "Renderer; may be repeated. Defaults to moltenvk. SolMetal execution "
            "requires the explicit --embedded-solmetal mode."
        ),
    )
    run.add_argument(
        "--embedded-solmetal",
        action="store_true",
        help=(
            "Run SolMetal cases through the developer AppKit/CAMetalLayer host. "
            "Without this flag SolMetal execution fails closed."
        ),
    )
    run.add_argument(
        "--embedded-host",
        default=str(DEFAULT_EMBEDDED_HOST),
        help=argparse.SUPPRESS,
    )
    run.add_argument(
        "--sol-app",
        default=str(DEFAULT_SOL_APP),
        help=argparse.SUPPRESS,
    )
    run.add_argument(
        "--only",
        action="append",
        help=(
            "Run one private manifest id; may be repeated. Selected games run "
            "in first-occurrence command-line order."
        ),
    )
    run.add_argument("--repeat", type=bounded_repeat, default=1)
    run.add_argument("--warmup", type=nonnegative_float)
    run.add_argument("--duration", type=positive_float)
    run.add_argument("--first-frame-timeout", type=positive_float, default=180)
    run.add_argument("--case-timeout", type=positive_float)
    run.add_argument("--stop-timeout", type=positive_float, default=20)
    run.add_argument("--cooldown", type=nonnegative_float, default=5)
    run.add_argument("--keep-awake", action="store_true")
    run.add_argument(
        "--solmetal-direct-mutation-batching",
        action="store_true",
        help=(
            "Enable the bounded direct-mutation batching experiment for "
            "embedded SolMetal cases. The mode is recorded in the public result."
        ),
    )
    run.add_argument(
        "--execute",
        action="store_true",
        help="Actually launch games. Without this flag only a redacted plan is printed.",
    )
    run.set_defaults(function=command_run)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.function(args))
    except HarnessError as error:
        print("solmetal-compatibility: %s" % error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
