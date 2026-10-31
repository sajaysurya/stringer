#!/bin/zsh
# Builds dist/Stringer-<version>.dmg for teammates: Stringer.app (with the
# CLI, title helper and recorder inside) and an Applications link.
#
# Unnotarized (that needs a paid Apple Developer account). After copying the
# app to /Applications, teammates run once:
#   xattr -dr com.apple.quarantine /Applications/Stringer.app
set -euo pipefail

ROOT=${0:A:h}
cd $ROOT
./build.sh
VERSION=$(sed -n 's/^public let stringerVersion = "\(.*\)"/\1/p' Sources/StringerCore/Files.swift)

# Self-test of what is about to ship (K-6): the bundled CLI runs and reports
# the version being packaged.
got=$("bin/Stringer.app/Contents/Helpers/stringer" version)
[[ $got == "stringer $VERSION" ]] || { echo "package.sh: bundled CLI says '$got', expected 'stringer $VERSION'"; exit 1; }
codesign --verify --deep --strict "bin/Stringer.app"

DIST=$ROOT/dist
STAGE=$DIST/stage
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "bin/Stringer.app" "$STAGE/Stringer.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<EOF
Stringer $VERSION — on-device meeting transcripts

1. Drag Stringer to Applications.
2. Stringer is not notarized, so once, in Terminal:
     xattr -dr com.apple.quarantine /Applications/Stringer.app
3. Open Stringer. It appears in the menu bar and downloads its speech
   models (about 600 MB, once; after that it works offline).
4. The first recording asks for Microphone and System Audio access, in
   Stringer's name. Allow both.

Meetings are saved in ~/Meetings (change it from the menu).
Command line: /Applications/Stringer.app/Contents/Helpers/stringer
  e.g. ln -s /Applications/Stringer.app/Contents/Helpers/stringer ~/.local/bin/stringer
Problems: stringer doctor
EOF

DMG=$DIST/Stringer-$VERSION.dmg
rm -f "$DMG"
hdiutil create -quiet -volname "Stringer $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
echo "packaged $DMG ($(du -h "$DMG" | cut -f1))"
