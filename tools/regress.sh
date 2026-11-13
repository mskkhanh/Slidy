#!/bin/zsh
# Runs every headless scenario on private copies of the fixture decks and prints one combined, stable report.
# Usage: tools/regress.sh > report.txt   (compare two reports with diff to see what a change did)
# The fixtures live in .fixtures/ (not in git): deck1.pptx (has a table on slide 17) and deck2.pptx.
cd "$(dirname "$0")/.." || exit 1
bin=.build/debug/Slidy
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
run() {   # run <deck> <slide> <ids> ENV=1 ...
  local deck=$1 slide=$2 ids=$3; shift 3
  cp ".fixtures/$deck.pptx" "$work/deck.pptx"
  echo "== $* ($deck slide $slide)"
  env "$@" $bin --drive "$work/deck.pptx" $slide ${=ids} 2>&1 | sed -e "s#$work#WORK#g" -e 's#/private##g' -e 's/[0-9A-F]\{8\}-[0-9A-F-]\{27\}/UUID/g' -e 's/in [0-9.]* s/in N s/g'
}
for deck in deck1 deck2; do
  for scenario in LINKPASTE LINKFIELD LINKS SLIDES GROUPS WAND GROW BOLD LAYER NEWSLIDE DELETESLIDE MOVESLIDE AUTOLIST PASTE FADEKEY CROP SIDEBAR MODIFIED REACH RESIZE DRAG SNAP CARET RENAME RECENTS; do
    run $deck 2 "2 3" $scenario=1
  done
  run $deck 2 "2 3" BADGE=2
done
for scenario in TABLEFADE DELETETABLE DRAGTABLE LAYER PASTE; do run deck1 17 "3" $scenario=1; done
echo "== --verify (deck1)"
cp .fixtures/deck1.pptx "$work/verify.pptx"
$bin --verify "$work/verify.pptx" "$work/out" 2>&1 | grep -v "^Loaded" | tail -3
