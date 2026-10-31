#!/bin/zsh
# Builds the standalone webrtc-audio-processing (the copy PulseAudio and
# PipeWire use) as one static library, aec/out/lib/libstringer_webrtc.a, for
# the same deployment target as the app. A stamp file triggers a rebuild when
# the version or the target changes.
set -euo pipefail

HERE=${0:A:h}
ROOT=${HERE:h}
VERSION=2.1
TARGET=${MACOSX_DEPLOYMENT_TARGET:-26.0}
SRC=$HERE/webrtc-audio-processing-$VERSION
BUILD=$HERE/build
OUT=$HERE/out
STAMP=$OUT/stamp
WANT="webrtc-audio-processing $VERSION macos $TARGET arm64"

if [[ -f $STAMP && "$(cat $STAMP)" == "$WANT" && -f $OUT/lib/libstringer_webrtc.a && -d $OUT/licenses ]]; then
  exit 0
fi

# meson and ninja live in a project venv, never system-wide.
VENV=$ROOT/.venv-build
if [[ ! -x $VENV/bin/meson ]]; then
  echo "aec: creating $VENV with meson and ninja"
  if command -v uv >/dev/null; then
    uv venv -q $VENV && uv pip install -q --python $VENV/bin/python meson ninja
  else
    python3 -m venv $VENV && $VENV/bin/pip install -q meson ninja
  fi
fi
export PATH=$VENV/bin:$PATH

TARBALL=$HERE/webrtc-audio-processing-$VERSION.tar.xz
if [[ ! -f $TARBALL ]]; then
  curl -sSfL -o $TARBALL \
    https://freedesktop.org/software/pulseaudio/webrtc-audio-processing/webrtc-audio-processing-$VERSION.tar.xz
fi
rm -rf $SRC $BUILD $OUT
tar -xf $TARBALL -C $HERE

export MACOSX_DEPLOYMENT_TARGET=$TARGET
export CFLAGS="-mmacosx-version-min=$TARGET"
export CXXFLAGS="-mmacosx-version-min=$TARGET"
export LDFLAGS="-mmacosx-version-min=$TARGET"

meson setup $BUILD $SRC \
  --buildtype=release \
  --default-library=static \
  --prefix=$OUT \
  --wrap-mode=forcefallback \
  -Dcpp_std=c++17 >$HERE/meson-setup.log 2>&1 || { tail -40 $HERE/meson-setup.log; exit 1; }
ninja -C $BUILD >$HERE/ninja.log 2>&1 || { tail -40 $HERE/ninja.log; exit 1; }
meson install -C $BUILD >/dev/null

# One archive holding webrtc and every abseil piece it pulled in, so the
# package links a single library.
mkdir -p $OUT/lib
libs=(${(f)"$(find $BUILD -name '*.a' -type f)"})
libtool -static -o $OUT/lib/libstringer_webrtc.a $libs 2>/dev/null
# Their licenses travel with the library (the app bundle ships them).
mkdir -p $OUT/licenses
cp $SRC/COPYING $OUT/licenses/webrtc-audio-processing-COPYING.txt
cp $SRC/subprojects/abseil-cpp-*/LICENSE $OUT/licenses/abseil-LICENSE.txt
echo $WANT > $STAMP
echo "aec: built $OUT/lib/libstringer_webrtc.a (${#libs} archives, target $TARGET)"
