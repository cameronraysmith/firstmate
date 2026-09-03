#!/usr/bin/env bash
# PROOF 3: per-branch range-diff of the old segment against the new segment.
# Reports pairs matched (= identical patch, ! changed patch) and any unmatched
# commit in either direction (< only in old, > only in new).
set -uo pipefail
WT=/Users/crs58/.treehouse/firstmate-e21abf/1/firstmate
NEWBASE=75b2de262ab03897518908a8a91be2bc234a52db
cd "$WT" || exit 1

OUT=cascade-evidence/range-diff-detail.txt
: > "$OUT"
fail=0
printf '%-4s %-42s %-6s %-6s %-6s %-6s %s\n' POS BRANCH SAME CHANGED ONLYOLD ONLYNEW VERDICT
prev="$NEWBASE"
while IFS=$'\t' read -r pos pr br oldtip newtip; do
  oldbase=$(awk -F'\t' -v p="$pos" '$1==p {print $6}' cascade-evidence/baseline.tsv)
  rd=$(git range-diff --no-color "$oldbase".."$oldtip" "$prev".."$newtip" 2>&1)

  {
    echo "===== pos=$pos pr=$pr br=$br"
    echo "----- old: $oldbase..$oldtip"
    echo "----- new: $prev..$newtip"
    echo "$rd"
    echo
  } >> "$OUT"

  same=$(printf '%s\n' "$rd"    | grep -cE '^ *[0-9]+: *[0-9a-f]+ = ')
  changed=$(printf '%s\n' "$rd" | grep -cE '^ *[0-9]+: *[0-9a-f]+ ! ')
  onlyold=$(printf '%s\n' "$rd" | grep -cE '^ *[0-9]+: *[0-9a-f]+ < ')
  onlynew=$(printf '%s\n' "$rd" | grep -cE '^ *-+: *-+ > ')

  verdict=PAIRED
  if [ "$onlyold" -ne 0 ] || [ "$onlynew" -ne 0 ]; then verdict=UNMATCHED; fail=1; fi
  printf '%-4s %-42s %-6s %-6s %-6s %-6s %s\n' "$pos" "$br" "$same" "$changed" "$onlyold" "$onlynew" "$verdict"
  prev="$newtip"
done < cascade-evidence/newtips.tsv

echo
echo "RANGEDIFF_FAIL=$fail  detail=$OUT"
