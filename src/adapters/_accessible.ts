import { stat } from 'node:fs/promises';

/**
 * Default `isAccessible` for adapters whose locator is a real file path.
 * Returns true iff fs.stat succeeds.
 */
export async function isFileAccessible(locator: string): Promise<boolean> {
  if (!locator) return false;
  try {
    await stat(locator);
    return true;
  } catch {
    return false;
  }
}
