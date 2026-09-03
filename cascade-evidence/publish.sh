#!/usr/bin/env bash
# Step 6: ONE atomic push carrying every member refspec with an explicit
# --force-with-lease pinned to that branch's independently recorded old SHA.
# A refused lease aborts the whole push (--atomic) and is a stop-and-report.
set -uo pipefail
cd /Users/crs58/.treehouse/firstmate-e21abf/1/firstmate || exit 1

args=()
while IFS=$'\t' read -r pos pr br oldtip newtip; do
  args+=("--force-with-lease=refs/heads/$br:$oldtip")
  args+=("$newtip:refs/heads/$br")
done < cascade-evidence/newtips.tsv

echo "refspecs=$(( ${#args[@]} / 2 ))"
if [ "${1:-}" = "--dry-run" ]; then
  timeout 300 git push --atomic --dry-run origin "${args[@]}"
else
  timeout 600 git push --atomic origin "${args[@]}"
fi
