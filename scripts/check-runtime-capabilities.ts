import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

type RuntimeCapabilities = {
  sourceNames: string[];
  toolNames: string[];
};

type CapabilityCheck = {
  capabilities: RuntimeCapabilities;
  errors: string[];
};

function read(root: string, path: string): string {
  return readFileSync(join(root, path), 'utf8');
}

export function parseSwiftSourceNames(swift: string): string[] {
  const enumMatch = swift.match(
    /public enum SourceName:[^{]+{\n(?<body>[\s\S]*?)\n}/,
  );
  if (!enumMatch?.groups?.body) {
    throw new Error('Could not find Swift SourceName enum');
  }
  return [
    ...enumMatch.groups.body.matchAll(
      /case\s+([A-Za-z][A-Za-z0-9]*)(?:\s*=\s*"([^"]+)")?/g,
    ),
  ].map(([, caseName, rawValue]) => rawValue ?? caseName);
}

export function documentedToolNames(markdown: string): string[] {
  return [...markdown.matchAll(/^## ([a-z0-9_]+)$/gm)].map((match) => match[1]);
}

export function documentedSourceNames(markdown: string): string[] {
  const match = markdown.match(/Enum: ((?:`[^`]+`(?:, )?)+)/);
  return match ? [...match[1].matchAll(/`([^`]+)`/g)].map((m) => m[1]) : [];
}

function readRuntimeCapabilities(root: string): RuntimeCapabilities {
  const sourceNames = parseSwiftSourceNames(
    read(root, 'macos/Shared/EngramCore/Adapters/SessionAdapter.swift'),
  );
  const toolNames = JSON.parse(
    read(root, 'tests/fixtures/mcp-golden/tools.json'),
  );
  if (
    !Array.isArray(toolNames) ||
    !toolNames.every((tool) => typeof tool === 'string')
  ) {
    throw new Error('MCP golden tools fixture must be an array of tool names');
  }
  return { sourceNames, toolNames };
}

function sameSet(actual: string[], expected: string[]): boolean {
  return (
    actual.length === expected.length &&
    expected.every((item) => actual.includes(item))
  );
}

export function checkRuntimeCapabilities(
  root = process.cwd(),
): CapabilityCheck {
  const capabilities = readRuntimeCapabilities(root);
  const readme = read(root, 'README.md');
  const mcpTools = read(root, 'docs/mcp-tools.md');
  const privacy = read(root, 'docs/PRIVACY.md');
  const mcpServer = read(root, 'macos/EngramMCP/Core/MCPStdioServer.swift');

  const errors: string[] = [];
  const { sourceNames, toolNames } = capabilities;
  const sourceCount = sourceNames.length;
  const toolCount = toolNames.length;

  if (!readme.includes(`聚合 ${sourceCount} `)) {
    errors.push(`README top-line source count must be ${sourceCount}`);
  }
  if (!readme.includes(`active MCP surface has ${toolCount} tools`)) {
    errors.push(
      `README current product state must say active MCP surface has ${toolCount} tools`,
    );
  }
  if (!readme.includes(`Swift MCP runtime 当前暴露 ${toolCount} 个工具`)) {
    errors.push(`README MCP tools section must say ${toolCount} tools`);
  }
  if (!readme.includes('keyword-only in the Swift product path')) {
    errors.push('README must state Swift product search is keyword-only');
  }
  if (
    !readme.includes('semantic / hybrid') ||
    !readme.includes('降级为 keyword')
  ) {
    errors.push('README must name semantic/hybrid degradation to keyword');
  }
  if (!readme.includes('live_sessions') || !readme.includes('unavailable')) {
    errors.push(
      'README must document live_sessions as unavailable in MCP mode',
    );
  }
  if (!readme.includes('peer sync') || !readme.includes('未实现')) {
    errors.push(
      'README must document peer sync as not implemented in Swift service',
    );
  }
  if (!readme.includes('Provider quota/runway')) {
    errors.push(
      'README must document that provider quota/runway is not polled by default',
    );
  }
  if (
    !privacy.includes('Provider quota/runway') ||
    !privacy.includes(
      'does not poll provider quota, billing, pricing, or runway APIs by default',
    ) ||
    !privacy.includes('does not auto-discover provider credentials')
  ) {
    errors.push(
      'docs/PRIVACY.md must document provider quota/runway as local-only by default',
    );
  }

  const totalMatch = mcpTools.match(/\*\*Total tools: (\d+)\*\*/);
  if (Number(totalMatch?.[1]) !== toolCount) {
    errors.push(`docs/mcp-tools.md total tools must be ${toolCount}`);
  }
  const docsToolNames = documentedToolNames(mcpTools);
  if (!sameSet(docsToolNames, toolNames)) {
    const missing = toolNames.filter((tool) => !docsToolNames.includes(tool));
    const extra = docsToolNames.filter((tool) => !toolNames.includes(tool));
    errors.push(
      `docs/mcp-tools.md tool sections must match golden tools; missing=${missing.join(',') || 'none'} extra=${extra.join(',') || 'none'}`,
    );
  }
  const docsSourceNames = documentedSourceNames(mcpTools);
  if (docsSourceNames.join(',') !== sourceNames.join(',')) {
    errors.push(
      'docs/mcp-tools.md source enum must match Swift SourceName order',
    );
  }
  if (!mcpTools.includes('Enum: `keyword`')) {
    errors.push('docs/mcp-tools.md search mode must be keyword-only');
  }
  if (
    !mcpTools.includes('semantic') ||
    !mcpTools.includes('keyword-only results')
  ) {
    errors.push(
      'docs/mcp-tools.md must name semantic/hybrid compatibility downgrade',
    );
  }

  if (!mcpServer.includes(`(${sourceCount} sources)`)) {
    errors.push(`MCP stdio instructions must say ${sourceCount} sources`);
  }

  const forbiddenProductCopy =
    /Ask Engram|card-as-answer|card as answer|chat Q&A|answer-generation/i;
  for (const [path, text] of [
    ['README.md', readme],
    ['docs/mcp-tools.md', mcpTools],
    ['macos/EngramMCP/Core/MCPStdioServer.swift', mcpServer],
  ] as const) {
    if (forbiddenProductCopy.test(text)) {
      errors.push(
        `${path} must not introduce Ask Engram, card-as-answer, chat Q&A, or answer-generation positioning`,
      );
    }
  }

  return { capabilities, errors };
}

function main() {
  const { capabilities, errors } = checkRuntimeCapabilities();
  if (errors.length > 0) {
    console.error(errors.join('\n'));
    process.exit(1);
  }
  console.log(
    `Runtime capability docs match Swift SourceName (${capabilities.sourceNames.length} sources) and MCP golden tools (${capabilities.toolNames.length} tools).`,
  );
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
