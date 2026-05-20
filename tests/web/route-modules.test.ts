import { describe, expect, it } from 'vitest';
import { registerAiAuditRoutes } from '../../src/web/routes/ai-audit.js';

describe('web route modules', () => {
  it('exposes AI audit routes from a dedicated module', () => {
    expect(registerAiAuditRoutes).toEqual(expect.any(Function));
  });
});
