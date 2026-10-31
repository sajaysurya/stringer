#!/bin/zsh
# Unit tests, then the lifecycle checks against the built app.
#   scripts/test.sh            unit + lifecycle (needs the speech models: bin/stringer setup)
#   scripts/test.sh --unit     unit tests only (what CI runs)
set -euo pipefail
ROOT=${0:A:h:h}
cd $ROOT
# Swift Build with a Command Line Tools-only toolchain intermittently fails to
# load the swift-testing macros; pointing at them explicitly fixes it.
FLAGS=()
PLUGINS=$(dirname $(xcrun --find swift))/../lib/swift/host/plugins/testing
[[ -d $PLUGINS ]] && FLAGS=(-Xswiftc -plugin-path -Xswiftc $PLUGINS)
LOG=$(mktemp)
rc=0
swift test $FLAGS >$LOG 2>&1 || rc=$?
grep -E '✘|↳ .*(only|changed|lost)|Test run with|error:' $LOG || tail -20 $LOG
rm -f $LOG
(( rc == 0 )) || exit $rc
[[ ${1:-} == --unit ]] && exit 0
[[ -x bin/stringer ]] || ./build.sh
scripts/lifecycle-test.sh
