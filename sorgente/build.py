#!/usr/bin/env python3
"""Trasforma sorgente/app.html nel sito: index.html, icone e manifest.

Uso:  python3 sorgente/build.py
Legge l'indirizzo e la chiave pubblica di Supabase da sorgente/config.json.
"""
import json
import re
from pathlib import Path

QUI = Path(__file__).resolve().parent
RADICE = QUI.parent

NOME = "Ordini · Profumo di Pane"
NOME_BREVE = "Ordini"
COLORE = "#2A2922"
SFONDO = "#2A2922"
# ritaglio del logo con solo il disegno del pane, per le icone
RITAGLIO_ICONA = (267, 84, 765, 582)


def leggi_config():
    cfg = json.loads((QUI / "config.json").read_text(encoding="utf-8"))
    url = cfg.get("url", "").strip().rstrip("/")
    key = cfg.get("key", "").strip()
    if key.startswith("sb_secret_") or "service_role" in key:
        raise SystemExit("Nel config.json va la chiave pubblica (publishable), non quella segreta.")
    return url, key


def sostituisci(src, nome, valore):
    vecchio = f'const {nome} = "";'
    if src.count(vecchio) != 1:
        raise SystemExit(f"Non trovo {vecchio} in app.html")
    return src.replace(vecchio, f"const {nome} = {json.dumps(valore)};")


def fai_icone():
    from PIL import Image

    logo = Image.open(QUI / "logo.jpg").convert("RGB")
    fondo = logo.getpixel((5, 5))
    disegno = logo.crop(RITAGLIO_ICONA)
    cartella = RADICE / "icone"
    cartella.mkdir(exist_ok=True)
    for lato in (180, 192, 512):
        disegno.resize((lato, lato), Image.LANCZOS).save(cartella / f"icona-{lato}.png", optimize=True)
    # versione "maskable": il disegno al centro con margine, per Android
    lato = 512
    tela = Image.new("RGB", (lato, lato), fondo)
    interno = int(lato * 0.72)
    tela.paste(disegno.resize((interno, interno), Image.LANCZOS), ((lato - interno) // 2, (lato - interno) // 2))
    tela.save(cartella / "icona-maskable-512.png", optimize=True)


def fai_manifest():
    manifest = {
        "name": NOME,
        "short_name": NOME_BREVE,
        "lang": "it",
        "start_url": "./",
        "scope": "./",
        "display": "standalone",
        "background_color": SFONDO,
        "theme_color": COLORE,
        "icons": [
            {"src": "icone/icona-192.png", "sizes": "192x192", "type": "image/png"},
            {"src": "icone/icona-512.png", "sizes": "512x512", "type": "image/png"},
            {"src": "icone/icona-maskable-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable"},
        ],
    }
    (RADICE / "manifest.webmanifest").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main():
    url, key = leggi_config()
    src = (QUI / "app.html").read_text(encoding="utf-8")
    src = sostituisci(src, "SB_URL", url)
    src = sostituisci(src, "SB_KEY", key)

    # quello che sta prima della testata (titolo, caratteri, stile) va nella <head>
    taglio = src.index('<header class="testata">')
    testa, corpo = src[:taglio], src[taglio:]
    testa = re.sub(r"<title>.*?</title>\s*", "", testa, flags=re.S)

    meta = f"""<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>{NOME}</title>
<meta name="robots" content="noindex,nofollow">
<meta name="theme-color" content="{COLORE}">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="{NOME_BREVE}">
<link rel="manifest" href="manifest.webmanifest">
<link rel="icon" type="image/png" sizes="192x192" href="icone/icona-192.png">
<link rel="apple-touch-icon" href="icone/icona-180.png">
"""
    pagina = f"""<!doctype html>
<html lang="it">
<head>
{meta}{testa.strip()}
</head>
<body>
{corpo.strip()}
</body>
</html>
"""
    (RADICE / "index.html").write_text(pagina, encoding="utf-8")
    fai_icone()
    fai_manifest()
    stato = "collegato a Supabase" if url and key else "SENZA Supabase (modalità prova)"
    print(f"Fatto: index.html ({len(pagina) // 1024} KB), {stato}.")


if __name__ == "__main__":
    main()
