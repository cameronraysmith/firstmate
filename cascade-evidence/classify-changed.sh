#!/usr/bin/env bash
# Split the range-diff's changed ("!") pairs into context-only (every differing
# line is a hunk header) and content-changed (a real +/- body line differs).
set -uo pipefail
cd /Users/crs58/.treehouse/firstmate-e21abf/1/firstmate || exit 1

python3 - <<'PY'
import re, collections

pos = None
cur = None
res = collections.OrderedDict()

hdr = re.compile(r'^===== pos=(\d+) pr=(\d+) br=(\S+)')
pair = re.compile(r'^ *(\d+): *([0-9a-f]+) ([=!<]) *(?:(\d+|-+): *([0-9a-f]+|-+))? ?(.*)$')

for line in open('cascade-evidence/range-diff-detail.txt'):
    m = hdr.match(line)
    if m:
        pos, pr, br = int(m.group(1)), m.group(2), m.group(3)
        res.setdefault(pos, {'br': br, 'pairs': []})
        cur = None
        continue
    m = pair.match(line.rstrip('\n'))
    if m and m.group(3) in '=!<':
        cur = {'op': m.group(3), 'subject': m.group(6), 'content': False}
        res[pos]['pairs'].append(cur)
        continue
    if cur is None or cur['op'] != '!':
        continue
    body = line.rstrip('\n')
    s = body.lstrip()
    if s.startswith(('--@@', '++@@', '-@@', '+@@')):
        continue
    if re.match(r'^ *[-+]', body) and not re.match(r'^ *[-+] ', body):
        cur['content'] = True

print(f"{'POS':<4} {'BRANCH':<42} {'CTXONLY':<8} {'CONTENT':<8} SUBJECTS_WITH_CONTENT_CHANGE")
need = []
for p, d in res.items():
    ch = [x for x in d['pairs'] if x['op'] == '!']
    ctx = [x for x in ch if not x['content']]
    con = [x for x in ch if x['content']]
    if con:
        need.append((p, d['br']))
    print(f"{p:<4} {d['br']:<42} {len(ctx):<8} {len(con):<8} " + ("; ".join(x['subject'][:60] for x in con) if con else "-"))

print()
print("LAYERS_NEEDING_TEST_RERUN:")
for p, br in need:
    print(f"  pos={p} {br}")
PY
