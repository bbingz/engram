import * as grpc from '@grpc/grpc-js'
import { loadSync } from '@grpc/proto-loader'
import { writeFileSync, unlinkSync } from 'fs'

const csrfToken = 'bb63fb52-8f71-4a3c-9b74-de02638140f2'

// Minimal proto with just GetUserTrajectory to discover its format
const proto = `
syntax = "proto3";
package exa.language_server_pb;
service LanguageServerService {
  rpc GetUserTrajectory(GetUserTrajectoryRequest) returns (GetUserTrajectoryResponse);
  rpc GetUserTrajectoryDebug(GetUserTrajectoryRequest) returns (stream GetUserTrajectoryDebugResponse);
}
// Try different possible request structures
message GetUserTrajectoryRequest {
  string cascade_id = 1;
  string trajectory_id = 2;
  int32 segment_index = 3;
}
message GetUserTrajectoryResponse {
  string content = 1;
  bytes data = 2;
  repeated string messages = 3;
  string markdown = 4;
}
message GetUserTrajectoryDebugResponse {
  string content = 1;
  bytes data = 2;
}
`
writeFileSync('/tmp/t5.proto', proto)
const pkgDef = loadSync('/tmp/t5.proto', { keepCase: false, defaults: true, oneofs: true })
unlinkSync('/tmp/t5.proto')
const pkg = grpc.loadPackageDefinition(pkgDef)
const Svc = pkg?.exa?.language_server_pb?.LanguageServerService
const client = new Svc('localhost:57815', grpc.credentials.createInsecure())
const meta = new grpc.Metadata()
meta.add('x-codeium-csrf-token', csrfToken)

// Test cascade IDs from listConversations
const cascadeId = '8bfd6e6a-3443-4299-bc8b-6ac404401f7a'
const trajectoryId = 'cca6e70a-1bbb-4677-b0ed-12fbf38920ff'  // from trajectory_id field

console.log('Testing GetUserTrajectory...')
try {
  const resp = await new Promise((res, rej) =>
    client.getUserTrajectory({ cascadeId, trajectoryId }, meta, { deadline: Date.now() + 5000 },
      (e, r) => e ? rej(e) : res(r)))
  console.log('Response:', JSON.stringify(resp).slice(0, 500))
} catch(e) { console.log('ERROR:', e.code, e.message.slice(0, 100)) }

client.close()
