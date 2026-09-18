import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const root = path.resolve(process.argv[2] ?? path.join(import.meta.dirname, '..'));
const modules = [
  'KubeShell.Core',
  'KubeShell.Shell',
  'KubeShell.Configuration',
  'KubeShell.Operations',
];

const violations = [];

for (const moduleName of modules) {
  const moduleRoot = path.join(root, 'Modules', moduleName);
  const bootstrapPath = path.join(moduleRoot, `${moduleName}.psm1`);
  const privateRoot = path.join(moduleRoot, 'Private');
  const bootstrap = fs.readFileSync(bootstrapPath, 'utf8');

  if (/^\s*function\s+/im.test(bootstrap)) {
    violations.push(`${moduleName}: bootstrap .psm1 contains implementation functions instead of only module bootstrap/export logic.`);
  }

  const declaredBlock = /\$privateScripts\s*=\s*@\(([\s\S]*?)\)\s*\nforeach\s*\(/m.exec(bootstrap)?.[1];
  if (!declaredBlock) {
    violations.push(`${moduleName}: unable to find the explicit private-script load list.`);
    continue;
  }

  const declared = [...declaredBlock.matchAll(/'([^']+\.ps1)'/g)].map(match => match[1]).sort();
  const actual = fs.readdirSync(privateRoot, { withFileTypes: true })
    .filter(entry => entry.isFile() && entry.name.endsWith('.ps1'))
    .map(entry => entry.name)
    .sort();

  if (declared.join('\n') !== actual.join('\n')) {
    violations.push(`${moduleName}: declared Private load list differs from files on disk (declared: ${declared.join(', ')}; actual: ${actual.join(', ')}).`);
  }

  for (const file of actual) {
    const source = fs.readFileSync(path.join(privateRoot, file), 'utf8');
    if (!/^\s*function\s+/im.test(source)) {
      violations.push(`${moduleName}/Private/${file}: no function implementation found.`);
    }
  }

  console.log(`OK   ${moduleName}: ${actual.length} private implementation file(s), thin bootstrap preserved.`);
}

if (violations.length > 0) {
  for (const violation of violations) console.error(`FAIL ${violation}`);
  process.exitCode = 1;
} else {
  console.log(`PowerShell module layout audit passed for ${modules.length} split modules.`);
}
