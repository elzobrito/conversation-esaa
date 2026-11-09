import { readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';

const memoryTests = readdirSync('tests/memory')
  .filter((name) => name.endsWith('.test.js'))
  .sort()
  .map((name) => join('tests/memory', name));
if (memoryTests.length === 0) {
  throw new Error('No memory tests found in tests/memory');
}
const tests = [
  'tests/installer/all.test.js',
  'tests/installer/args.test.js',
  'tests/installer/install.test.js',
  'tests/installer/memory/memory.test.js',
  ...memoryTests,
];
const child = spawnSync(process.execPath, ['--test', ...tests], { stdio: 'inherit' });
if (child.error) throw child.error;
process.exitCode = child.status ?? 1;
