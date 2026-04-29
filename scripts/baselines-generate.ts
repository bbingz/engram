/**
 * Generate baseline screenshots by running the full UI test suite
 * and copying resulting PNGs to the baselines directory.
 *
 * XCUITest runner is sandboxed — screenshots land in the sandbox temp dir.
 * After the test run, we copy them out to the baselines directory.
 */

import { execSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const baselinesDir = 'macos/EngramUITests/baselines';

// XCUITest sandbox temp dir where ScreenshotCapture writes PNGs
const sandboxDir = path.join(
  os.homedir(),
  'Library/Containers/com.engram.EngramUITests.xctrunner/Data/tmp/engram-screenshots',
);

// Clean previous screenshots from sandbox
if (fs.existsSync(sandboxDir)) {
  fs.rmSync(sandboxDir, { recursive: true });
}

console.log('Running full UI test suite...');
try {
  execSync(
    `cd macos && xcodegen generate && xcodebuild test -project Engram.xcodeproj -scheme Engram ` +
      `-only-testing:EngramUITests ` +
      `-destination 'platform=macOS' ` +
      `CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM=""`,
    { stdio: 'inherit' },
  );
} catch {
  console.log(
    'Some tests failed — continuing to collect screenshots from passing tests',
  );
}

// Copy screenshots from sandbox to baselines
if (!fs.existsSync(sandboxDir)) {
  console.error(`No screenshots found at ${sandboxDir}`);
  process.exit(1);
}

fs.mkdirSync(baselinesDir, { recursive: true });
const pngs = fs.readdirSync(sandboxDir).filter((f) => f.endsWith('.png'));
for (const png of pngs) {
  fs.copyFileSync(path.join(sandboxDir, png), path.join(baselinesDir, png));
}

// Also copy manifest
const manifestSrc = path.join(sandboxDir, 'test-manifest.json');
if (fs.existsSync(manifestSrc)) {
  fs.copyFileSync(
    manifestSrc,
    path.join(baselinesDir, '..', 'test-manifest.json'),
  );
}

console.log(`Copied ${pngs.length} baselines to ${baselinesDir}/`);
