#!/bin/sh
# Re-render this kit: edm, seed 4242, structure standard, offline (no app).
set -e
cd "$(dirname "$0")"
D=../../.build/release/djctl
r() { name=$1; opts=$2; shift 2; echo "== $name  $opts $*"; $D render edm 4242 "$name.wav" --structure standard --options "$opts" "$@"; }
ALL='{"hook":true,"chordSnap":"strong","layerBudget":"auto","melodyDensity":0.35,"ghostNotes":0.1,"bassFollow":true}'
r 00-baseline '{}'
r 01-hook '{"hook":true}'
r 01b-chordSnap '{"chordSnap":"strong"}'
r 01c-keyLock '{"keyLock":true}'
r 02-hook+chordSnap '{"hook":true,"chordSnap":"strong"}'
r 03-hook+chordSnap+layerBudget-auto '{"hook":true,"chordSnap":"strong","layerBudget":"auto"}'
r 04-all "$ALL"
r 04-stem-drums+bass "$ALL" --solo drums,bass
r 04-stem-drums+bass+melody "$ALL" --solo drums,bass,melody
r 04-stem-no-melody "$ALL" --mute melody
