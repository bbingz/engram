import { relative, resolve, sep } from 'node:path';

export interface SubagentTranscriptLayout {
  parentSessionId: string;
  relativePath: string;
}

export function subagentTranscriptLayout(
  locator: string,
  projectsRoot?: string,
): SubagentTranscriptLayout | undefined {
  const canonical = resolve(locator);
  let components: string[];
  if (projectsRoot) {
    const confined = relative(resolve(projectsRoot), canonical);
    if (confined === '..' || confined.startsWith(`..${sep}`)) return undefined;
    components = confined.split(sep).filter(Boolean);
  } else {
    components = canonical.split(sep).filter(Boolean);
  }
  const index = components.lastIndexOf('subagents');
  if (index < 2 || index + 1 >= components.length) return undefined;
  const tail = components.slice(index + 1);
  const direct = tail.length === 1 && tail[0]?.endsWith('.jsonl');
  const workflow =
    tail.length >= 3 &&
    tail[0] === 'workflows' &&
    tail.at(-1)?.endsWith('.jsonl');
  if (!direct && !workflow) return undefined;
  return {
    parentSessionId: components[index - 1]!,
    relativePath: tail.join('/'),
  };
}
