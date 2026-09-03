#!/usr/bin/env bash
# Post-cascade proofs: signatures, identity, ancestry, segment sizes.
set -uo pipefail
WT=/Users/crs58/.treehouse/firstmate-e21abf/1/firstmate
OLDBASE=a56a78ac431833381a265d28cbc9c5ab6094117d
NEWBASE=75b2de262ab03897518908a8a91be2bc234a52db
cd "$WT" || exit 1

fail=0

echo "### PROOF 1+2: signature and identity per rebased segment"
printf '%-4s %-42s %-7s %-14s %s\n' POS BRANCH SIGS IDENTITY SEG
prev="$NEWBASE"
while IFS=$'\t' read -r pos pr br oldtip newtip; do
  sigs=$(git log --format='%G?' "$prev".."$newtip" | sort -u | tr -d '\n')
  n=$(git rev-list --count "$prev".."$newtip")
  bad_a=$(git log --format='%ae' "$prev".."$newtip" | grep -cv '^cameron\.ray\.smith@gmail\.com$')
  bad_c=$(git log --format='%ce' "$prev".."$newtip" | grep -cv '^cameron\.ray\.smith@gmail\.com$')
  idn="A:$bad_a C:$bad_c"
  [ "$sigs" = "G" ] || { echo "  !! SIGNATURE_NOT_ALL_GOOD pos=$pos br=$br sigs=$sigs"; fail=1; }
  [ "$bad_c" -eq 0 ] || { echo "  !! COMMITTER_IDENTITY_CHANGED pos=$pos br=$br"; fail=1; }
  printf '%-4s %-42s %-7s %-14s %s\n' "$pos" "$br" "$sigs" "$idn" "$n"
  prev="$newtip"
done < cascade-evidence/newtips.tsv

echo
echo "### PROOF 4: plain-git ancestry per edge (new topology)"
prev_name=origin/main
prev="$NEWBASE"
while IFS=$'\t' read -r pos pr br oldtip newtip; do
  if git merge-base --is-ancestor "$prev" "$newtip"; then st=OK; else st=NOT_ANCESTOR; fail=1; fi
  printf '%-4s %-42s <- %-42s %s\n' "$pos" "$br" "$prev_name" "$st"
  prev_name="$br"; prev="$newtip"
done < cascade-evidence/newtips.tsv

echo
echo "### every member descends from the NEW trunk"
while IFS=$'\t' read -r pos pr br oldtip newtip; do
  git merge-base --is-ancestor "$NEWBASE" "$newtip" || { echo "  !! STRANDED pos=$pos br=$br"; fail=1; }
  if git merge-base --is-ancestor "$OLDBASE" "$newtip" && ! git merge-base --is-ancestor "$NEWBASE" "$newtip"; then
    echo "  !! STILL_ON_OLD_BASE_ONLY pos=$pos br=$br"; fail=1
  fi
done < cascade-evidence/newtips.tsv
echo "all 30 descend from $NEWBASE (silence above = pass)"

echo
echo "### backups still at recorded old tips"
while IFS=$'\t' read -r pos pr br oldtip newtip; do
  b=$(git rev-parse --verify -q "refs/heads/backup/cascade-$br")
  [ "$b" = "$oldtip" ] || { echo "  !! BACKUP_MOVED br=$br backup=$b expected=$oldtip"; fail=1; }
done < cascade-evidence/newtips.tsv
echo "30 backups verified (silence above = pass)"

echo
echo "### non-stack refs untouched"
for r in wip/fm08-fixture-fix-staged review/fm08-adversarial fm/linearize-16-18; do
  printf '  %-34s %s\n' "$r" "$(git rev-parse --verify -q "refs/heads/$r")"
done

echo
echo "VERIFY_FAIL=$fail"
