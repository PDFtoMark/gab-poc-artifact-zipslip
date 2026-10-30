import { readFileSync } from 'node:fs'
import { createHash } from 'node:crypto'

const zipPath = process.env.INPUT_PATH
const name = process.env.INPUT_NAME || 'bundle-size-report'
const token = process.env.ACTIONS_RUNTIME_TOKEN
const results = process.env.ACTIONS_RESULTS_URL

if (!token || !results) {
  console.log('missing runtime env', Object.keys(process.env).filter(k => k.startsWith('ACTIONS_')))
  process.exit(1)
}

const claims = JSON.parse(
  Buffer.from(
    token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'),
    'base64'
  ).toString()
)
const scope = claims.scp.split(' ').find(s => s.startsWith('Actions.Results:'))
const [, wr, jr] = scope.split(':')
const service = `${new URL(results).origin}/twirp/github.actions.results.api.v1.ArtifactService`
const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }

const created = await (
  await fetch(`${service}/CreateArtifact`, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      workflow_run_backend_id: wr,
      workflow_job_run_backend_id: jr,
      name,
      mime_type: 'application/zip',
      version: 7
    })
  })
).json()
console.log('create:', JSON.stringify(created).slice(0, 300))
if (!created.signed_upload_url) process.exit(1)

const data = readFileSync(zipPath)
const put = await fetch(created.signed_upload_url, {
  method: 'PUT',
  headers: {
    'x-ms-blob-type': 'BlockBlob',
    'x-ms-version': '2021-12-02',
    'Content-Type': 'application/zip'
  },
  body: data
})
console.log('put:', put.status, (await put.text()).slice(0, 200))

const hash = createHash('sha256').update(data).digest('hex')
const finalized = await (
  await fetch(`${service}/FinalizeArtifact`, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      workflow_run_backend_id: wr,
      workflow_job_run_backend_id: jr,
      name,
      size: String(data.length),
      hash: `sha256:${hash}`
    })
  })
).json()
console.log('finalize:', JSON.stringify(finalized))
