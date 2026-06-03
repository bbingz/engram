#!/usr/bin/env node
// src/cli/index.ts
// CLI dispatcher: routes to MCP server, resume, or diagnostic subcommands

import { pathToFileURL } from 'node:url';

type CliModule = {
  main?: (...args: unknown[]) => unknown | Promise<unknown>;
};

type CliImporter = (specifier: string) => Promise<CliModule>;

export async function dispatchCli(
  args = process.argv.slice(2),
  importer: CliImporter = (specifier) => import(specifier),
): Promise<void> {
  const subcommand = args[0];

  if (subcommand === 'logs') {
    const module = await importer('./logs.js');
    await module.main?.(args.slice(1));
  } else if (subcommand === 'traces') {
    const module = await importer('./traces.js');
    await module.main?.(args.slice(1));
  } else if (subcommand === 'health' || subcommand === 'diagnose') {
    const module = await importer('./health.js');
    await module.main?.(subcommand, args.slice(1));
  } else if (subcommand === 'project') {
    const module = await importer('./project.js');
    await module.main?.(args.slice(1));
  } else if (args.includes('--resume') || args.includes('-r')) {
    // Dynamic import to avoid loading MCP server code
    await importer('./resume.js');
  } else {
    // Default: run MCP server
    await importer('../index.js');
  }
}

export function formatCliError(err: unknown): string {
  if (err instanceof Error) {
    return err.stack || err.message;
  }
  return String(err);
}

const invokedPath = process.argv[1] ? pathToFileURL(process.argv[1]).href : '';
if (import.meta.url === invokedPath) {
  dispatchCli().catch((err) => {
    console.error(formatCliError(err));
    process.exitCode = 1;
  });
}
