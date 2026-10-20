"""Genere tous les logos arrondis a partir de assets/icon/icon_blue.png.

Un seul rayon (RADIUS) pour le logo dans l'app, le site et le logiciel Windows,
pour que le coin soit identique partout. Lancer depuis la racine du projet :

    python tools/round_icon.py

Non touches (le systeme applique deja sa propre forme) : Android (icone
adaptative), iOS, apple-touch-icon et les icones web "maskable".
"""
from PIL import Image, ImageDraw

SRC = 'assets/icon/icon_blue.png'
RADIUS = 0.18   # coin = 18% du cote : petit arrondi net, reste un carre
MARGIN = 0.03   # petite marge transparente (icone du bureau Windows)
SS = 4          # sur-echantillonnage du masque pour un bord lisse

src = Image.open(SRC).convert('RGBA')


def rounded(size, radius=RADIUS, margin=0.0):
    """Logo carre aux coins arrondis, fond transparent autour."""
    inner = round(size * (1 - 2 * margin))
    off = (size - inner) // 2
    tile = src.resize((inner, inner), Image.LANCZOS)
    mask = Image.new('L', (inner * SS, inner * SS), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, inner * SS - 1, inner * SS - 1),
        radius=round(inner * SS * radius), fill=255)
    tile.putalpha(mask.resize((inner, inner), Image.LANCZOS))
    canvas = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    canvas.paste(tile, (off, off))
    return canvas


def square(size):
    return src.convert('RGB').resize((size, size), Image.LANCZOS)


# Logo affiche dans l'app (en-tete, menu, accueil, a propos).
rounded(512).save('assets/icon/logo.png')

# Windows : source de flutter_launcher_icons / msix + .ico du .exe.
desktop = rounded(1024, margin=MARGIN)
desktop.save('assets/icon/icon_rounded.png')
desktop.save('windows/runner/resources/app_icon.ico',
             sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64),
                    (128, 128), (256, 256)])

# Site web : favicon + icones PWA ; iOS arrondit lui-meme l'apple-touch-icon.
rounded(64).save('web/favicon.png')
rounded(256).save('web/favicon.ico', sizes=[(16, 16), (32, 32), (48, 48)])
rounded(192).save('web/icons/Icon-192.png')
rounded(512).save('web/icons/Icon-512.png')
square(180).save('web/icons/apple-touch-icon.png')

# macOS : grille Apple (contenu 824/1024 centre, rayon ~22.5%).
for s in (16, 32, 64, 128, 256, 512, 1024):
    rounded(s, radius=0.225, margin=100 / 1024).save(
        f'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{s}.png')
