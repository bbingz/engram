// src/adapters/grpc/cascade-client.ts
import { readdir, readFile } from 'fs/promises'
import { join } from 'path'
import { writeFileSync, unlinkSync } from 'fs'
import * as grpc from '@grpc/grpc-js'
import { loadSync } from '@grpc/proto-loader'

const PROTO_DEFINITION = `
syntax = "proto3";
package exa.language_server_pb;

service LanguageServerService {
  rpc GetAllCascadeTrajectories(GetAllCascadeTrajectoriesRequest) returns (GetAllCascadeTrajectoriesResponse);
  rpc ConvertTrajectoryToMarkdown(ConvertTrajectoryToMarkdownRequest) returns (ConvertTrajectoryToMarkdownResponse);
}

message GetAllCascadeTrajectoriesRequest {}

message Timestamp {
  int64 seconds = 1;
  int32 nanos = 2;
}

message ConversationAnnotations {
  string title = 1;
}

message CascadeTrajectorySummary {
  string summary = 1;
  string trajectory_id = 4;
  Timestamp created_time = 7;
  Timestamp last_modified_time = 3;
  ConversationAnnotations annotations = 15;
}

message GetAllCascadeTrajectoriesResponse {
  map<string, CascadeTrajectorySummary> trajectory_summaries = 1;
}

// Trajectory message used as input to ConvertTrajectoryToMarkdown
// Field 6 = cascade_id (the .pb file UUID / map key from GetAllCascadeTrajectories)
message Trajectory {
  string cascade_id = 6;
}

message ConvertTrajectoryToMarkdownRequest {
  Trajectory trajectory = 1;
}

message ConvertTrajectoryToMarkdownResponse {
  string markdown = 1;
}
`

export interface ConversationSummary {
  cascadeId: string    // the map key (UUID of the .pb file)
  title: string
  summary: string
  createdAt: string
  updatedAt: string
}

interface DaemonConfig {
  httpsPort: number
  httpPort: number
  csrfToken: string
}

// From protoLoader with keepCase: false, field names are camelCase
interface TrajectorySummaryResponse {
  summary?: string
  trajectoryId?: string
  createdTime?: { seconds?: bigint | number }
  lastModifiedTime?: { seconds?: bigint | number }
  annotations?: { title?: string } | null
}

interface GetAllResponse {
  trajectorySummaries?: Record<string, TrajectorySummaryResponse>
}

interface ConvertResponse {
  markdown?: string
}

export class CascadeGrpcClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private client: any
  private csrfToken: string

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private constructor(client: any, csrfToken: string) {
    this.client = client
    this.csrfToken = csrfToken
  }

  static async fromDaemonDir(daemonDir: string): Promise<CascadeGrpcClient | null> {
    try {
      const files = await readdir(daemonDir)
      const jsonFiles = files.filter(f => f.endsWith('.json'))
      if (jsonFiles.length === 0) return null

      // Pick the most recent json file (ls_*.json)
      const jsonFile = jsonFiles.sort().at(-1)!
      const config = JSON.parse(
        await readFile(join(daemonDir, jsonFile), 'utf8')
      ) as DaemonConfig

      if (!config.httpPort || !config.csrfToken) return null

      // Write proto to temp file (protoLoader doesn't support inline strings)
      const tmpProtoPath = join('/tmp', `cascade-${Date.now()}.proto`)
      writeFileSync(tmpProtoPath, PROTO_DEFINITION)

      let pkgDef
      try {
        pkgDef = loadSync(tmpProtoPath, {
          keepCase: false,
          defaults: true,
          oneofs: true,
        })
      } finally {
        try { unlinkSync(tmpProtoPath) } catch { /* ignore */ }
      }

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const proto = grpc.loadPackageDefinition(pkgDef) as any
      const ServiceClass = proto?.exa?.language_server_pb?.LanguageServerService
      if (!ServiceClass) return null

      // Use httpPort with insecure credentials (httpsPort uses self-signed cert that fails)
      const client = new ServiceClass(
        `localhost:${config.httpPort}`,
        grpc.credentials.createInsecure()
      )

      return new CascadeGrpcClient(client, config.csrfToken)
    } catch {
      return null
    }
  }

  private metadata(): grpc.Metadata {
    const meta = new grpc.Metadata()
    meta.add('x-codeium-csrf-token', this.csrfToken)
    return meta
  }

  private toISOString(seconds: bigint | number | undefined): string {
    if (seconds === undefined || seconds === null) return ''
    return new Date(Number(seconds) * 1000).toISOString()
  }

  async listConversations(): Promise<ConversationSummary[]> {
    return new Promise((resolve, reject) => {
      this.client.getAllCascadeTrajectories(
        {},
        this.metadata(),
        { deadline: Date.now() + 10000 },
        (err: Error | null, response: GetAllResponse) => {
          if (err) { reject(err); return }
          const summaries = response?.trajectorySummaries ?? {}
          const result: ConversationSummary[] = Object.entries(summaries).map(([cascadeId, s]) => ({
            cascadeId,
            title: s.annotations?.title ?? '',
            summary: s.summary ?? '',
            createdAt: this.toISOString(s.createdTime?.seconds),
            updatedAt: this.toISOString(s.lastModifiedTime?.seconds),
          }))
          resolve(result)
        }
      )
    })
  }

  async getMarkdown(cascadeId: string): Promise<string> {
    return new Promise((resolve, reject) => {
      this.client.convertTrajectoryToMarkdown(
        { trajectory: { cascadeId } },
        this.metadata(),
        { deadline: Date.now() + 15000 },
        (err: Error | null, response: ConvertResponse) => {
          if (err) { reject(err); return }
          resolve(response?.markdown ?? '')
        }
      )
    })
  }

  close(): void {
    this.client.close()
  }
}
