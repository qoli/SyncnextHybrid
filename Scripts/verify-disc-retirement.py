#!/usr/bin/env python3
"""Verify the retired 0008 contract in source snapshots, without resetting a checkout."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent


def git(repo, *args, env=None):
    return subprocess.check_output(["git", "-C", str(repo), *args], env=env)


def archive(repo, revision, destination):
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryFile() as stream:
        subprocess.run(["git", "-C", str(repo), "archive", revision], stdout=stream, check=True)
        stream.seek(0)
        subprocess.run(["tar", "-xf", "-", "-C", str(destination)], stdin=stream, check=True)


def replay(repo, revision, patches, destination=None):
    with tempfile.TemporaryDirectory(prefix="disc-retirement-index-") as temporary:
        env = os.environ | {"GIT_INDEX_FILE": str(Path(temporary) / "index")}
        git(repo, "read-tree", revision, env=env)
        for patch in patches:
            git(repo, "apply", "--cached", "--whitespace=error-all", str(patch), env=env)
        tree = git(repo, "write-tree", env=env).decode().strip()
        if destination is not None:
            destination.mkdir(parents=True, exist_ok=True)
            git(repo, "checkout-index", "--all", "--force", "--prefix=" + str(destination) + "/", env=env)
        return tree


def run_logged(command, log, cwd):
    print("Running: " + " ".join(command), flush=True)
    with log.open("w") as output:
        result = subprocess.run(command, cwd=cwd, stdout=output, stderr=subprocess.STDOUT)
    print(f"exit={result.returncode} log={log}", flush=True)
    result.check_returncode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--resume", action="store_true", help="Refresh this runner's existing snapshot and retain build caches")
    args = parser.parse_args()
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=args.resume)
    pins = dict(line.split("=", 1) for line in (ROOT / "Versions.env").read_text().splitlines()
                if line and not line.startswith("#"))
    if args.resume:
        previous = json.loads((output / "proof.json").read_text())
        if previous["pins"] != pins or previous["hybridCommit"] != git(ROOT, "rev-parse", "HEAD").decode().strip():
            raise SystemExit("The existing snapshot belongs to different source pins; use a new output directory")
    subprocess.run(["shasum", "-a", "256", "-c", "Patches/manifest.sha256"], cwd=ROOT, check=True)
    series = {}
    for name in ["AetherEngine", "FFmpegBuild"]:
        series[name] = [ROOT / "Patches" / name / line.strip()
                        for line in (ROOT / "Patches" / name / "series").read_text().splitlines()
                        if line.strip() and not line.startswith("#")]
    retired = ROOT / "Patches/AetherEngine/0008-http-disc-mime-recognition.patch"
    if retired.exists() or retired in series["AetherEngine"]:
        raise SystemExit("0008 is still active; retire its file and series entry first")

    package = output / "candidate/SyncnextHybrid"
    archive(ROOT, "HEAD", package)
    shutil.rmtree(package / "Patches")
    shutil.copytree(ROOT / "Patches", package / "Patches")
    shutil.copy2(ROOT / "Versions.env", package / "Versions.env")
    proof = {"hybridCommit": git(ROOT, "rev-parse", "HEAD").decode().strip(),
             "scope": "Committed Hybrid code, current remaining patches, root-owned test overlays",
             "pins": pins, "repositories": {}}
    for name, key in [("AetherEngine", "AETHERENGINE"), ("FFmpegBuild", "FFMPEGBUILD")]:
        source = ROOT / name
        target = package / name
        if target.exists() and not args.resume:
            target.rmdir()  # git archive materializes gitlinks as empty directories
        revision = pins[key + "_COMMIT"]
        first = replay(source, revision, series[name], target)
        second = replay(source, revision, series[name])
        if first != second:
            raise SystemExit(f"{name}: patch replays differ")
        proof["repositories"][name] = {"commit": revision, "tree": first,
                                      "replayMatches": True,
                                      "patches": [p.name for p in series[name]]}

    tests = package / "AetherEngine/Tests/AetherEngineTests"
    for source in sorted((ROOT / "Tests/UpstreamDiscRetirement").glob("*.swift")):
        relative = "Support/KeepAliveRangeOrigin.swift" if source.name == "KeepAliveRangeOrigin.swift" else source.name
        shutil.copy2(source, tests / relative)
    demuxer = package / "AetherEngine/Sources/AetherEngine/Demuxer/Demuxer.swift"
    proof["demuxerSHA256"] = hashlib.sha256(demuxer.read_bytes()).hexdigest()
    proof["testOverlays"] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                             for p in (ROOT / "Tests/UpstreamDiscRetirement").glob("*.swift")}
    (output / "proof.json").write_text(json.dumps(proof, indent=2) + "\n")
    run_logged(["swift", "test", "--package-path", "AetherEngine", "--filter",
                "HTTPDiscRetirementTests|DiscImageMediaTypeTests|ExtensionlessDiscImageTests|"
                "HTTPDiscIOReaderTests|RemoteDiscSessionReleaseTests|CancellableLoadTests"],
               output / "disc-tests.log", package)
    run_logged(["swift", "test"], output / "hybrid-tests.log", package)
    proof["discTestsPassed"] = True
    proof["hybridTestsPassed"] = True
    (output / "proof.json").write_text(json.dumps(proof, indent=2) + "\n")
    print(json.dumps(proof, indent=2), flush=True)


if __name__ == "__main__":
    main()
