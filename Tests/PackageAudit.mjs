import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(process.argv[2] ?? '.');
const file = path.join(root, 'build', 'Package.ps1');
const source = fs.readFileSync(file, 'utf8');
const failures = [];

function requireMatch(regex, message) {
  if (!regex.test(source)) failures.push(message);
}
function forbidMatch(regex, message) {
  if (regex.test(source)) failures.push(message);
}

// [L6] A package must be composed from source plus an explicit allow-list of outputs produced
// by this invocation. Nested bin/obj trees from a dirty checkout are never copied wholesale.
requireMatch(/Where-Object\s*\{\s*\$_\.Name\s+-in\s+@\('bin','obj'\)\s*\}/s,
  'Package build does not clean stale bin/obj directories before compilation.');
requireMatch(/\$excludedDirectoryNames\s*=\s*@\([^\r\n]*'bin'[^\r\n]*'obj'/,
  'Source staging does not exclude nested bin/obj directories.');
requireMatch(/function\s+Copy-KubeBuildOutput/s,
  'Package build lacks an explicit fresh-output copy primitive.');
requireMatch(/\$unexpectedObj[\s\S]*\$unexpectedBinFiles[\s\S]*allowedBinRoots/s,
  'Package build lacks a post-stage invariant check for unexpected obj/bin artifacts.');
for (const expected of [
  'Runtime/KubeShell.Runtime/bin/Release/net8.0',
  'ObjectModel/KubeShell.ObjectModel/bin/Release/net8.0',
  'Hosting/KubeShell.Hosting/bin/Release/net8.0',
  'Backends/KubeShell.KubectlProcess/bin/Release/net8.0',
  'Libraries/KubeShell.Serialization/bin/Release/net8.0',
  'Backends/KubeShell.KubernetesClient/bin/Release/net8.0',
  'Backends/KubeShell.Kubectl/bin/Release/net8.0',
  'Optional/KubeShell.Provider/bin/Release/net8.0'
]) {
  requireMatch(new RegExp(`Copy-KubeBuildOutput\\s+'${expected.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}'`),
    `Package build does not explicitly stage fresh output: ${expected}`);
}
forbidMatch(/Copy-Item\s+-LiteralPath\s+\$item\.FullName\s+-Destination\s+\$packageRoot\s+-Recurse/s,
  'Package build still recursively copies top-level project trees, allowing stale artifacts to leak into the archive.');

if (failures.length) {
  console.error('Package audit failed:');
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}
console.log('Package reproducibility audit passed.');
