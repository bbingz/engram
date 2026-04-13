// src/core/db/alias-repo.ts — project alias management
import type BetterSqlite3 from 'better-sqlite3';

export function resolveProjectAliases(
  db: BetterSqlite3.Database,
  projects: string[],
): string[] {
  if (projects.length === 0) return projects;
  const placeholders = projects.map(() => '?').join(',');
  const rows = db
    .prepare(`
    SELECT DISTINCT alias AS name FROM project_aliases WHERE canonical IN (${placeholders})
    UNION
    SELECT DISTINCT canonical AS name FROM project_aliases WHERE alias IN (${placeholders})
  `)
    .all(...projects, ...projects) as { name: string }[];
  const all = new Set(projects);
  for (const r of rows) all.add(r.name);
  return [...all];
}

export function addProjectAlias(
  db: BetterSqlite3.Database,
  alias: string,
  canonical: string,
): void {
  db.prepare(
    'INSERT OR IGNORE INTO project_aliases (alias, canonical) VALUES (?, ?)',
  ).run(alias, canonical);
}

export function removeProjectAlias(
  db: BetterSqlite3.Database,
  alias: string,
  canonical: string,
): void {
  db.prepare(
    'DELETE FROM project_aliases WHERE alias = ? AND canonical = ?',
  ).run(alias, canonical);
}

export function listProjectAliases(
  db: BetterSqlite3.Database,
): { alias: string; canonical: string }[] {
  return db
    .prepare(
      'SELECT alias, canonical FROM project_aliases ORDER BY canonical, alias',
    )
    .all() as { alias: string; canonical: string }[];
}
