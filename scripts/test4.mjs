import * as grpc from '@grpc/grpc-js'
import { loadSync } from '@grpc/proto-loader'
import { writeFileSync, unlinkSync } from 'fs'

const csrfToken = 'bb63fb52-8f71-4a3c-9b74-de02638140f2'
const proto = `
syntax = "proto3";
package exa.language_server_pb;
service LanguageServerService {
  rpc ConvertTrajectoryToMarkdown(ConvertTrajectoryToMarkdownRequest) returns (ConvertTrajectoryToMarkdownResponse);
}
message Trajectory { string cascade_id = 1; }
message ConvertTrajectoryToMarkdownRequest { Trajectory trajectory = 1; }
message ConvertTrajectoryToMarkdownResponse { string markdown = 1; }
`
writeFileSync('/tmp/t4.proto', proto)
const pkgDef = loadSync('/tmp/t4.proto', { keepCase: false, defaults: true, oneofs: true })
unlinkSync('/tmp/t4.proto')
const pkg = grpc.loadPackageDefinition(pkgDef)
const Svc = pkg?.exa?.language_server_pb?.LanguageServerService
const client = new Svc('localhost:57815', grpc.credentials.createInsecure())
const meta = new grpc.Metadata()
meta.add('x-codeium-csrf-token', csrfToken)

const testIds = [
  '075e5c3e-d415-42db-b3bb-02b57db2cc59',
  '0ec73264-54bf-4c1f-bd94-f4ff84eb601e',
  '1076c4da-d777-40b6-a11d-e2d32c6142b5',
]

for (const id of testIds) {
  try {
    const md = await new Promise((res, rej) =>
      client.convertTrajectoryToMarkdown({ trajectory: { cascadeId: id } }, meta, { deadline: Date.now() + 10000 },
        (e, r) => e ? rej(e) : res(r)))
    console.log(id.slice(0,8) + ': ' + md.markdown?.length + ' chars')
    if (md.markdown?.length > 200) console.log('CONTENT!', md.markdown.slice(0, 400))
  } catch(e) { console.log(id.slice(0,8) + ': ERROR', e.message.slice(0,60)) }
}
client.close()
