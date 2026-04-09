#!/usr/bin/env node
// src/cli/index.ts
// CLI dispatcher: routes to MCP server, resume, or diagnostic subcommands

const args = process.argv.slice(2);
const subcommand = args[0];

if (subcommand === 'logs') {
  import('./logs.js').then((m) => m.main(args.slice(1)));
} else if (subcommand === 'traces') {
  import('./traces.js').then((m) => m.main(args.slice(1)));
} else if (subcommand === 'health' || subcommand === 'diagnose') {
  import('./health.js').then((m) => m.main(subcommand, args.slice(1)));
} else if (args.includes('--resume') || args.includes('-r')) {
  // Dynamic import to avoid loading MCP server code
  import('./resume.js');
} else {
  // Default: run MCP server
  import('../index.js');
}
