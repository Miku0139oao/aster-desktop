"""Build an offline HTML/Markdown manual; never changes release binaries.

python -m pip install -r scripts/docs-requirements.txt
python scripts/package-docs.py --version 0.2.3 --output .build/public-0.2.3
"""

import argparse
import html
import re
import unicodedata
import zipfile
from pathlib import Path

import markdown

ROOT = Path(__file__).resolve().parents[1]
PAGES = {
    'README.md': ('index.html', '下載與快速入門'),
    'docs/USER_GUIDE.md': ('docs/USER_GUIDE.html', '完整使用手冊'),
    'docs/FAQ.md': ('docs/FAQ.html', '常見問題'),
    'docs/APPLICATION_ROUTING.md': ('docs/APPLICATION_ROUTING.html', '應用程式分流'),
    'docs/INSPECTION.md': ('docs/INSPECTION.html', '連線與日誌'),
    'CHANGELOG.md': ('CHANGELOG.html', '更新紀錄'),
    'docs/BUILDING.md': ('docs/BUILDING.html', '開發與建置'),
    'docs/ARCHITECTURE.md': ('docs/ARCHITECTURE.html', '架構與介面'),
    'docs/TESTING.md': ('docs/TESTING.html', '測試紀錄'),
    'NOTICE.md': ('NOTICE.html', '第三方聲明'),
}
CSS = '''
:root { color-scheme:light dark; --bg:#fcf8ff; --panel:#f1eaf9; --fg:#24202a; --muted:#625a70; --accent:#69489f; --border:#d9cfe4 }
@media(prefers-color-scheme:dark) { :root { --bg:#1a171e; --panel:#25202d; --fg:#eee7f5; --muted:#c8bdd5; --accent:#d3b7ff; --border:#4c4358 } }
* { box-sizing:border-box } body { margin:0; background:var(--bg); color:var(--fg); font:16px/1.85 system-ui,-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif }
header { padding:18px max(24px,calc((100vw - 1260px)/2)); background:var(--panel); border-bottom:1px solid var(--border) }
header a { text-decoration:none; font-weight:700 } header span { color:var(--muted); margin-left:18px; font-size:14px }
.layout { max-width:1308px; padding:32px 24px; margin:auto; display:grid; grid-template-columns:200px minmax(0,1fr); gap:40px }
nav { position:sticky; top:24px; align-self:start } nav a { display:block; padding:7px 12px; margin-bottom:3px; border-radius:10px; text-decoration:none } nav a[aria-current=page] { background:var(--panel); font-weight:700 }
main { min-width:0; max-width:960px } h1,h2,h3 { line-height:1.4; scroll-margin-top:24px } h1 { font-size:30px; margin-top:0 } h2 { margin-top:44px; font-size:24px; border-bottom:1px solid var(--border); padding-bottom:10px } h3 { margin-top:28px; font-size:19px }
a { color:var(--accent); text-underline-offset:3px } a:focus-visible { outline:3px solid var(--accent); outline-offset:3px } p,ul,ol { margin:16px 0 } li { margin:5px 0 }
table { border-collapse:collapse; width:100%; margin:22px 0; font-size:15px } th,td { padding:12px; border:1px solid var(--border); text-align:left; vertical-align:top; overflow-wrap:anywhere } th { background:var(--panel) }
code { font:0.9em/1.7 ui-monospace,Consolas,monospace; background:var(--panel); padding:2px 5px; border-radius:5px; overflow-wrap:anywhere } pre { padding:16px; background:var(--panel); border-radius:12px; overflow:auto } pre code { padding:0; white-space:pre; overflow-wrap:normal }
blockquote { border-left:4px solid var(--accent); margin-left:0; padding-left:20px; color:var(--muted) } footer { margin-top:48px; padding-top:16px; border-top:1px solid var(--border); color:var(--muted); font-size:14px }
@media(max-width:800px) { .layout { display:block; padding:20px 16px } nav { position:static; display:flex; flex-wrap:wrap; gap:4px; margin-bottom:28px } nav a { font-size:14px; padding:5px 9px } h1 { font-size:26px } th,td { padding:8px } header { padding:16px } header span { display:block; margin:4px 0 0 } }
@media print { nav,header { display:none } .layout { display:block; padding:0 } main { max-width:none } body { color:#000; background:#fff; font-size:11pt } h2 { break-after:avoid } a { color:inherit } }
'''


def slugify(value, separator):
    value = unicodedata.normalize('NFC', value).lower()
    value = re.sub(r'[^\w\s-]', '', value)
    return re.sub(r'\s', separator, value).strip(separator)


def local_links(source, rendered):
    def replace(match):
        value = html.unescape(match.group(1))
        path, sep, fragment = value.partition('#')
        if not path or re.match(r'[a-z][a-z0-9+.-]*:', path, re.I):
            return match.group(0)
        target = (ROOT / source).parent / path
        relative = target.resolve().relative_to(ROOT).as_posix()
        if relative in PAGES:
            # The HTML layout preserves every source directory.
            replacement = 'index.html' if path == 'README.md' else path.replace('README.md', 'index.html')
            if replacement.endswith('.md'):
                replacement = replacement[:-3] + '.html'
            return 'href="' + html.escape(replacement + (sep + fragment if sep else ''), quote=True) + '"'
        return match.group(0)

    return re.sub(r'href="([^"]+)"', replace, rendered)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', default='0.2.3')
    parser.add_argument('--output', type=Path, default=ROOT / 'dist')
    args = parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
        parser.error('Version must contain major.minor.patch')
    args.output.mkdir(parents=True, exist_ok=True)
    archive = args.output / f'Aster-Desktop-{args.version}-docs.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as package:
        for source, (destination, label) in PAGES.items():
            text = (ROOT / source).read_text(encoding='utf-8')
            package.writestr(source, text)
            rendered = markdown.markdown(text, extensions=['tables', 'fenced_code', 'toc'], extension_configs={'toc': {'slugify': slugify}})
            rendered = local_links(source, rendered)
            prefix = '../' if destination.startswith('docs/') else ''
            links = ''.join(
                f'<a href="{prefix + path}"' + (' aria-current="page"' if path == destination else '') + f'>{html.escape(name)}</a>'
                for path, name in PAGES.values()
            )
            document = (
                '<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8">'
                '<meta name="viewport" content="width=device-width,initial-scale=1">'
                f'<title>{html.escape(label)} · Aster Desktop {args.version}</title><style>{CSS}</style></head><body>'
                f'<header><a href="{prefix}index.html">Aster Desktop</a><span>{args.version} 使用文件 · 可離線閱讀</span></header>'
                f'<div class="layout"><nav aria-label="使用文件">{links}</nav><main>{rendered}'
                '<footer>GPL-3.0 · 平台驗證範圍請參閱測試紀錄。下載與 GitHub 連結需網路。</footer>'
                '</main></div></body></html>'
            )
            package.writestr(destination, document)
        package.write(ROOT / 'LICENSE', 'LICENSE')
    print(archive)
    print(f'Created {len(PAGES)} HTML pages with matching Markdown and license.')


if __name__ == '__main__':
    main()
