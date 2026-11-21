#!/usr/bin/env python3
"""Fail release builds when Android falls back to Flutter's template icon."""

from __future__ import annotations

import hashlib
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "android/app/src/main/res"
EXPECTED = {
    "mdpi": (48, "02c2b03ff7c370fedd5aba3dddeb305187d802b2709ae4ca37f27f6e31426f2a"),
    "hdpi": (72, "def45fb69d4c2875caf0af63e4c3c5772d9b8826e273012f03d27e7c40c963ef"),
    "xhdpi": (96, "8047231a3456e02dd7e319f83fcf4c6ac911a11875532b38c49f4d4bf40698bc"),
    "xxhdpi": (144, "c27eec3e9dae19c7ce6fd4e66e16783495ff7b2b871edbb72ac5969de08c59b2"),
    "xxxhdpi": (192, "83f64d9237dc925938e5678b2673673101589b6e77eb1fbe025aa6b9f25fee61"),
}


def fail(message: str) -> None:
    raise SystemExit(f"Android icon check failed: {message}")


def check_png(path: Path, size: int, digest: str) -> None:
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n") or data[12:16] != b"IHDR":
        fail(f"{path.relative_to(ROOT)} is not a PNG")
    width, height = struct.unpack(">II", data[16:24])
    if (width, height) != (size, size):
        fail(
            f"{path.relative_to(ROOT)} is {width}x{height}; expected {size}x{size}"
        )
    actual = hashlib.sha256(data).hexdigest()
    if actual != digest:
        fail(
            f"{path.relative_to(ROOT)} is not the generated Aster icon "
            f"(SHA-256 {actual})"
        )


for density, (size, digest) in EXPECTED.items():
    for name in ("ic_launcher.png", "ic_launcher_round.png"):
        check_png(RES / f"mipmap-{density}/{name}", size, digest)

manifest = (ROOT / "android/app/src/main/AndroidManifest.xml").read_text(
    encoding="utf-8"
)
for attribute in (
    'android:icon="@mipmap/ic_launcher"',
    'android:roundIcon="@mipmap/ic_launcher_round"',
):
    if attribute not in manifest:
        fail(f"AndroidManifest.xml is missing {attribute}")

for version in (26, 33):
    for name in ("ic_launcher.xml", "ic_launcher_round.xml"):
        path = RES / f"mipmap-anydpi-v{version}/{name}"
        text = path.read_text(encoding="utf-8")
        for resource in (
            "@color/ic_launcher_background",
            "@drawable/ic_launcher_foreground",
        ):
            if resource not in text:
                fail(f"{path.relative_to(ROOT)} is missing {resource}")
        if version == 33 and "@drawable/ic_launcher_monochrome" not in text:
            fail(f"{path.relative_to(ROOT)} is missing the monochrome icon")

print("Android Aster launcher and adaptive icons are valid.")
