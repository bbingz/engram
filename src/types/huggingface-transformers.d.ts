declare module '@huggingface/transformers' {
  export const env: {
    allowRemoteModels: boolean;
    localModelPath: string;
  };
  export function pipeline(
    task: string,
    model: string,
    options?: Record<string, unknown>,
  ): Promise<
    (
      text: string,
      options?: Record<string, unknown>,
    ) => Promise<{ data: Float32Array }>
  >;
}
