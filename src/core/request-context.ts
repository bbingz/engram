import { AsyncLocalStorage } from 'node:async_hooks';

interface RequestContext {
  requestId: string;
  spanId?: string;
  source: 'mcp' | 'http' | 'indexer' | 'watcher' | 'scheduler';
}

const als = new AsyncLocalStorage<RequestContext>();

export function runWithContext<T>(ctx: RequestContext, fn: () => T): T {
  return als.run(ctx, fn);
}

export function getRequestContext(): RequestContext | undefined {
  return als.getStore();
}

export function getRequestId(): string | undefined {
  return als.getStore()?.requestId;
}
