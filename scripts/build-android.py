#!/usr/bin/env python3
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile


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


def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_checksum(root, extra=()):
    lines = []
    for path in [*sorted(root.rglob("*.aar")), *extra]:
        if path.is_file():
            digest = file_digest(path)
            lines.append(f"{digest}  {path.relative_to(root).as_posix()}")
    (root / "checksums.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def verify_apk(path):
    if not path.exists():
        raise RuntimeError(f"APK was not produced at {path}")
    with zipfile.ZipFile(path) as archive:
        names = set(archive.namelist())
    abis = {
        name.split("/")[1]
        for name in names
        if name.startswith("lib/") and name.count("/") >= 2
    }
    expected = {"arm64-v8a", "x86_64"}
    if abis != expected:
        found = ", ".join(sorted(abis)) or "none"
        raise RuntimeError(
            f"APK contains {found}; expected only {', '.join(sorted(expected))}"
        )
    for abi in sorted(expected):
        if f"lib/{abi}/libgojni.so" not in names:
            raise RuntimeError(f"APK is missing lib/{abi}/libgojni.so")


def main():
    parser = argparse.ArgumentParser(description="Build the Android engine binding and Flutter APK")
    parser.add_argument("--skip-apk", action="store_true")
    parser.add_argument("--out", default="build/android")
    options = parser.parse_args()

    project = Path(__file__).resolve().parents[1]
    version_match = re.search(
        r"^version:\s*([^+\s]+)\+\d+",
        (project / "pubspec.yaml").read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    if not version_match:
        raise RuntimeError("pubspec.yaml has no build version")
    release_version = version_match.group(1)
    published_apk_name = f"Aster-Desktop-{release_version}-android.apk"
    bridge = project / "bridge"
    output = project / options.out
    libraries = output / "app"
    if libraries.exists():
        shutil.rmtree(libraries)
    libraries.mkdir(parents=True)
    go_bin = Path(run([os.environ.get("ASTER_GO", "go"), "env", "GOPATH"], capture=True).stdout.strip()) / "bin"
    gomobile = Path(os.environ.get("ASTER_GOMOBILE", go_bin / ("gomobile.exe" if os.name == "nt" else "gomobile")))
    if not gomobile.exists():
        go = os.environ.get("ASTER_GO", "go")
        mobile_version = "v0.0.0-20261011034528-197770444867"
        run([go, "install", "golang.org/x/mobile/cmd/gomobile@" + mobile_version], cwd=bridge)
        run([go, "install", "golang.org/x/mobile/cmd/gobind@" + mobile_version], cwd=bridge)
    run([gomobile, "init"], cwd=bridge)
    run(
        [
            gomobile,
            "bind",
            "-target=android/arm64,android/amd64",
            "-androidapi",
            "24",
            # cmfa disables the core's /data/system/packages.xml lookup, which a
            # normal Android app cannot read. VpnService.Builder owns per-app
            # routing; the core only receives include/exclude lists for its
            # embedded TUN configuration.
            "-tags",
            "with_gvisor cmfa",
            "-trimpath",
            "-ldflags=-s -w",
            "-o",
            libraries / "mobileapi.aar",
            "./mobileapi",
        ],
        cwd=bridge,
    )
    app_libraries = project / "android/app/libs"
    app_libraries.mkdir(parents=True, exist_ok=True)

    shutil.copy2(libraries / "mobileapi.aar", app_libraries / "mobileapi.aar")
    with zipfile.ZipFile(app_libraries / "mobileapi.aar") as archive:
        names = set(archive.namelist())
        for required in (
            "classes.jar",
            "jni/arm64-v8a/libgojni.so",
            "jni/x86_64/libgojni.so",
        ):
            if required not in names:
                raise RuntimeError(f"mobile AAR is missing {required}")

    if not options.skip_apk:
        run(
            [
                os.environ.get("ASTER_FLUTTER", "flutter"),
                "build",
                "apk",
                "--release",
                # Keep Flutter from adding an armeabi-v7a libapp.so that has no
                # matching libgojni.so; the Go engine only targets 64-bit ABIs.
                "--target-platform",
                "android-arm64,android-x64",
            ],
            cwd=project,
        )
        built_apk = project / "build/app/outputs/flutter-apk/app-release.apk"
        verify_apk(built_apk)
        published_apk = output / published_apk_name
        shutil.copy2(built_apk, published_apk)
    write_checksum(
        output,
        extra=[output / published_apk_name]
        if not options.skip_apk
        else [],
    )
    print(f"Android engine binding: {app_libraries / 'mobileapi.aar'}")
    if not options.skip_apk:
        print(f"APK output: {output / published_apk_name}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
