"""Offline test for scripts/assemble-release.py.

Builds a complete fake CI artifact tree, runs the assembler, and checks the
published names, checksums, notes and failure paths. Stdlib only; runs in the
Ubuntu CI job so a tag never reaches a broken release step.

python3 scripts/test-assemble-release.py
"""

import hashlib
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ASSEMBLE = ROOT / 'scripts/assemble-release.py'


def version():
    text = (ROOT / 'pubspec.yaml').read_text(encoding='utf-8')
    match = re.search(r'(?m)^version:\s*([^+\s]+)\+\d+\s*$', text)
    assert match, 'pubspec.yaml has no version'
    return match.group(1)


def touch(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)


def build_fixture(root, v):
    artifacts = root / 'artifacts'

    def platform(name):
        return artifacts / name / 'dist'

    windows = platform('aster-desktop-windows-2022')
    touch(windows / f'Aster-Desktop-{v}-windows-x64-setup.exe', b'installer')
    touch(windows / f'Aster-Desktop-{v}-windows-x64-portable.zip', b'portable')
    touch(windows / f'Aster-Desktop-{v}-source.tar.gz', b'source tar')
    touch(windows / f'Aster-Desktop-{v}-source.zip', b'source zip')
    touch(windows / 'Aster-Core-a9a33503-source.tar.gz', b'core tar')
    touch(windows / 'Aster-Core-a9a33503-source.zip', b'core zip')
    touch(windows / 'checksums.txt', b'ignored')

    ubuntu = platform('aster-desktop-ubuntu-24.04')
    touch(ubuntu / f'Aster-Desktop-{v}-linux-x64.deb', b'deb')
    touch(
        ubuntu / f'Aster-Desktop-{v}-linux-ubuntu-24.04-x64-portable.tar.gz',
        b'linux portable',
    )
    touch(ubuntu / f'Aster-Desktop-{v}-source.tar.gz', b'source tar on linux')
    touch(ubuntu / 'checksums.txt', b'ignored')

    touch(
        platform('aster-desktop-macos-15') / f'Aster-Desktop-{v}-macos-arm64.dmg',
        b'arm dmg',
    )
    touch(
        platform('aster-desktop-macos-15-intel')
        / f'Aster-Desktop-{v}-macos-amd64.dmg',
        b'intel dmg',
    )

    android = artifacts / 'aster-android'
    touch(android / f'Aster-Desktop-{v}-android.apk', b'apk')
    touch(android / 'apk-signing.txt', b'signing')
    touch(android / 'checksums.txt', b'ignored')

    ios = artifacts / 'aster-ios-unsigned'
    touch(ios / 'Aster-iOS-unsigned.zip', b'ios')
    touch(
        ios / 'ios-checksums.txt',
        (
            'engine sha256 deadbeef\n'
            f'{hashlib.sha256(b"ios").hexdigest()}  build/Aster-iOS-unsigned.zip\n'
        ).encode(),
    )

    out = root / 'out'
    meta = root / 'meta'
    touch(out / f'Aster-Desktop-{v}-docs.zip', b'docs')
    return artifacts, out, meta


def run(version, artifacts, out, meta):
    return subprocess.run(
        [
            sys.executable,
            str(ASSEMBLE),
            '--version',
            version,
            '--artifacts',
            str(artifacts),
            '--output',
            str(out),
            '--meta',
            str(meta),
        ],
        capture_output=True,
        text=True,
        encoding='utf-8',
    )


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check(condition, message):
    if not condition:
        raise SystemExit('FAIL: ' + message)


def main():
    v = version()
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        artifacts, out, meta = build_fixture(root, v)
        result = run(v, artifacts, out, meta)
        check(result.returncode == 0, result.stderr or result.stdout)

        names = {path.name for path in out.iterdir()}
        expected = {
            f'Aster-Desktop-{v}-windows-x64-setup.exe',
            f'Aster-Desktop-{v}-windows-x64-portable.zip',
            f'Aster-Desktop-{v}-macos-arm64.dmg',
            f'Aster-Desktop-{v}-macos-amd64.dmg',
            f'Aster-Desktop-{v}-linux-x64.deb',
            f'Aster-Desktop-{v}-linux-ubuntu-24.04-x64-portable.tar.gz',
            f'Aster-Desktop-{v}-android.apk',
            f'Aster-Desktop-{v}-android-apk-signing.txt',
            f'Aster-Desktop-{v}-ios-unsigned.zip',
            f'Aster-Desktop-{v}-ios-checksums.txt',
            f'Aster-Desktop-{v}-source.tar.gz',
            f'Aster-Desktop-{v}-source.zip',
            'Aster-Core-a9a33503-source.tar.gz',
            'Aster-Core-a9a33503-source.zip',
            f'Aster-Desktop-{v}-docs.zip',
            'SHA256SUMS',
        }
        check(names == expected, f'unexpected output set: {sorted(names)}')

        check(
            b'\r' not in (out / 'SHA256SUMS').read_bytes(),
            'SHA256SUMS must use LF so sha256sum -c works',
        )
        checksums = (out / 'SHA256SUMS').read_text(encoding='utf-8').splitlines()
        check(len(checksums) == len(expected) - 1, 'checksum count is wrong')
        for line in checksums:
            digest, name = line.split('  ', 1)
            check(
                sha256(out / name) == digest,
                f'checksum does not match {name}',
            )
        check(
            (out / f'Aster-Desktop-{v}-source.tar.gz').read_bytes()
            == b'source tar on linux',
            'the first source archive (sorted by runner) was not kept',
        )

        ios_checksums_path = out / f'Aster-Desktop-{v}-ios-checksums.txt'
        check(
            b'\r' not in ios_checksums_path.read_bytes(),
            'the iOS checksums must use LF so shasum -c works',
        )
        ios_checksums = ios_checksums_path.read_text(encoding='utf-8')
        check(
            ios_checksums
            == '# engine sha256 deadbeef\n'
            f'{hashlib.sha256(b"ios").hexdigest()}  '
            f'Aster-Desktop-{v}-ios-unsigned.zip\n',
            f'iOS checksums were not rewritten for the release: {ios_checksums}',
        )

        changelog = (ROOT / 'CHANGELOG.md').read_text(encoding='utf-8')
        heading = re.search(rf'(?m)^## {re.escape(v)} — (.+)$', changelog)
        check(heading is not None, 'CHANGELOG section is missing')
        parts = [part.strip() for part in heading.group(1).split(' — ')]
        tagline = ' — '.join(parts[1:])
        section = changelog[heading.end():]
        end = re.search(r'(?m)^## ', section)
        following = section[end.start():] if end else ''
        section = section[:end.start()] if end else section
        bullets = [line for line in section.splitlines() if line.strip()]
        title = (meta / 'release-title.txt').read_text(encoding='utf-8').strip()
        check(
            title == f'Aster Desktop {v} — {tagline}',
            f'title does not match the CHANGELOG tagline: {title}',
        )
        check(
            re.search(r'\d{4}-\d{2}-\d{2}', title) is None,
            f'the release title leaked the CHANGELOG date: {title}',
        )
        notes = (meta / 'release-notes.md').read_text(encoding='utf-8')
        for bullet in bullets:
            check(bullet in notes, f'notes lost the CHANGELOG line: {bullet}')
        for line in [line for line in following.splitlines() if line.strip()][1:2]:
            check(
                line not in notes,
                f'notes leaked the next CHANGELOG section: {line}',
            )
        for name in expected - {'SHA256SUMS'}:
            check(name in notes, f'notes do not link {name}')
        check('iOS' in notes and 'Arch' in notes, 'platform notes are missing')

        missing = root / 'missing'
        os.replace(artifacts, missing)
        broken = missing / 'aster-android' / f'Aster-Desktop-{v}-android.apk'
        broken.unlink()
        result = run(v, missing, root / 'missing-out', root / 'missing-meta')
        check(result.returncode != 0, 'a missing platform must fail')
        check('android-apk' in result.stderr, result.stderr)

        touch(broken, b'apk')
        wrong = root / 'wrong'
        os.replace(missing, wrong)
        touch(
            wrong / 'aster-desktop-ubuntu-24.04' / 'dist' / 'Aster-Desktop-0.0.1-linux-x64.deb',
            b'old',
        )
        result = run(v, wrong, root / 'wrong-out', root / 'wrong-meta')
        check(result.returncode != 0, 'a foreign version must fail')
        check('expected ' + v in result.stderr, result.stderr)

        (
            wrong
            / 'aster-desktop-ubuntu-24.04'
            / 'dist'
            / 'Aster-Desktop-0.0.1-linux-x64.deb'
        ).unlink()
        touch(wrong / 'aster-android' / 'surprise.txt', b'?')
        result = run(v, wrong, root / 'surprise-out', root / 'surprise-meta')
        check(result.returncode != 0, 'an unexpected artifact must fail')
        check('unexpected release artifact' in result.stderr, result.stderr)

    print('PASS: release assembly, checksums, notes and failure paths')


if __name__ == '__main__':
    main()
