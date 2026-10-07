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
image.resize((512,512),Image.Resampling.LANCZOS).save(root/'assets/aster.png')
image.resize((256,256),Image.Resampling.LANCZOS).save(root/'assets/aster.ico',sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
(root/'windows/runner/resources/app_icon.ico').write_bytes((root/'assets/aster.ico').read_bytes())
for size in [16,32,64,128,256,512,1024]:
    image.resize((size,size),Image.Resampling.LANCZOS).save(root/f'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png')
svg='''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><rect width="256" height="256" rx="64" fill="#7652bf"/><g fill="none" stroke="#f5efff" stroke-width="19" stroke-linecap="round" stroke-linejoin="round"><path d="M63 196 126 62 191 196"/><path d="M88 146H166"/></g><path d="M46 164C90 214 200 166 211 92" fill="none" stroke="#d7baff" stroke-width="10" stroke-linecap="round"/><circle cx="211" cy="92" r="12" fill="#f5efff"/></svg>'''
(root/'assets/aster.svg').write_text(svg,encoding='utf-8')
