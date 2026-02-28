import { readFileSync, writeFileSync, unlinkSync } from 'fs'
import * as grpc from '@grpc/grpc-js'
import { loadSync } from '@grpc/proto-loader'
import { execSync } from 'child_process'

// Find language server
const psOutput = execSync('ps aux', { encoding: 'utf8' })
const lsLine = psOutput.split('\n').find(l => l.includes('language_server_macos'))
const tokenMatch = lsLine.match(/--csrf_token\s+([a-f0-9-]+)/)
const csrfToken = tokenMatch[1]

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
message Trajectory { string cascade_id = 1; }
message ConvertTrajectoryToMarkdownRequest { Trajectory trajectory = 1; }
message ConvertTrajectoryToMarkdownResponse { string markdown = 1; }
`
writeFileSync('/tmp/t3.proto', proto)
const pkgDef = loadSync('/tmp/t3.proto', { keepCase: false, defaults: true, oneofs: true })
unlinkSync('/tmp/t3.proto')
const pkg = grpc.loadPackageDefinition(pkgDef)
const Svc = pkg?.exa?.language_server_pb?.LanguageServerService
const client = new Svc('localhost:57815', grpc.credentials.createInsecure())
const meta = new grpc.Metadata()
meta.add('x-codeium-csrf-token', csrfToken)

// Get all trajectories and check trajectory_id field
const all = await new Promise((res, rej) =>
  client.getAllCascadeTrajectories({}, meta, { deadline: Date.now() + 10000 }, (e, r) => e ? rej(e) : res(r)))

const entries = Object.entries(all.trajectorySummaries ?? {}).slice(0, 3)
for (const [mapKey, s] of entries) {
  console.log('map key:', mapKey.slice(0,8))
  console.log('trajectory_id field:', s.trajectoryId)  // camelCase from keepCase:false
  
  // Try with trajectory_id field value
  if (s.trajectoryId) {
    const md = await new Promise((res, rej) =>
      client.convertTrajectoryToMarkdown(
        { trajectory: { cascadeId: s.trajectoryId } }, meta, { deadline: Date.now() + 10000 },
        (e, r) => e ? rej(e) : res(r)))
    console.log('  using trajectoryId field -> markdown:', md.markdown?.length, 'chars')
    if (md.markdown?.length > 200) console.log('  preview:', md.markdown.slice(0, 200))
  }
  console.log()
}
client.close()
