"""Collect CI artifacts into one GitHub release with checksums and notes.

Every platform job uploads its own artifact directory, so shared files such as
the source archives appear more than once. This script keeps one copy of each,
rejects packages built for another version, writes SHA256SUMS and renders the
release notes from the CHANGELOG section of the tagged version.

python scripts/assemble-release.py --version 0.4.0 \
  --artifacts release-assets --output release --meta .build/release-meta
"""

import argparse
import hashlib
import os
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# key, pattern, required, output name template
ASSETS = [
    ('windows-setup', r'^Aster-Desktop-(?P<v>[^+\s]+)-windows-x64-setup\.exe$', True, '{name}'),
    ('windows-portable', r'^Aster-Desktop-(?P<v>[^+\s]+)-windows-x64-portable\.zip$', True, '{name}'),
    ('macos-arm64', r'^Aster-Desktop-(?P<v>[^+\s]+)-macos-arm64\.dmg$', True, '{name}'),
    ('macos-amd64', r'^Aster-Desktop-(?P<v>[^+\s]+)-macos-amd64\.dmg$', True, '{name}'),
    ('ubuntu-deb', r'^Aster-Desktop-(?P<v>[^+\s]+)-linux-x64\.deb$', True, '{name}'),
    ('ubuntu-portable', r'^Aster-Desktop-(?P<v>[^+\s]+)-linux-ubuntu-24\.04-x64-portable\.tar\.gz$', True, '{name}'),
    ('arch-package', r'^Aster-Desktop-(?P<v>[^+\s]+)-linux-x64\.pkg\.tar\.zst$', False, '{name}'),
    ('arch-portable', r'^Aster-Desktop-(?P<v>[^+\s]+)-linux-arch-x64-portable\.tar\.gz$', False, '{name}'),
    ('android-apk', r'^Aster-Desktop-(?P<v>[^+\s]+)-android\.apk$', True, '{name}'),
    ('android-signing', r'^apk-signing\.txt$', True, 'Aster-Desktop-{version}-android-apk-signing.txt'),
    ('ios-unsigned', r'^Aster-iOS-unsigned\.zip$', True, 'Aster-Desktop-{version}-ios-unsigned.zip'),
    ('ios-checksums', r'^ios-checksums\.txt$', False, 'Aster-Desktop-{version}-ios-checksums.txt'),
    ('desktop-source-tar', r'^Aster-Desktop-(?P<v>[^+\s]+)-source\.tar\.gz$', True, '{name}'),
    ('desktop-source-zip', r'^Aster-Desktop-(?P<v>[^+\s]+)-source\.zip$', True, '{name}'),
    ('core-source-tar', r'^Aster-Core-[0-9a-f]+-source\.tar\.gz$', True, '{name}'),
    ('core-source-zip', r'^Aster-Core-[0-9a-f]+-source\.zip$', True, '{name}'),
]

IGNORED = {'checksums.txt'}


def digest(path):
    sha = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            sha.update(chunk)
    return sha.hexdigest()


IOS_CHECKSUM = re.compile(r'([0-9a-f]{64})  build/Aster-iOS-unsigned\.zip$')


def write_ios_checksums(source, destination, version):
    """Rewrite the CI checksum file for the renamed archive.

    The job hashes build/Aster-iOS-unsigned.zip; publishing that path would
    make `shasum -c` fail. Keep the engine note as a comment so the file stays
    a valid checksum list.
    """
    digest = None
    engine = None
    for line in source.read_text(encoding='utf-8').splitlines():
        if line.startswith('engine sha256 '):
            engine = line
            continue
        match = IOS_CHECKSUM.fullmatch(line.strip())
        if match:
            digest = match.group(1)
    if digest is None:
        raise SystemExit(f'{source} does not checksum the iOS archive')
    lines = []
    if engine:
        lines.append('# ' + engine)
    lines.append(f'{digest}  Aster-Desktop-{version}-ios-unsigned.zip')
    destination.write_text(
        '\n'.join(lines) + '\n', encoding='utf-8', newline='\n'
    )


def changelog_section(version):
    text = (ROOT / 'CHANGELOG.md').read_text(encoding='utf-8')
    heading = re.search(rf'(?m)^## {re.escape(version)} — (.+)$', text)
    if not heading:
        raise SystemExit(f'CHANGELOG.md has no section for {version}')
    start = heading.end()
    end = re.search(r'(?m)^## ', text[start:])
    body = text[start:start + end.start() if end else len(text)]
    bullets = [line for line in body.splitlines() if line.strip()]
    if not bullets:
        raise SystemExit(f'CHANGELOG.md section for {version} is empty')
    parts = [part.strip() for part in heading.group(1).split(' — ')]
    # "0.4.0 — 2026-11-22 — iOS 客戶端基礎" names the release after the date.
    tagline = ' — '.join(parts[1:]) if len(parts) > 1 else ''
    return tagline, bullets


def collect(artifacts, version):
    groups = {key: [] for key, *_ in ASSETS}
    for path in sorted(artifacts.rglob('*')):
        if not path.is_file():
            continue
        if path.name in IGNORED:
            continue
        for key, pattern, _required, _template in ASSETS:
            match = re.fullmatch(pattern, path.name)
            if not match:
                continue
            built = match.groupdict().get('v')
            if built is not None and built != version:
                raise SystemExit(
                    f'{path} was built for {built}, expected {version}'
                )
            groups[key].append(path)
            break
        else:
            raise SystemExit(f'unexpected release artifact: {path}')
    for key, _pattern, required, _template in ASSETS:
        if required and not groups[key]:
            raise SystemExit(f'missing release artifact: {key}')
    return groups


def copy_assets(groups, output, version):
    output.mkdir(parents=True, exist_ok=True)
    copied = {}
    for key, _pattern, _required, template in ASSETS:
        paths = groups[key]
        if not paths:
            continue
        digests = {digest(path) for path in paths}
        if len(digests) > 1:
            print(
                f'warning: {key} was built differently on each runner; '
                f'keeping {paths[0].name}',
                file=sys.stderr,
            )
        source = paths[0]
        destination = output / template.format(
            name=source.name, version=version
        )
        if key == 'ios-checksums':
            write_ios_checksums(source, destination, version)
        else:
            shutil.copyfile(source, destination)
        copied[key] = destination.name
    return copied


def write_checksums(output):
    lines = []
    for path in sorted(output.iterdir()):
        if path.is_file() and path.name != 'SHA256SUMS':
            lines.append(f'{digest(path)}  {path.name}')
    (output / 'SHA256SUMS').write_text(
        '\n'.join(lines) + '\n', encoding='utf-8', newline='\n'
    )


def write_notes(copied, meta, version, repo):
    tagline, bullets = changelog_section(version)
    title = f'Aster Desktop {version}' + (f' — {tagline}' if tagline else '')
    base = f'https://github.com/{repo}/releases/download/v{version}'
    link = lambda name: f'[{name}]({base}/{name})'
    rows = [
        (
            'Windows 10／11 x64',
            ' · '.join(
                x for x in (
                    copied.get('windows-setup') and
                    f'[安裝器]({base}/{copied["windows-setup"]})',
                    copied.get('windows-portable') and
                    f'[可攜版]({base}/{copied["windows-portable"]})',
                ) if x
            ),
        ),
        ('macOS 13+ Apple Silicon', f'[DMG]({base}/{copied["macos-arm64"]})'),
        ('macOS 13+ Intel', f'[DMG]({base}/{copied["macos-amd64"]})'),
        (
            'Ubuntu 24.04 x64',
            ' · '.join(
                x for x in (
                    copied.get('ubuntu-deb') and
                    f'[deb]({base}/{copied["ubuntu-deb"]})',
                    copied.get('ubuntu-portable') and
                    f'[可攜版]({base}/{copied["ubuntu-portable"]})',
                ) if x
            ),
        ),
    ]
    if copied.get('arch-package') or copied.get('arch-portable'):
        rows.append(
            (
                'Arch Linux x64',
                ' · '.join(
                    x for x in (
                        copied.get('arch-package') and
                        f'[套件]({base}/{copied["arch-package"]})',
                        copied.get('arch-portable') and
                        f'[可攜版]({base}/{copied["arch-portable"]})',
                    ) if x
                ),
            )
        )
    rows.append(
        (
            'Android arm64／x86_64',
            f'[APK]({base}/{copied["android-apk"]})'
            f' · [簽章資訊]({base}/{copied["android-signing"]})',
        )
    )
    rows.append(
        (
            'iOS（未簽章）',
            f'[zip]({base}/{copied["ios-unsigned"]})'
            + (
                f' · [建置校驗]({base}/{copied["ios-checksums"]})'
                if copied.get('ios-checksums')
                else ''
            ),
        )
    )
    downloads = '\n'.join(f'| {name} | {value} |' for name, value in rows)
    extras = [link(copied['desktop-source-tar']), link(copied['desktop-source-zip'])]
    extras += [link(copied['core-source-tar']), link(copied['core-source-zip'])]
    if copied.get('docs'):
        extras.insert(0, link(copied['docs']))

    notes = (
        f'# {title}\n\n'
        + '\n'.join(bullets)
        + '\n\n## 下載\n\n'
        '| 平台 | 檔案 |\n| --- | --- |\n'
        + downloads
        + '\n\n離線文件與來源碼：'
        + ' · '.join(extras)
        + '\n\n'
        '## 平台說明\n\n'
        '- **iOS** 產物是未簽章的 CI 建置，只供編譯與結構檢查，不能直接安裝在一般 iPhone；'
        'TestFlight、Ad Hoc IPA、NetworkExtension 實機授權與 App Store 發佈需要能使用'
        '完整 NetworkExtension capability 的付費 Apple Developer Program 簽章設定。\n'
        '- **macOS** DMG 由 CI 以本機簽署建置，尚未取得 Apple Developer ID 簽章／公證；'
        '首次開啟可能需要在「系統設定 → 隱私權與安全性」允許。\n'
        '- **Arch Linux** 套件需要 Arch 原生依賴，無法在 Ubuntu CI runner 產生；'
        '本版未包含 Arch 套件，需要者請依 `docs/BUILDING.md` 在 Arch 上建置。\n\n'
        '## 來源與校驗\n\n'
        f'- 本版執行程式來源為 tag `v{version}`，內附核心與轉換器固定於 '
        '`a9a33503b39a03681bc52d9758907316a22df199`。\n'
        '- 下載 `SHA256SUMS` 後，以 `sha256sum -c SHA256SUMS`（macOS：`shasum -a 256 -c`）'
        '核對全部檔案。\n'
        '- GPL-3.0 與第三方聲明見 `NOTICE.md`；對應桌面與核心來源包一併提供。\n'
    )
    meta.mkdir(parents=True, exist_ok=True)
    (meta / 'release-title.txt').write_text(
        f'{title}\n', encoding='utf-8', newline='\n'
    )
    (meta / 'release-notes.md').write_text(
        notes, encoding='utf-8', newline='\n'
    )
    return title


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--meta', type=Path, default=ROOT / '.build/release-meta')
    parser.add_argument(
        '--repo',
        default=os.environ.get('GITHUB_REPOSITORY', 'Miku0139oao/aster-desktop'),
    )
    args = parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
        parser.error('Version must contain major.minor.patch')
    if not args.artifacts.is_dir():
        parser.error(f'{args.artifacts} is not a directory')

    groups = collect(args.artifacts, args.version)
    copied = copy_assets(groups, args.output, args.version)
    docs = args.output / f'Aster-Desktop-{args.version}-docs.zip'
    if docs.is_file():
        copied['docs'] = docs.name
    else:
        print('warning: the offline manual archive is missing', file=sys.stderr)
    write_checksums(args.output)
    write_notes(copied, args.meta, args.version, args.repo)
    print(f'Collected {len(copied)} release assets for {args.version}')


if __name__ == '__main__':
    main()
