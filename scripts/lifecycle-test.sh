#!/bin/zsh
# Meeting lifecycle checks (L-1…L-9) against replayed audio:
# no microphone, no permissions, nothing played aloud. Uses an isolated
# meetings folder, config and support folder; your real ones are untouched.
#
#   scripts/lifecycle-test.sh [STRINGER_BIN]     (default: bin/stringer)
set -uo pipefail

ROOT=${0:A:h:h}
S=${1:-$ROOT/bin/stringer}
WORK=$(mktemp -d /tmp/stringer-lifecycle.XXXXXX)
export STRINGER_HOME=$WORK/home STRINGER_CONFIG=$WORK/config.toml STRINGER_SUPPORT=$WORK/support
export STRINGER_DEBUG=true STRINGER_AI_TITLE=false
mkdir -p $STRINGER_SUPPORT
# Reuse the real model install marker so the isolated support folder sees models.
ln -sf "$HOME/Library/Application Support/Stringer/models-ready" $STRINGER_SUPPORT/models-ready
python3 -I $ROOT/scripts/make-test-audio.py $WORK/fx >/dev/null || exit 1
export STRINGER_REPLAY_SYSTEM=$WORK/fx/system.wav STRINGER_REPLAY_MIC=$WORK/fx/mic.wav
PASS=0 FAIL=0
ok() { print -P "%F{green}PASS%f $1"; ((PASS++)); }
bad() { print -P "%F{red}FAIL%f $1${2:+ — $2}"; ((FAIL++)); }
json() { python3 -I -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
state() { $S status --json | json "' '.join(m['state'] for m in d['active']) or 'idle'"; }
wait_state() {  # id, wanted state, timeout
  local t=0
  while (( t < ${3:-60} * 10 )); do
    local s=$($S ls --json | json "next((m['state'] for m in d if m['id']=='$1'), 'gone')")
    [[ $s == $2 ]] && return 0
    sleep 0.1; ((t++))
  done
  return 1
}
id_of() { json "d['id']"; }

echo "work dir: $WORK"

# L-1: start → stop goes through every state with one owner pid.
export STRINGER_REPLAY_SPEED=1
ID=$($S start --json | id_of)
seen=() pids=()
for i in {1..30}; do
  m=$($S status --json)
  st=$(print -r -- $m | json "next((x['state'] for x in d['active'] if x['id']=='$ID'), 'finished')")
  pid=$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))['pid'])" "$(print -r -- $m | json "next((x['dir'] for x in d['active'] if x['id']=='$ID'), '')")/state.json" 2>/dev/null)
  [[ -n $pid && $pid != 0 ]] && pids+=$pid
  [[ ${seen[-1]:-} != $st ]] && seen+=$st
  (( i == 8 )) && $S stop $ID --no-wait >/dev/null
  [[ $st == finished ]] && break
  sleep 0.5
done
final=$($S ls --json | json "next(m['state'] for m in d if m['id']=='$ID')")
upids=(${(u)pids})
if [[ $final == done && ${#upids} == 1 && " ${seen[*]} " == *" recording "* && " ${seen[*]} " == *" transcribing "* ]]; then
  ok "L-1 states: ${seen[*]} → done; one owner pid (${upids[*]})"
else
  bad "L-1" "seen: ${seen[*]}, final $final, pids ${upids[*]}"
fi

# L-5: start while recording is refused; L-2: stop from two terminals transcribes once.
ID=$($S start --json | id_of)
sleep 3
if $S start >/dev/null 2>&1; then bad "L-5" "a second start was accepted"; else ok "L-5 second start refused while recording"; fi
$S stop $ID >$WORK/stop1.txt 2>&1 &
$S stop $ID >$WORK/stop2.txt 2>&1 &
wait
dir=$($S ls --json | json "next(m['dir'] for m in d if m['id']=='$ID')")
n=$(grep -c 'final pass:' "$dir/worker.log")
if [[ $n == 1 ]] && grep -q done $WORK/stop1.txt && grep -q done $WORK/stop2.txt; then ok "L-2 two stops, transcribed once"; else bad "L-2" "final passes: $n"; fi

# L-6: start while the previous meeting is transcribing — both finish.
export STRINGER_REPLAY_SPEED=1
A=$($S start --title "First" --json | id_of)
sleep 4
$S stop $A --no-wait >/dev/null
for i in {1..50}; do [[ $(state) == *transcribing* ]] && break; sleep 0.1; done
B=$($S start --title "Second" --json | id_of)
if [[ -n $B ]] && wait_state $A done 60; then
  $S stop $B >/dev/null 2>&1
  if wait_state $B done 60; then ok "L-6 started during transcription; both done"; else bad "L-6" "second did not finish"; fi
else
  bad "L-6" "could not start while transcribing, or first did not finish"
fi

# L-3: kill -9 the owner mid-recording, then stop finishes it.
ID=$($S start --json | id_of)
sleep 4
dir=$($S ls --json | json "next(m['dir'] for m in d if m['id']=='$ID')")
owner=$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))['pid'])" "$dir/state.json")
kill -9 $owner
$S stop $ID >/dev/null 2>&1
dir=$($S ls --json | json "next(m['dir'] for m in d if m['id']=='$ID')")
rec=$(grep -o 'pid=[0-9]*' "$dir/capture.log" | head -1 | cut -d= -f2)
if wait_state $ID done 30 && ! kill -0 $rec 2>/dev/null && [[ -s "$dir/transcript.txt" ]]; then
  ok "L-3 owner killed; stop stopped the recorder and finished"
else
  bad "L-3" "state $($S ls --json | json "next(m['state'] for m in d if m['id']=='$ID')")"
fi

# L-4: kill -9 owner and recorder → interrupted; note recovers it.
ID=$($S start --json | id_of)
sleep 5
dir=$($S ls --json | json "next(m['dir'] for m in d if m['id']=='$ID')")
owner=$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))['pid'])" "$dir/state.json")
rec=$(grep -o 'pid=[0-9]*' "$dir/capture.log" | head -1 | cut -d= -f2)
kill -9 $owner $rec
sleep 0.5
st=$($S ls --json | json "next(m['state'] for m in d if m['id']=='$ID')")
$S note $ID --quiet >/dev/null 2>&1
if [[ $st == interrupted ]] && wait_state $ID done 5 && grep -q 'Good morning' "$dir/transcript.txt"; then
  ok "L-4 both killed → interrupted; note recovered the transcript"
else
  bad "L-4" "state after kill: $st"
fi

# L-8: rename while recording, while transcribing, and after done.
ID=$($S start --json | id_of)
sleep 3
$S rename $ID "Renamed While Recording" >/dev/null
$S stop $ID --no-wait >/dev/null
for i in {1..50}; do [[ $(state) == *transcribing* ]] && break; sleep 0.1; done
$S rename $ID "Renamed While Transcribing" >/dev/null
wait_state $ID done 60
dir=$($S ls --json | json "next(m['dir'] for m in d if m['id']=='$ID')")
r1=0; [[ $dir == *"Renamed While Transcribing" ]] && grep -q 'title: Renamed While Transcribing' "$dir/transcript.txt" && r1=1
$S rename $ID "Renamed After Done" >/dev/null
dir=$($S ls --json | json "next(m['dir'] for m in d if m['id']=='$ID')")
r2=0; [[ $dir == *"Renamed After Done" ]] && grep -q 'title: Renamed After Done' "$dir/transcript.txt" && r2=1
if (( r1 && r2 )); then ok "L-8 renamed while recording, transcribing and done; folder and header follow"; else bad "L-8" "folder $dir"; fi

# L-9: cleanup with debug off keeps exactly the transcripts and identity, and a user file.
export STRINGER_DEBUG=false
ID=$($S start --json | id_of)
sleep 3
dir=$($S ls --json | json "next(m['dir'] for m in d if m['id']=='$ID')")
echo mine > "$dir/my notes.md"
$S stop $ID >/dev/null 2>&1
dir=$($S ls --json | json "next(m['dir'] for m in d if m['id']=='$ID')")
left=$(ls "$dir" | sort | tr '\n' '|')
if [[ $left == "live.txt|meeting.json|my notes.md|transcript.txt|" ]]; then ok "L-9 cleanup kept exactly live, transcript, meeting.json and the user's file"; else bad "L-9" "left: $left"; fi

echo "$PASS passed, $FAIL failed (work dir $WORK)"
(( FAIL == 0 ))
