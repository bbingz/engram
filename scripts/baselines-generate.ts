/**
 * Generate baseline screenshots by running the full UI test suite
 * and copying resulting PNGs to the baselines directory.
 */

import { execSync } from 'child_process';
import fs from 'fs';
import path from 'path';

const baselinesDir = 'macos/EngramUITests/baselines';
const screenshotsDir = process.env.SCREENSHOTS_DIR || '/tmp/engram-screenshots';

console.log('Running full UI test suite...');
execSync(`mkdir -p ${screenshotsDir}`);
execSync(
  `xcodebuild test -project macos/Engram.xcodeproj -scheme Engram ` +
    `-destination 'platform=macOS' SCREENSHOTS_DIR=${screenshotsDir} ` +
    `CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM=""`,
  { stdio: 'inherit' },
);

fs.mkdirSync(baselinesDir, { recursive: true });
const pngs = fs.readdirSync(screenshotsDir).filter((f) => f.endsWith('.png'));
for (const png of pngs) {
  fs.copyFileSync(path.join(screenshotsDir, png), path.join(baselinesDir, png));
}
console.log(`Copied ${pngs.length} baselines to ${baselinesDir}/`);
