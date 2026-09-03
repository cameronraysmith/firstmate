#!/usr/bin/env bash
# Sequential membership-selected cascade of stack 40 onto the new origin/main.
# Never passes --update-refs: backup/cascade-* branches point at member tips
# inside the rebase range and would otherwise be force-updated.
set -uo pipefail

WT=/Users/crs58/.treehouse/firstmate-e21abf/1/firstmate
NEWBASE=75b2de262ab03897518908a8a91be2bc234a52db
cd "$WT" || exit 1

OUT=cascade-evidence/newtips.tsv
[ -f "$OUT" ] || : > "$OUT"

# resume support: skip members already recorded
done_count=$(wc -l < "$OUT" | tr -d ' ')
prev="$NEWBASE"
if [ "$done_count" -gt 0 ]; then
  prev=$(tail -1 "$OUT" | cut -f5)
  echo "RESUMING after $done_count members; prev=$prev"
fi

i=0
while IFS=$'\t' read -r pos pr br head obr osha cnt; do
  i=$((i + 1))
  [ "$i" -le "$done_count" ] && continue

  echo "=== pos=$pos pr=$pr br=$br segment=$cnt old_tip=$head old_parent=$osha new_parent=$prev"
  if ! timeout 300 git rebase --onto "$prev" "$osha" "$br"; then
    echo "CONFLICT_AT pos=$pos pr=$pr br=$br"
    git status --porcelain=v1 | head -30
    exit 3
  fi

  newtip=$(git rev-parse HEAD)
  seg=$(git rev-list --count "$prev".."$newtip")
  if [ "$seg" != "$cnt" ]; then
    echo "SEGMENT_SIZE_CHANGED pos=$pos br=$br before=$cnt after=$seg"
    exit 4
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$pos" "$pr" "$br" "$head" "$newtip" >> "$OUT"
  echo "    -> new_tip=$newtip commits=$seg"
  prev="$newtip"
done < cascade-evidence/members.tsv

echo "CASCADE_COMPLETE final_tip=$prev members=$(grep -c . "$OUT")"
