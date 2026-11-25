#!/bin/zsh
# Renders every TamaEmu*.icon (Icon Composer) file into a small preview
# image for the App Icon picker in Settings. iOS can't draw an .icon file
# inside the app, so the picker shows these pictures instead.
#
# Re-run this after editing any icon in Icon Composer:
#   zsh Tools/render-icon-previews.sh
set -euo pipefail
cd "${0:A:h}/.."

ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
ASSETS="TamaEmu/Resources/Assets.xcassets"

for icon in TamaEmu/Resources/TamaEmu*.icon; do
    base="${icon:t:r}"                       # TamaEmu or TamaEmu-yellow
    if [[ "$base" == "TamaEmu" ]]; then id="default"; else id="${base#TamaEmu-}"; fi
    set="$ASSETS/IconPreview-$id.imageset"
    mkdir -p "$set"
    "$ICTOOL" "$icon" --export-image --output-file "$set/preview.png" \
        --platform iOS --rendition Default --width 180 --height 180 --scale 1 >/dev/null
    cat > "$set/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "preview.png", "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
    echo "rendered $id"
done
