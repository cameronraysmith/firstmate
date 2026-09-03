#!/usr/bin/env bash
# For each layer whose patch content changed, list the test files its own
# segment touches and price them from bin/fm-test-run.sh's weight hints.
set -uo pipefail
cd /Users/crs58/.treehouse/firstmate-e21abf/1/firstmate || exit 1
NEWBASE=75b2de262ab03897518908a8a91be2bc234a52db

NEED="1 4 5 9 10 13 15 17 19 21 25 26"

TIP=fm/fm-omp-eval-idle-timeout-clamp
git show "$TIP:bin/fm-test-run.sh" \
  | sed -n '/^portable_serial_weight_hints()/,/^}/p' \
  | grep -E '^tests/' > /tmp/weights.txt
echo "weight hints available: $(wc -l < /tmp/weights.txt)"

total_ms=0
: > /tmp/all-tests.txt
prev="$NEWBASE"
while IFS=$'\t' read -r pos pr br oldtip newtip; do
  case " $NEED " in *" $pos "*) ;; *) prev="$newtip"; continue ;; esac
  files=$(git diff --name-only "$prev".."$newtip" -- 'tests/*.test.sh' | sort -u)
  sum=0
  for f in $files; do
    w=$(awk -v f="$f" '$1==f {print $2}' /tmp/weights.txt)
    [ -n "$w" ] || w=0
    sum=$((sum + w))
    echo "$f" >> /tmp/all-tests.txt
  done
  total_ms=$((total_ms + sum))
  n=$(printf '%s\n' "$files" | grep -c . || true)
  printf 'pos=%-3s %-42s tests=%-3s est=%ss\n' "$pos" "$br" "$n" "$((sum / 1000))"
  for f in $files; do echo "      $f"; done
  prev="$newtip"
done < cascade-evidence/newtips.tsv

echo
echo "distinct test files: $(sort -u /tmp/all-tests.txt | grep -c .)"
echo "summed serial estimate: $((total_ms / 1000))s (~$((total_ms / 60000)) min), excluding 12 branch checkouts"
