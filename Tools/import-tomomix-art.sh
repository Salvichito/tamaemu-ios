#!/bin/zsh
# Copies Tomomix drawings (tomo-*.svg or tomo-*.png) from your Figma export
# folder into the app's asset catalog. Run it again after every export:
# new drawings are added, changed ones replaced. Names starting with x-
# don't match tomo-* and are skipped.
#
#   Tools/import-tomomix-art.sh [folder]   (default: ~/Documents/Tamagotchi/assets)

set -e
src=${1:-$HOME/Documents/Tamagotchi/assets}
dest=${0:A:h:h}/TamaEmu/Resources/Assets.xcassets/Tomomix

python3 - "$src" "$dest" <<'PY'
import json, pathlib, shutil, sys
src, dest = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
dest.mkdir(parents=True, exist_ok=True)
info = {"author": "xcode", "version": 1}
(dest / "Contents.json").write_text(json.dumps({"info": info}, indent=2))
# Drawings the app doesn't use as they are: they're cut up below instead.
sources = {"tomo-shootingstar", "tomo-starrynight", "tomo-zzz", "tomo-poop-small", "tomo-poop-big", "tomo-healing", "tomo-swoosh"}
import re

def no_white_background(svg):
    """Figma sometimes exports a white square behind the drawing; drop it."""
    m = re.search(r'<svg width="([\d.]+)" height="([\d.]+)"', svg)
    if not m:
        return svg
    w, h = m.groups()
    return re.sub(rf'<rect width="{w}" height="{h}" fill="(white|#FFFFFF|#ffffff)"/>\n?', "", svg, count=1)

files = sorted(f for f in src.glob("tomo-*") if f.suffix in (".svg", ".png") and f.stem not in sources)
for f in files:
    imageset = dest / f"{f.stem}.imageset"
    shutil.rmtree(imageset, ignore_errors=True)
    imageset.mkdir()
    if f.suffix == ".svg":
        (imageset / f.name).write_text(no_white_background(f.read_text()))
    else:
        shutil.copy(f, imageset / f.name)
    image = {"filename": f.name, "idiom": "universal"}
    contents = {"images": [image], "info": info}
    if f.suffix == ".svg":
        contents["properties"] = {"preserves-vector-representation": True}
    else:
        image["scale"] = "3x"
    (imageset / "Contents.json").write_text(json.dumps(contents, indent=2))
print(f"Imported {len(files)} drawings into {dest}")

def add_svg(name, svg):
    imageset = dest / f"{name}.imageset"
    shutil.rmtree(imageset, ignore_errors=True)
    imageset.mkdir()
    (imageset / f"{name}.svg").write_text(svg)
    (imageset / "Contents.json").write_text(json.dumps({
        "images": [{"filename": f"{name}.svg", "idiom": "universal"}], "info": info,
        "properties": {"preserves-vector-representation": True}}, indent=2))

def bbox(d):
    n = [float(x) for x in re.findall(r"-?\d*\.?\d+(?:e-?\d+)?", d)]
    xs, ys = n[0::2], n[1::2]
    return min(xs), min(ys), max(xs), max(ys)

# tomo-shootingstar.svg (a 596 square on the night color) becomes:
#  - tomo-shooting-star: the star and its trail, without the background,
#    cropped to the drawing (the head is the 4-point star on the right)
#  - tomo-star-fallen: the 4-point star on its own
f = src / "tomo-shootingstar.svg"
if f.exists():
    svg = re.sub(r'<rect width="595\.656" height="595\.656" fill="#[0-9A-Fa-f]{6}"/>', "", f.read_text(), count=1)
    head = re.search(r'<path d="([^"]+)" fill="#FFEA60"/>', svg)
    x0, y0, x1, y1 = bbox(head.group(1))
    cropped = re.sub(r'width="\d+" height="\d+" viewBox="[^"]+"', 'width="472" height="180" viewBox="0 200 472 180"', svg, count=1)
    add_svg("tomo-shooting-star", cropped)
    w, h = x1 - x0, y1 - y0
    add_svg("tomo-star-fallen",
            f'<svg width="{w:.0f}" height="{h:.0f}" viewBox="{x0:.2f} {y0:.2f} {w:.2f} {h:.2f}" fill="none" '
            f'xmlns="http://www.w3.org/2000/svg">\n{head.group(0)}\n</svg>\n')
    print("Cut tomo-shooting-star and tomo-star-fallen from", f.name)

# tomo-starrynight.svg becomes a list of stars (the app fades each one in
# and out on its own) plus the background color.
f = src / "tomo-starrynight.svg"
if f.exists():
    svg = f.read_text()
    background = re.search(r'<rect [^>]*fill="(#[0-9A-Fa-f]{6})"', svg).group(1)
    stars = []
    for d, color in re.findall(r'<path d="([^"]+)" fill="(#[0-9A-Fa-f]{6})"', svg):
        x0, y0, x1, y1 = bbox(d)
        stars.append({"x": round((x0 + x1) / 2, 2), "y": round((y0 + y1) / 2, 2),
                      "r": round((x1 - x0) / 2, 2), "color": color})
    dataset = dest / "tomo-starrynight.dataset"
    shutil.rmtree(dataset, ignore_errors=True)
    dataset.mkdir()
    (dataset / "tomo-starrynight.json").write_text(json.dumps(
        {"size": 596, "background": background, "stars": stars}, indent=1))
    (dataset / "Contents.json").write_text(json.dumps({
        "data": [{"filename": "tomo-starrynight.json", "idiom": "universal"}], "info": info}, indent=2))
    print(f"Made the starry night: {len(stars)} stars")

def split(svg):
    """The drawing's opening tag, its shapes, and its closing part."""
    svg = no_white_background(svg)
    head = re.match(r"<svg[^>]*>\n?", svg).group(0)
    shapes = re.findall(r"<(?:path|circle|rect|ellipse)\b[^>]*/>", svg)
    return head, shapes

def path_box(shape):
    d = re.search(r' d="([^"]+)"', shape)
    return bbox(d.group(1)) if d else None

# Poop: the smell waves (the tall, thin squiggles) become their own
# drawings, each also mirrored, so the app can flip them one by one.
# tomo-poop-big = the poop alone; tomo-poop-big-wave-1..3 (+ -flip).
for name in ("tomo-poop-small", "tomo-poop-big"):
    f = src / f"{name}.svg"
    if not f.exists():
        continue
    head, shapes = split(f.read_text())
    body, waves = [], []
    for shape in shapes:
        b = path_box(shape)
        if b and (b[3] - b[1]) > 1.8 * (b[2] - b[0]):
            waves.append((b, shape))
        else:
            body.append(shape)
    add_svg(name, head + "\n".join(body) + "\n</svg>\n")
    for i, (b, shape) in enumerate(sorted(waves, key=lambda w: w[0][0]), 1):
        cx = (b[0] + b[2]) / 2
        add_svg(f"{name}-wave-{i}", head + shape + "\n</svg>\n")
        add_svg(f"{name}-wave-{i}-flip",
                head + f'<g transform="translate({2 * cx:.2f} 0) scale(-1 1)">{shape}</g>\n</svg>\n')
    print(f"Split {name}: {len(waves)} smell waves")

# Healing frog: the fart cloud (the shapes right of x = 295, at its back)
# becomes tomo-healing-cloud; the rest, the frog, tomo-healing-frog. Both
# keep the same 512 canvas (and the gradient definitions) so they line up.
f = src / "tomo-healing.svg"
if f.exists():
    text = no_white_background(f.read_text())
    head, shapes = split(text)
    defs = re.search(r"<defs>.*?</defs>", text, re.S)
    defs = defs.group(0) + "\n" if defs else ""
    cloud, frog = [], []
    for shape in shapes:
        b = path_box(shape)
        (cloud if b and b[0] > 295 else frog).append(shape)
    add_svg("tomo-healing-frog", head + "\n".join(frog) + "\n" + defs + "</svg>\n")
    add_svg("tomo-healing-cloud", head + "\n".join(cloud) + "\n" + defs + "</svg>\n")
    print(f"Split tomo-healing: frog {len(frog)} shapes, cloud {len(cloud)}")

# Cleaning swoosh: the soft band stays tomo-swoosh; each sparkle becomes
# tomo-swoosh-sparkle-1..N on the same canvas, so the app can make each
# one twinkle on its own.
f = src / "tomo-swoosh.svg"
if f.exists():
    text = no_white_background(f.read_text())
    head = re.match(r"<svg[^>]*>\n?", text).group(0)
    defs = re.search(r"<defs>.*?</defs>", text, re.S)
    defs = defs.group(0) + "\n" if defs else ""
    band = re.findall(r"<rect\b[^>]*/>", text)
    band = [r for r in band if "url(#paint" in r]
    sparkles = re.findall(r"<path\b[^>]*/>", text)
    add_svg("tomo-swoosh", head + "\n".join(band) + "\n" + defs + "</svg>\n")
    for i, sp in enumerate(sparkles, 1):
        add_svg(f"tomo-swoosh-sparkle-{i}", head + sp + "\n</svg>\n")
    print(f"Split tomo-swoosh: band + {len(sparkles)} sparkles")

# The 8 care icons (01-food.svg … 08-attention.svg), shared by Tomomix
# (tomo-icon-*) and the P1/P2 screen (P1Icon*). One color, tinted by the
# app, cropped to the middle 128 of their 256 square so the shape fills
# about the same room the old icons did.
icons = [("01-food", "food", "Food"), ("02-light", "light", "Light"), ("03-game", "game", "Game"),
         ("04-medicine", "medicine", "Medicine"), ("05-bathroom", "clean", "Bathroom"),
         ("06-status", "status", "Status"), ("07-training", "discipline", "Training"),
         ("08-attention", "attention", "Attention")]
catalog = dest.parent
for source, tomo, p1 in icons:
    f = src / f"{source}.svg"
    if not f.exists():
        continue
    svg = no_white_background(f.read_text())
    svg = re.sub(r'width="256" height="256" viewBox="0 0 256 256"', 'width="128" height="128" viewBox="64 64 128 128"', svg, count=1)
    for folder, name, filename in ((dest, f"tomo-icon-{tomo}", f"tomo-icon-{tomo}.svg"),
                                   (catalog, f"P1Icon{p1}", f"{p1.lower()}.svg")):
        imageset = folder / f"{name}.imageset"
        shutil.rmtree(imageset, ignore_errors=True)
        imageset.mkdir()
        (imageset / filename).write_text(svg)
        (imageset / "Contents.json").write_text(json.dumps({
            "images": [{"filename": filename, "idiom": "universal"}], "info": info,
            "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"}}, indent=2))
    print("Icon", source, "->", f"tomo-icon-{tomo}", "+", f"P1Icon{p1}")

# ZZZ: each letter becomes tomo-zzz-1..3 (in the drawing's layer order),
# all on the same canvas, so the app can show them one after another.
f = src / "tomo-zzz.svg"
if f.exists():
    head, shapes = split(f.read_text())
    for i, shape in enumerate(shapes, 1):
        add_svg(f"tomo-zzz-{i}", head + shape + "\n</svg>\n")
    print(f"Split tomo-zzz: {len(shapes)} letters")
PY
