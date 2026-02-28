// Run: node scripts/test-grpc.mjs  (requires Windsurf to be running)
// Tests different cascade_id field numbers to find the correct proto definition.
import { readdir, readFile } from 'fs/promises'
import { join } from 'path'
import { homedir } from 'os'
import { writeFileSync, unlinkSync } from 'fs'
import * as grpc from '@grpc/grpc-js'
import { loadSync } from '@grpc/proto-loader'

const daemonDir = join(homedir(), '.gemini', 'antigravity', 'daemon')

async function getConfig() {
  // Try new process-based discovery (Antigravity 1.18+)
  try {
    const { execSync } = await import('child_process')
    const psOutput = execSync('ps aux', { encoding: 'utf8' })
    const lsLine = psOutput.split('\n').find(l => l.includes('language_server_macos') || l.includes('language_server_linux'))
    if (lsLine) {
      const tokenMatch = lsLine.match(/--csrf_token\s+([a-f0-9-]+)/)
      const pid = lsLine.trim().split(/\s+/)[1]
      const extPortMatch = lsLine.match(/--extension_server_port\s+(\d+)/)
      const extPort = extPortMatch?.[1]
      if (tokenMatch && pid) {
        const lsofOut = execSync(`lsof -i -P -n 2>/dev/null | grep "^[^ ]*[[:space:]]*${pid}[[:space:]].*LISTEN"`, { encoding: 'utf8' })
        const ports = []
        for (const line of lsofOut.split('\n')) {
          const portMatch = line.match(/:(\d+)\s+\(LISTEN\)/)
          if (portMatch && portMatch[1] !== extPort) ports.push(parseInt(portMatch[1]))
        }
        // Probe each port — server has both TLS and plaintext gRPC ports
        for (const port of ports) {
          const client = makeClient({ httpPort: port, csrfToken: tokenMatch[1] }, 1)
          const meta = new grpc.Metadata()
          meta.add('x-codeium-csrf-token', tokenMatch[1])
          const ok = await new Promise(res => {
            client.getAllCascadeTrajectories({}, meta, { deadline: Date.now() + 2000 },
              (err) => { res(!err || err.code !== 14) })
          })
          client.close()
          if (ok) {
            console.log(`Found via process: port=${port}, token=${tokenMatch[1]}`)
            return { httpPort: port, csrfToken: tokenMatch[1] }
          }
        }
      }
    }
  } catch { /* fall through */ }

  // Fall back to old JSON discovery file
  try {
    const files = await readdir(daemonDir)
    const jsonFile = files.filter(f => f.endsWith('.json')).sort().at(-1)
    if (jsonFile) return JSON.parse(await readFile(join(daemonDir, jsonFile), 'utf8'))
  } catch { /* fall through */ }

  console.error('Could not find language server — is Antigravity running?'); process.exit(1)
}

function makeClient(config, fieldNum) {
  const proto = `
syntax = "proto3";
package exa.language_server_pb;
service LanguageServerService {
  rpc GetAllCascadeTrajectories(GetAllCascadeTrajectoriesRequest) returns (GetAllCascadeTrajectoriesResponse);
  rpc ConvertTrajectoryToMarkdown(ConvertTrajectoryToMarkdownRequest) returns (ConvertTrajectoryToMarkdownResponse);
}
message GetAllCascadeTrajectoriesRequest {}
message Timestamp { int64 seconds = 1; int32 nanos = 2; }
message ConversationAnnotations { string title = 1; }
message CascadeTrajectorySummary {
  string summary = 1; string trajectory_id = 4;
  Timestamp created_time = 7; Timestamp last_modified_time = 3;
  ConversationAnnotations annotations = 15;
}
message GetAllCascadeTrajectoriesResponse {
  map<string, CascadeTrajectorySummary> trajectory_summaries = 1;
}
message Trajectory { string cascade_id = ${fieldNum}; }
message ConvertTrajectoryToMarkdownRequest { Trajectory trajectory = 1; }
message ConvertTrajectoryToMarkdownResponse { string markdown = 1; }
`
  const tmpPath = `/tmp/test-cascade-${fieldNum}.proto`
  writeFileSync(tmpPath, proto)
  try {
    const pkgDef = loadSync(tmpPath, { keepCase: false, defaults: true, oneofs: true })
    const pkg = grpc.loadPackageDefinition(pkgDef)
    const Svc = pkg?.exa?.language_server_pb?.LanguageServerService
    const client = new Svc(`localhost:${config.httpPort}`, grpc.credentials.createInsecure())
    return client
  } finally {
    try { unlinkSync(tmpPath) } catch {}
  }
}

async function main() {
  const config = await getConfig()
  const meta = new grpc.Metadata()
  meta.add('x-codeium-csrf-token', config.csrfToken)

  // Get a cascadeId to test with
  const listClient = makeClient(config, 1)
  const conversations = await new Promise((res, rej) =>
    listClient.getAllCascadeTrajectories({}, meta, { deadline: Date.now() + 10000 },
      (err, r) => { if (err) rej(err); else res(r) }))
  listClient.close()

  const ids = Object.keys(conversations?.trajectorySummaries ?? {})
  if (!ids.length) { console.log('No conversations found'); return }
  console.log(`Testing with cascadeId: ${ids[0]}\n`)

  for (const fieldNum of [1, 2, 3, 4, 5, 6, 7, 8]) {
    const client = makeClient(config, fieldNum)
    try {
      const result = await new Promise((res, rej) =>
        client.convertTrajectoryToMarkdown(
          { trajectory: { cascadeId: ids[0] } }, meta, { deadline: Date.now() + 10000 },
          (err, r) => { if (err) rej(err); else res(r) }))
      const len = result?.markdown?.length ?? 0
      console.log(`cascade_id = ${fieldNum}: markdown ${len} chars ${len > 0 ? '✅ CORRECT!' : '(empty)'}`)
      if (len > 0) { console.log('\nFirst 200 chars:', result.markdown.slice(0, 200)); break }
    } catch (e) {
      console.log(`cascade_id = ${fieldNum}: error — ${e.message}`)
    } finally {
      client.close()
    }
  }
}
main().catch(console.error)
