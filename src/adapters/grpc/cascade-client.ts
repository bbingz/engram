// src/adapters/grpc/cascade-client.ts

import { execSync } from 'node:child_process';
import { unlinkSync, writeFileSync } from 'node:fs';
import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import * as grpc from '@grpc/grpc-js';
import { loadSync } from '@grpc/proto-loader';

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
message Trajectory {
  string cascade_id = 1;
}

message ConvertTrajectoryToMarkdownRequest {
  Trajectory trajectory = 1;
}

message ConvertTrajectoryToMarkdownResponse {
  string markdown = 1;
}
`;

export interface ConversationSummary {
  cascadeId: string; // the map key (UUID of the .pb file)
  title: string;
  summary: string;
  createdAt: string;
  updatedAt: string;
  cwd: string; // workspace folder path (from workspaces[0].workspaceFolderAbsoluteUri)
}

interface DaemonConfig {
  httpsPort: number;
  httpPort: number;
  csrfToken: string;
}

// From protoLoader with keepCase: false, field names are camelCase
interface TrajectorySummaryResponse {
  summary?: string;
  trajectoryId?: string;
  createdTime?: { seconds?: bigint | number };
  lastModifiedTime?: { seconds?: bigint | number };
  annotations?: { title?: string } | null;
}

interface GetAllResponse {
  trajectorySummaries?: Record<string, TrajectorySummaryResponse>;
}

interface ConvertResponse {
  markdown?: string;
}

export interface TrajectoryMessage {
  role: 'user' | 'assistant';
  content: string;
}

export class CascadeGrpcClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private client: any;
  private csrfToken: string;
  private port: number;

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private constructor(client: any, csrfToken: string, port: number) {
    this.client = client;
    this.csrfToken = csrfToken;
    this.port = port;
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private static buildGrpcClient(address: string): any {
    const tmpProtoPath = join('/tmp', `cascade-${Date.now()}.proto`);
    writeFileSync(tmpProtoPath, PROTO_DEFINITION);
    try {
      const pkgDef = loadSync(tmpProtoPath, {
        keepCase: false,
        defaults: true,
        oneofs: true,
      });
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const proto = grpc.loadPackageDefinition(pkgDef) as any;
      const ServiceClass =
        proto?.exa?.language_server_pb?.LanguageServerService;
      if (!ServiceClass) return null;
      return new ServiceClass(address, grpc.credentials.createInsecure());
    } finally {
      try {
        unlinkSync(tmpProtoPath);
      } catch {
        /* ignore */
      }
    }
  }

  /**
   * New-style discovery: parse `ps aux` to find the language_server process,
   * extract --csrf_token and the listening port via lsof.
   * Works with Antigravity 1.18+ which no longer writes a JSON discovery file.
   */
  static async fromProcess(): Promise<CascadeGrpcClient | null> {
    try {
      const psOutput = execSync('ps aux', { encoding: 'utf8', timeout: 5000 });
      const lsLine = psOutput
        .split('\n')
        .find(
          (line) =>
            line.includes('language_server_macos') ||
            line.includes('language_server_linux'),
        );
      if (!lsLine) return null;

      const tokenMatch = lsLine.match(/--csrf_token\s+([a-f0-9-]+)/);
      if (!tokenMatch) return null;
      const csrfToken = tokenMatch[1];

      // PID is the second field in ps aux output
      const pid = lsLine.trim().split(/\s+/)[1];

      // Find the HTTP listening port (not the one used for extension server IPC)
      const extensionPortMatch = lsLine.match(
        /--extension_server_port\s+(\d+)/,
      );
      const extensionPort = extensionPortMatch ? extensionPortMatch[1] : null;

      // Filter by PID column — lsof -p doesn't reliably filter LISTEN lines on macOS
      const lsofOutput = execSync(
        `lsof -i -P -n 2>/dev/null | grep "^[^ ]*[[:space:]]*${pid}[[:space:]].*LISTEN"`,
        { encoding: 'utf8', timeout: 5000 },
      );
      // Collect all candidate ports (language server may have TLS + plaintext)
      const ports: number[] = [];
      for (const line of lsofOutput.split('\n')) {
        const portMatch = line.match(/:(\d+)\s+\(LISTEN\)/);
        if (portMatch && portMatch[1] !== extensionPort) {
          ports.push(parseInt(portMatch[1], 10));
        }
      }
      if (ports.length === 0) return null;

      // The server has both TLS and plaintext gRPC ports.
      // Probe each: insecure gRPC fails fast (~16ms) on TLS ports.
      // Return the first port that accepts cleartext connections.
      for (const port of ports) {
        const client = CascadeGrpcClient.buildGrpcClient(`localhost:${port}`);
        if (!client) continue;

        const meta = new grpc.Metadata();
        meta.add('x-codeium-csrf-token', csrfToken);

        const works = await new Promise<boolean>((resolve) => {
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          client.getAllCascadeTrajectories(
            {},
            meta,
            { deadline: Date.now() + 2000 },
            (err: any) => {
              // code 14 = UNAVAILABLE (no TCP connection established) → TLS or not gRPC
              resolve(!err || err.code !== 14);
            },
          );
        });

        if (works) return new CascadeGrpcClient(client, csrfToken, port);
        client.close();
      }

      return null;
    } catch {
      return null;
    }
  }

  /**
   * Old-style discovery: read JSON config file written by the language server.
   * Works with Antigravity < 1.18 and potentially Windsurf.
   */
  static async fromDaemonDir(
    daemonDir: string,
  ): Promise<CascadeGrpcClient | null> {
    try {
      const files = await readdir(daemonDir);
      const jsonFiles = files.filter((f) => f.endsWith('.json'));
      if (jsonFiles.length === 0) return null;

      const jsonFile = jsonFiles.sort().at(-1)!;
      const config = JSON.parse(
        await readFile(join(daemonDir, jsonFile), 'utf8'),
      ) as DaemonConfig;

      if (!config.httpPort || !config.csrfToken) return null;

      const client = CascadeGrpcClient.buildGrpcClient(
        `localhost:${config.httpPort}`,
      );
      if (!client) return null;
      return new CascadeGrpcClient(client, config.csrfToken, config.httpPort);
    } catch {
      return null;
    }
  }

  private metadata(): grpc.Metadata {
    const meta = new grpc.Metadata();
    meta.add('x-codeium-csrf-token', this.csrfToken);
    return meta;
  }

  private toISOString(seconds: bigint | number | undefined): string {
    if (seconds === undefined || seconds === null) return '';
    return new Date(Number(seconds) * 1000).toISOString();
  }

  async listConversations(): Promise<ConversationSummary[]> {
    // Use ConnectRPC JSON instead of gRPC proto to get full response including workspaces
    try {
      const resp = await fetch(
        `http://localhost:${this.port}/exa.language_server_pb.LanguageServerService/GetAllCascadeTrajectories`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'x-codeium-csrf-token': this.csrfToken,
          },
          body: '{}',
          signal: AbortSignal.timeout(10000),
        },
      );
      if (!resp.ok) return this.listConversationsGrpc();

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const data = (await resp.json()) as any;
      const summaries = data?.trajectorySummaries ?? {};

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      return Object.entries(summaries).map(([cascadeId, s]: [string, any]) => {
        // Extract workspace folder path from workspaces array
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const ws = (s?.workspaces as any[])?.[0];
        let cwd = '';
        if (ws?.workspaceFolderAbsoluteUri) {
          // Strip "file://" prefix → absolute path
          cwd = decodeURIComponent(
            ws.workspaceFolderAbsoluteUri.replace(/^file:\/\//, ''),
          );
        }

        // ConnectRPC JSON returns ISO 8601 strings for timestamps
        const createdAt =
          typeof s?.createdTime === 'string'
            ? s.createdTime
            : s?.createdTime?.seconds
              ? new Date(Number(s.createdTime.seconds) * 1000).toISOString()
              : '';
        const updatedAt =
          typeof s?.lastModifiedTime === 'string'
            ? s.lastModifiedTime
            : s?.lastModifiedTime?.seconds
              ? new Date(
                  Number(s.lastModifiedTime.seconds) * 1000,
                ).toISOString()
              : '';

        return {
          cascadeId,
          title: s?.summary ?? '', // ConnectRPC: summary IS the title (no annotations field)
          summary: s?.summary ?? '',
          createdAt,
          updatedAt,
          cwd,
        };
      });
    } catch {
      return this.listConversationsGrpc();
    }
  }

  /** Fallback: list conversations via gRPC proto (no workspace info) */
  private async listConversationsGrpc(): Promise<ConversationSummary[]> {
    return new Promise((resolve, reject) => {
      this.client.getAllCascadeTrajectories(
        {},
        this.metadata(),
        { deadline: Date.now() + 10000 },
        (err: Error | null, response: GetAllResponse) => {
          if (err) {
            reject(err);
            return;
          }
          const summaries = response?.trajectorySummaries ?? {};
          const result: ConversationSummary[] = Object.entries(summaries).map(
            ([cascadeId, s]) => ({
              cascadeId,
              title: s.annotations?.title ?? '',
              summary: s.summary ?? '',
              createdAt: this.toISOString(s.createdTime?.seconds),
              updatedAt: this.toISOString(s.lastModifiedTime?.seconds),
              cwd: '',
            }),
          );
          resolve(result);
        },
      );
    });
  }

  async getMarkdown(cascadeId: string): Promise<string> {
    return new Promise((resolve, reject) => {
      this.client.convertTrajectoryToMarkdown(
        { trajectory: { cascadeId } },
        this.metadata(),
        { deadline: Date.now() + 15000 },
        (err: Error | null, response: ConvertResponse) => {
          if (err) {
            reject(err);
            return;
          }
          resolve(response?.markdown ?? '');
        },
      );
    });
  }

  /**
   * Get conversation messages via ConnectRPC JSON (GetCascadeTrajectory).
   * This is the primary API for reading full conversation content.
   * Falls back to ConvertTrajectoryToMarkdown if the ConnectRPC call fails.
   */
  async getTrajectoryMessages(cascadeId: string): Promise<TrajectoryMessage[]> {
    try {
      const resp = await fetch(
        `http://localhost:${this.port}/exa.language_server_pb.LanguageServerService/GetCascadeTrajectory`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'x-codeium-csrf-token': this.csrfToken,
          },
          body: JSON.stringify({ cascadeId }),
          signal: AbortSignal.timeout(15000),
        },
      );
      if (!resp.ok) return [];

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const data = (await resp.json()) as any;
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const steps: any[] = data?.trajectory?.steps ?? [];

      const messages: TrajectoryMessage[] = [];
      for (const step of steps) {
        const type = (step?.type as string) ?? '';
        if (type.includes('USER_INPUT')) {
          const text = step?.userInput?.userResponse ?? '';
          if (text) messages.push({ role: 'user', content: text });
        } else if (type.includes('PLANNER_RESPONSE')) {
          const text = step?.plannerResponse?.response ?? '';
          if (text) messages.push({ role: 'assistant', content: text });
        } else if (type.includes('NOTIFY_USER')) {
          const text = step?.notifyUser?.notificationContent ?? '';
          if (text) messages.push({ role: 'assistant', content: text });
        }
      }
      return messages;
    } catch {
      return [];
    }
  }

  close(): void {
    this.client.close();
  }
}
