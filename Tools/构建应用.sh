#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release -j 6
products="$(swift build -c release --show-bin-path)"
app="$PWD/dist/Living Atlas.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
mkdir -p "$app/Contents/Helpers"
install -m 0755 "$products/atlas" "$app/Contents/Helpers/atlas"
codesign --force --sign - "$app/Contents/Helpers/atlas"
cp "$products/LivingAtlas" "$app/Contents/MacOS/LivingAtlas"
for bundle in "$products"/*.bundle; do
    dest="$app/Contents/Resources/$(basename "$bundle")"
    mkdir -p "$dest"
    rsync -a --delete "$bundle/" "$dest/"
done
install -m 0644 Tools/LivingAtlas.icns "$app/Contents/Resources/LivingAtlas.icns"
install -m 0644 .build/checkouts/GRDB.swift/LICENSE "$app/Contents/Resources/GRDB-LICENSE.txt"
cp Tools/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify "$app"
printf '%s\n' "$app"
