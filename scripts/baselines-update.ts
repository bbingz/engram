/**
 * Selectively update baseline screenshots from the latest test run.
 * Optionally filter by page prefix: npm run baselines:update -- HomeView
 */

import fs from 'fs';
import path from 'path';

const baselinesDir = 'macos/EngramUITests/baselines';
const screenshotsDir = process.env.SCREENSHOTS_DIR || '/tmp/engram-screenshots';
const pageFilter = process.argv[2];

const pngs = fs.readdirSync(screenshotsDir).filter((f) => f.endsWith('.png'));
const filtered = pageFilter ? pngs.filter((f) => f.startsWith(pageFilter)) : pngs;

fs.mkdirSync(baselinesDir, { recursive: true });
for (const png of filtered) {
  fs.copyFileSync(path.join(screenshotsDir, png), path.join(baselinesDir, png));
}
console.log(`Updated ${filtered.length} baselines${pageFilter ? ` (filter: ${pageFilter}*)` : ''}`);
