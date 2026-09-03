#!/usr/bin/env bash
# Append the just-finished member at position $1 to newtips.tsv, verifying its
# segment size against the recorded baseline before accepting it.
set -uo pipefail
WT=/Users/crs58/.treehouse/firstmate-e21abf/1/firstmate
NEWBASE=75b2de262ab03897518908a8a91be2bc234a52db
cd "$WT" || exit 1

want=$1
row=$(awk -F'\t' -v p="$want" '$1==p' cascade-evidence/members.tsv)
[ -n "$row" ] || { echo "NO_SUCH_POS $want"; exit 1; }
IFS=$'\t' read -r pos pr br head obr osha cnt <<< "$row"

have=$(wc -l < cascade-evidence/newtips.tsv | tr -d ' ')
[ "$have" -eq $((want - 1)) ] || { echo "OUT_OF_ORDER have=$have want=$want"; exit 1; }

if [ "$want" -eq 1 ]; then prev="$NEWBASE"; else prev=$(tail -1 cascade-evidence/newtips.tsv | cut -f5); fi

newtip=$(git rev-parse "refs/heads/$br") || exit 1
seg=$(git rev-list --count "$prev".."$newtip")
if [ "$seg" != "$cnt" ]; then
  echo "SEGMENT_SIZE_CHANGED pos=$pos br=$br before=$cnt after=$seg"
  exit 4
fi
printf '%s\t%s\t%s\t%s\t%s\n' "$pos" "$pr" "$br" "$head" "$newtip" >> cascade-evidence/newtips.tsv
echo "RECORDED pos=$pos br=$br new_tip=$newtip commits=$seg"
