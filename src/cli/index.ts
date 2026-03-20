#!/usr/bin/env node
// src/cli/index.ts
// CLI dispatcher: routes to MCP server or resume subcommand

const args = process.argv.slice(2)

if (args.includes('--resume') || args.includes('-r')) {
  // Dynamic import to avoid loading MCP server code
  import('./resume.js')
} else {
  // Default: run MCP server
  import('../index.js')
}
