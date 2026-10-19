import sys
from PIL import Image, ImageDraw
src, out_png, out_ico = sys.argv[1:4]
RADIUS = 0.20   # coin = 20% du cote : arrondi visible, reste un carre
MARGIN = 0.03   # petite marge transparente
S = 1024
SS = 4
im = Image.open(src).convert('RGBA')
inner = round(S * (1 - 2 * MARGIN))
off = (S - inner) // 2
tile = im.resize((inner, inner), Image.LANCZOS)
mask = Image.new('L', (inner * SS, inner * SS), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, inner * SS - 1, inner * SS - 1), radius=round(inner * SS * RADIUS), fill=255)
mask = mask.resize((inner, inner), Image.LANCZOS)
tile.putalpha(mask)
canvas = Image.new('RGBA', (S, S), (0, 0, 0, 0))
canvas.paste(tile, (off, off))
canvas.save(out_png)
canvas.save(out_ico, sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
