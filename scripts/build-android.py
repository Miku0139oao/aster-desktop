#!/usr/bin/env python3
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys


ABIS = {
    "arm64-v8a": ("arm64", ""),
    "x86_64": ("amd64", ""),
}


def run(command, *, cwd=None, env=None, capture=False):
    print("+", " ".join(str(value) for value in command), flush=True)
    merged_env = os.environ.copy()
    if env:
        merged_env.update({key: str(value) for key, value in env.items()})
    return subprocess.run(
        [str(value) for value in command],
        cwd=cwd,
        env=merged_env,
        check=True,
        capture_output=capture,
        text=True,
    )


def core_source(bridge_dir):
    result = run(
        ["go", "list", "-m", "-f", "{{.Dir}}", "github.com/Miku0139oao/aster-core"],
        cwd=bridge_dir,
        capture=True,
    )
    path = Path(result.stdout.strip())
    if not path.is_dir():
        raise RuntimeError(f"Aster Core source is unavailable: {path}")
    return path


def write_checksum(root):
    lines = []
    for path in sorted(root.rglob("*.so")):
        if path.is_file():
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            lines.append(f"{digest}  {path.relative_to(root).as_posix()}")
    (root / "checksums.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="Build native Android engines and the Flutter APK")
    parser.add_argument("--abis", default="arm64-v8a,x86_64")
    parser.add_argument("--out", default="build/android")
    options = parser.parse_args()

    project = Path(__file__).resolve().parents[1]
    bridge = project / "bridge"
    output = project / options.out
    libraries = output / "jniLibs"
    if libraries.exists():
        import shutil

        shutil.rmtree(libraries)

    go = os.environ.get("ASTER_GO", "go")
    core_dir = core_source(bridge)
    ldflags = (
        '-X "github.com/Miku0139oao/aster-core/constant.Version=android-a9a33503" '
        '-X "github.com/Miku0139oao/aster-core/constant.BuildTime=1970-01-01T00:00:00Z" '
        '-X "github.com/Miku0139oao/aster-core/constant.ReleaseAsset=aster-core-android" -w -s -buildid='
    )

    for abi in [value.strip() for value in options.abis.split(",") if value.strip()]:
        try:
            goarch, _ = ABIS[abi]
        except KeyError:
            raise SystemExit(f"Unsupported Android ABI: {abi}")
        target = libraries / abi
        target.mkdir(parents=True, exist_ok=True)
        env = {"GOOS": "android", "GOARCH": goarch, "CGO_ENABLED": "0"}
        run(
            [go, "build", "-tags", "with_gvisor", "-trimpath", f"-ldflags={ldflags}", "-o", target / "libaster_core.so", "."],
            cwd=core_dir,
            env=env,
        )
        run(
            [go, "build", "-tags", "with_gvisor", "-trimpath", "-o", target / "libaster_bridge.so", "./cmd/aster-bridge"],
            cwd=bridge,
            env=env,
        )

    write_checksum(libraries)
    run([os.environ.get("ASTER_FLUTTER", "flutter"), "build", "apk", "--release", "--split-per-abi"], cwd=project)
    print(f"Android engine libraries: {libraries}")
    print(f"APK output: {project / 'build/app/outputs/flutter-apk'}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
