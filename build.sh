#!/bin/zsh
# Dev build into bin/:
#   bin/stringer, bin/stringer-title, bin/aec-offline
#   bin/Stringer Recorder.app          standalone recorder (org.sajay.stringer.recorder)
#   bin/Stringer.app                   menu-bar app (org.sajay.stringer), with the
#                                      CLI, title helper and recorder in Contents/Helpers
#
# Everything is signed with "Stringer Local Signing" (./setup-signing.sh) so
# permission grants survive rebuilds; without it, ad-hoc (macOS asks again
# after every build).
#
#   ./build.sh            release build (what package.sh ships)
#   ./build.sh --debug    debug build
set -euo pipefail

ROOT=${0:A:h}
cd $ROOT
CONFIG=release
[[ ${1:-} == --debug ]] && CONFIG=debug
VERSION=$(sed -n 's/^public let stringerVersion = "\(.*\)"/\1/p' Sources/StringerCore/Files.swift)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)
export MACOSX_DEPLOYMENT_TARGET=26.0

./aec/build.sh
swift build -c $CONFIG 2>&1 | grep -vE 'ld: warning: search path' | grep -E 'error|warning: unre|Compiling|Build' || true
OUT=$(swift build -c $CONFIG --show-bin-path)
for exe in stringer StringerRecorder StringerApp stringer-title aec-offline; do
  [[ -x "$OUT/$exe" ]] || { echo "build.sh: $OUT/$exe missing"; exit 1; }
done

BIN=$ROOT/bin
rm -rf "$BIN"
mkdir -p "$BIN"

plist() {  # template, destination
  sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD/" "$1" > "$2"
}

# The recorder bundle.
make_recorder() {  # destination .app
  mkdir -p "$1/Contents/MacOS"
  cp "$OUT/StringerRecorder" "$1/Contents/MacOS/StringerRecorder"
  plist Resources/Info-recorder.plist "$1/Contents/Info.plist"
}

cp "$OUT/stringer" "$OUT/stringer-title" "$OUT/aec-offline" "$BIN/"
make_recorder "$BIN/Stringer Recorder.app"

APP="$BIN/Stringer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$OUT/StringerApp" "$APP/Contents/MacOS/Stringer"
plist Resources/Info-app.plist "$APP/Contents/Info.plist"
cp "$OUT/stringer" "$OUT/stringer-title" "$APP/Contents/Helpers/"
make_recorder "$APP/Contents/Helpers/Stringer Recorder.app"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# License texts of everything linked in (THIRD_PARTY_NOTICES.md).
LIC="$APP/Contents/Resources/Licenses"
mkdir -p "$LIC"
FA=$(swift package show-dependencies --format json 2>/dev/null | python3 -I -c "import json,sys; print(next(d['path'] for d in json.load(sys.stdin)['dependencies'] if d['identity']=='fluidaudio'))" 2>/dev/null || echo .build/checkouts/FluidAudio)
cp LICENSE "$LIC/Stringer-LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$LIC/"
cp aec/out/licenses/* "$LIC/"
cp "$FA/LICENSE" "$LIC/FluidAudio-LICENSE.txt"
for f in fastcluster vbx NemoTextProcessing; do cp "$FA/ThirdPartyLicenses/$f-LICENSE.md" "$LIC/" 2>/dev/null || true; done

# Sign inside-out with the stable identity if there is one.
KEYCHAIN=${STRINGER_KEYCHAIN:-$HOME/Library/Keychains/stringer-signing.keychain-db}
IDENTITY="Stringer Local Signing"
SIGN=(--force --timestamp=none)
if [[ -f $KEYCHAIN ]] && security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  security unlock-keychain -p "${STRINGER_KEYCHAIN_PASSWORD:-stringer-local}" "$KEYCHAIN" 2>/dev/null || true
  SIGN+=(--sign "$IDENTITY" --keychain "$KEYCHAIN")
  echo "signing with \"$IDENTITY\""
else
  SIGN+=(--sign -)
  echo "warning: no \"$IDENTITY\" — signing ad-hoc; macOS will ask for permissions again after every build."
  echo "         run ./setup-signing.sh once to fix that."
fi
sign() { codesign "${SIGN[@]}" --identifier "$1" "$2" 2>&1 | grep -v "replacing existing signature" || true; }

sign org.sajay.stringer.cli "$BIN/stringer"
sign org.sajay.stringer.title "$BIN/stringer-title"
sign org.sajay.stringer.aec-offline "$BIN/aec-offline"
sign org.sajay.stringer.recorder "$BIN/Stringer Recorder.app"
sign org.sajay.stringer.cli "$APP/Contents/Helpers/stringer"
sign org.sajay.stringer.title "$APP/Contents/Helpers/stringer-title"
sign org.sajay.stringer.recorder "$APP/Contents/Helpers/Stringer Recorder.app"
sign org.sajay.stringer "$APP"
codesign --verify --deep --strict "$APP"

echo "built Stringer $VERSION ($CONFIG) in bin/"
echo "  CLI:  bin/stringer        app: open bin/Stringer.app"
