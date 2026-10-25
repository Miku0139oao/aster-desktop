"""Render the original vector Aster orbital-A monogram (Pillow required)."""
from pathlib import Path
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parent.parent
scale = 8
image = Image.new('RGBA', (256*scale, 256*scale))
d = ImageDraw.Draw(image)
d.rounded_rectangle((0, 0, 256*scale-1, 256*scale-1), radius=64*scale, fill='#7652bf')
def line(points, color, width):
    points = [(round(x*scale), round(y*scale)) for x,y in points]
    d.line(points, fill=color, width=width*scale, joint='curve')
    for x,y in [points[0], points[-1]]:
        r=width*scale/2
        d.ellipse((x-r,y-r,x+r,y+r), fill=color)
line([(63,196),(126,62),(191,196)], '#f5efff', 19)
line([(88,146),(166,146)], '#f5efff', 19)
curve=[]
for i in range(201):
    t=i/200; u=1-t
    curve.append((u**3*46+3*u*u*t*90+3*u*t*t*200+t**3*211,u**3*164+3*u*u*t*214+3*u*t*t*166+t**3*92))
line(curve, '#d7baff', 10)
d.ellipse(((211-12)*scale,(92-12)*scale,(211+12)*scale,(92+12)*scale), fill='#f5efff')

def save(path, size):
    path.parent.mkdir(parents=True, exist_ok=True)
    image.resize((size,size),Image.Resampling.LANCZOS).save(path)

save(root/'assets/aster.png', 512)
image.resize((256,256),Image.Resampling.LANCZOS).save(
    root/'assets/aster.ico',
    sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)],
)
(root/'windows/runner/resources/app_icon.ico').write_bytes((root/'assets/aster.ico').read_bytes())
for size in [16,32,64,128,256,512,1024]:
    save(root/f'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png', size)

# Android launchers use the legacy PNG below API 26 and an adaptive vector
# foreground above it. Keep both generated from the same source so a Flutter
# template update cannot silently restore the default Flutter icon.
android_res = root/'android/app/src/main/res'
for density, size in {
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
}.items():
    save(android_res/f'mipmap-{density}/ic_launcher.png', size)
    save(android_res/f'mipmap-{density}/ic_launcher_round.png', size)

(android_res/'values/ic_launcher_background.xml').write_text(
    '''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#7652BF</color>
</resources>
''',
    encoding='utf-8',
)

logo_paths = '''    <path
        android:pathData="M26.578,82.688 L53.156,26.156 L80.578,82.688"
        android:strokeColor="{mark}"
        android:strokeWidth="8.016"
        android:strokeLineCap="round"
        android:strokeLineJoin="round" />
    <path
        android:pathData="M37.125,61.594 L70.031,61.594"
        android:strokeColor="{mark}"
        android:strokeWidth="8.016"
        android:strokeLineCap="round" />
    <path
        android:pathData="M19.406,69.188 C37.969,90.281 84.375,70.031 89.016,38.813"
        android:strokeColor="{orbit}"
        android:strokeWidth="4.219"
        android:strokeLineCap="round" />
    <path
        android:pathData="M89.016,33.75 A5.063,5.063 0,1 1,89.016,43.875 A5.063,5.063 0,1 1,89.016,33.75"
        android:fillColor="{mark}" />
'''

def vector(mark, orbit):
    return f'''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
{logo_paths.format(mark=mark, orbit=orbit).rstrip()}
</vector>
'''

(android_res/'drawable').mkdir(parents=True, exist_ok=True)
(android_res/'drawable/ic_launcher_foreground.xml').write_text(
    vector('#F5EFFF', '#D7BAFF'),
    encoding='utf-8',
)
(android_res/'drawable/ic_launcher_monochrome.xml').write_text(
    vector('#FFFFFFFF', '#FFFFFFFF'),
    encoding='utf-8',
)

adaptive_icon = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
{monochrome}</adaptive-icon>
'''
for directory in ['mipmap-anydpi-v26', 'mipmap-anydpi-v33']:
    (android_res/directory).mkdir(parents=True, exist_ok=True)
    monochrome = (
        '    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />\n'
        if directory.endswith('v33')
        else ''
    )
    for name in ['ic_launcher', 'ic_launcher_round']:
        (android_res/directory/f'{name}.xml').write_text(
            adaptive_icon.format(monochrome=monochrome),
            encoding='utf-8',
        )

svg='''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><rect width="256" height="256" rx="64" fill="#7652bf"/><g fill="none" stroke="#f5efff" stroke-width="19" stroke-linecap="round" stroke-linejoin="round"><path d="M63 196 126 62 191 196"/><path d="M88 146H166"/></g><path d="M46 164C90 214 200 166 211 92" fill="none" stroke="#d7baff" stroke-width="10" stroke-linecap="round"/><circle cx="211" cy="92" r="12" fill="#f5efff"/></svg>'''
(root/'assets/aster.svg').write_text(svg,encoding='utf-8')
