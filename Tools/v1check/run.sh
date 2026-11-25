#!/bin/zsh
# Headless health check of every first-gen (TamaLib) toy.
#
#   Tools/v1check/run.sh [rom-folder]
#
# Builds v1check against the app's own core (Packages/TamaLibCore), runs it
# on each ROM in parallel, and writes Tools/v1check/report.md. ROMs are not in
# the repo; the folder defaults to the BrickEmuPy ROM set in iCloud Drive.
# Takes a few minutes: each toy is run through about 1.5 emulated hours.
set -u
HERE=${0:A:h}
REPO=${HERE:h:h}
CORE=${V1CHECK_CORE:-$REPO/Packages/TamaLibCore/Sources/CTamaLib}   # override to try a modified core
ROMS=${1:-"$HOME/Library/Mobile Documents/com~apple~CloudDocs/Tamagotchi/Bios-Roms/BrickEmuPy ROMs"}
OUT=${V1CHECK_OUT:-$HERE/.build}
mkdir -p $OUT

clang -O2 -I$CORE/include $CORE/cpu.c $CORE/hw.c $CORE/tamalib.c $CORE/hal_ios.c \
  $HERE/v1check.c -o $OUT/v1check || { echo "build failed"; exit 1 }

typeset -A ROM=(
  p1 TamagotchiP1.bin  p1j TamagotchiP1J.bin  p2 TamagotchiP2.bin
  angel TamagotchiAngel.bin  morino TamagotchiMorino.bin  umino TamagotchiUmino.bin
  genjintch TamagotchiGenjintch.bin  tamaotch TamagotchiTamaotch.bin
  mothra TamagotchiMothra.bin  yasashii TamagotchiYasashii.bin
  digimon-v1 DigimonV1.bin  digimon-v2 DigimonV2.bin  digimon-v3 DigimonV3.bin
)
ORDER=(p1 p1j p2 angel morino umino genjintch tamaotch mothra yasashii digimon-v1 digimon-v2 digimon-v3)

for id in $ORDER; do
  $OUT/v1check "$ROMS/${ROM[$id]}" $id > $OUT/$id.md 2>/dev/null &
done
wait

{
  echo "# First-gen core check"
  echo
  echo "Run $(date '+%Y-%m-%d %H:%M') on the core in this checkout. Each toy: real-time pace, boot,"
  echo "start-up and hatch time vs its manual, menu icons, short presses, calls in an hour"
  echo "left alone, and save/resume. Screens are ASCII snapshots to eyeball."
  echo
  echo "| Toy | Result |"
  echo "|---|---|"
  for id in $ORDER; do
    echo "| ${ROM[$id]:r} | $(grep '^Summary' $OUT/$id.md | sed 's/^Summary for [^:]*: //') |"
  done
  echo
  for id in $ORDER; do cat $OUT/$id.md; done
} > ${V1CHECK_REPORT:-$HERE/report.md}

grep -h '^Summary' $OUT/*.md
grep -h '\*\*FAIL\*\*\|\*\*WARN\*\*' $OUT/*.md | head -40
echo "Report: $HERE/report.md"
