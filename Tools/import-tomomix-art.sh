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
files = sorted(f for f in src.glob("tomo-*") if f.suffix in (".svg", ".png"))
for f in files:
    imageset = dest / f"{f.stem}.imageset"
    shutil.rmtree(imageset, ignore_errors=True)
    imageset.mkdir()
    shutil.copy(f, imageset / f.name)
    image = {"filename": f.name, "idiom": "universal"}
    contents = {"images": [image], "info": info}
    if f.suffix == ".svg":
        contents["properties"] = {"preserves-vector-representation": True}
    else:
        image["scale"] = "3x"
    (imageset / "Contents.json").write_text(json.dumps(contents, indent=2))
print(f"Imported {len(files)} drawings into {dest}")
PY
