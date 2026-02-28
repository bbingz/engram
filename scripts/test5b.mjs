import * as grpc from '@grpc/grpc-js'
import { loadSync } from '@grpc/proto-loader'
import { writeFileSync, unlinkSync } from 'fs'

const csrfToken = 'bb63fb52-8f71-4a3c-9b74-de02638140f2'
const proto = `
syntax = "proto3";
package exa.language_server_pb;
service LanguageServerService {
  rpc GetUserTrajectory(GetUserTrajectoryRequest) returns (GetUserTrajectoryResponse);
}
message GetUserTrajectoryRequest {
  string cascade_id = 1;
  string trajectory_id = 2;
  int32 segment_index = 3;
}
message GetUserTrajectoryResponse {
  bytes data = 1; string content = 2; string markdown = 3; repeated string messages = 4;
}
`
writeFileSync('/tmp/t5b.proto', proto)
const pkgDef = loadSync('/tmp/t5b.proto', { keepCase: false, defaults: true, oneofs: true })
unlinkSync('/tmp/t5b.proto')
const pkg = grpc.loadPackageDefinition(pkgDef)
const Svc = pkg?.exa?.language_server_pb?.LanguageServerService
const client = new Svc('localhost:57815', grpc.credentials.createInsecure())
const meta = new grpc.Metadata()
meta.add('x-codeium-csrf-token', csrfToken)

// The trajectory_id field value from the list response
const trajectoryIdField = 'cca6e70a-1bbb-4677-b0ed-12fbf38920ff'
const cascadeId = '8bfd6e6a-3443-4299-bc8b-6ac404401f7a'

// Try different combos
const combos = [
  { cascadeId: trajectoryIdField },         // field1 = trajectory_id value  
  { trajectoryId: cascadeId },              // field2 = map key
  { trajectoryId: trajectoryIdField },      // field2 = trajectory_id value  
  { cascadeId: trajectoryIdField, trajectoryId: cascadeId },
]

for (const req of combos) {
  try {
    const resp = await new Promise((res, rej) =>
      client.getUserTrajectory(req, meta, { deadline: Date.now() + 5000 },
        (e, r) => e ? rej(e) : res(r)))
    console.log('Request:', JSON.stringify(req))
    console.log('Response keys:', Object.keys(resp))
    console.log('Response:', JSON.stringify(resp).slice(0, 300))
    break
  } catch(e) { console.log('Req', JSON.stringify(req), '->', e.code, e.message.slice(0, 80)) }
}
client.close()
