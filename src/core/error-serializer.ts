// src/core/error-serializer.ts
export interface SerializedError {
  name: string;
  message: string;
  stack?: string;
  code?: string;
}

export function serializeError(err: unknown): SerializedError {
  if (err instanceof Error) {
    return {
      name: err.name,
      message: err.message,
      stack: err.stack,
      code: (err as any).code,
    };
  }
  return { name: 'UnknownError', message: String(err) };
}
