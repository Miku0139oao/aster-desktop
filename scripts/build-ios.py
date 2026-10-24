#!/usr/bin/env python3
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys


def run(command, *, cwd=None, capture=False):
    print("+", " ".join(str(value) for value in command), flush=True)
    return subprocess.run(
        [str(value) for value in command],
        cwd=cwd,
        check=True,
        capture_output=capture,
        text=True,
    )


def main():
    parser = argparse.ArgumentParser(description="Build the Aster iOS XCFramework and app")
    parser.add_argument("--skip-app", action="store_true")
    options = parser.parse_args()

    project = Path(__file__).resolve().parents[1]
    bridge = project / "bridge"
    output = project / "ios" / "mobileapi.xcframework"
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        shutil.rmtree(output)

    go = os.environ.get("ASTER_GO", "go")
    go_bin = Path(run([go, "env", "GOPATH"], capture=True).stdout.strip()) / "bin"
    gomobile = Path(os.environ.get("ASTER_GOMOBILE", go_bin / "gomobile"))
    if not gomobile.exists():
        mobile_version = "v0.0.0-20261011034528-197770444867"
        run([go, "install", "golang.org/x/mobile/cmd/gomobile@" + mobile_version], cwd=bridge)
        run([go, "install", "golang.org/x/mobile/cmd/gobind@" + mobile_version], cwd=bridge)
    run([gomobile, "init"], cwd=bridge)
    run(
        [
            gomobile,
            "bind",
            "-target=ios/arm64,iossimulator/arm64,iossimulator/amd64",
            "-tags",
            "with_gvisor",
            "-o",
            output,
            "./mobileapi",
        ],
        cwd=bridge,
    )
    run(["ruby", project / "scripts/configure-ios.rb"], cwd=project)

    digest = hashlib.sha256()
    for path in sorted(output.rglob("*")):
        if path.is_file():
            digest.update(path.relative_to(output).as_posix().encode())
            digest.update(path.read_bytes())
    (project / "ios" / "mobileapi.xcframework.sha256").write_text(
        digest.hexdigest() + "\n",
        encoding="utf-8",
    )

    if not options.skip_app:
        run(
            [os.environ.get("ASTER_FLUTTER", "flutter"), "build", "ios", "--release", "--no-codesign"],
            cwd=project,
        )
    print(f"iOS engine binding: {output}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
