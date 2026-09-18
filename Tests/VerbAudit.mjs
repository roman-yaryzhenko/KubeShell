import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const root = path.resolve(process.argv[2] ?? path.join(import.meta.dirname, '..'));

// PowerShell 7.6 approved verbs. Runtime.ps1 performs the authoritative
// Get-Verb check when pwsh is available; this static copy keeps the naming
// gate useful in environments that only have Node.
const approvedVerbs = new Set([
  'Add','Approve','Assert','Backup','Block','Checkpoint','Clear','Close','Compare','Complete','Compress','Confirm','Connect',
  'Convert','ConvertFrom','ConvertTo','Copy','Debug','Deny','Disable','Disconnect','Dismount','Edit','Enable','Enter','Exit',
  'Expand','Export','Find','Format','Get','Grant','Group','Hide','Import','Initialize','Install','Invoke','Join','Limit','Lock',
  'Measure','Merge','Mount','Move','New','Open','Optimize','Out','Ping','Pop','Protect','Publish','Push','Read','Receive','Redo',
  'Register','Remove','Rename','Repair','Request','Reset','Resize','Resolve','Restart','Restore','Resume','Revoke','Save','Search',
  'Select','Send','Set','Show','Skip','Split','Start','Step','Stop','Submit','Suspend','Switch','Sync','Test','Trace','Unblock',
  'Undo','Uninstall','Unlock','Unprotect','Unpublish','Unregister','Update','Use','Wait','Watch','Write',
]);

function collectFiles(directory, files = []) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name === '.git') continue;
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) collectFiles(fullPath, files);
    else if (/\.(ps1|psm1)$/i.test(entry.name)) files.push(fullPath);
  }
  return files;
}


function extractQuotedList(source, startPattern, endPattern, label) {
  const start = source.search(startPattern);
  if (start < 0) throw new Error(`Unable to find ${label} start.`);
  const tail = source.slice(start);
  const endMatch = tail.match(endPattern);
  if (!endMatch || endMatch.index === undefined) throw new Error(`Unable to find ${label} end.`);
  const block = tail.slice(0, endMatch.index);
  return [...block.matchAll(/'([^']+)'/g)].map((match) => match[1]);
}

function duplicateValues(values) {
  const counts = new Map();
  for (const value of values) counts.set(value, (counts.get(value) ?? 0) + 1);
  return [...counts.entries()].filter(([, count]) => count > 1).map(([value]) => value);
}

function verbOf(commandName) {
  const dash = commandName.indexOf('-');
  return dash > 0 ? commandName.slice(0, dash) : null;
}

const issues = [];
let functionCount = 0;
let commandShapedAliasCount = 0;


// Root manifest and root-module lists are intentionally duplicated by PowerShell's
// module packaging model. Keep them byte-independent but contract-equivalent.
const manifestSource = fs.readFileSync(path.join(root, 'KubeShell.psd1'), 'utf8');
const rootModuleSource = fs.readFileSync(path.join(root, 'KubeShell.psm1'), 'utf8');
const manifestFunctions = extractQuotedList(
  manifestSource,
  /FunctionsToExport\s*=\s*@\(/m,
  /\n\s*AliasesToExport\s*=/m,
  'manifest FunctionsToExport',
);
const manifestAliases = extractQuotedList(
  manifestSource,
  /AliasesToExport\s*=\s*@\(/m,
  /\n\s*CmdletsToExport\s*=/m,
  'manifest AliasesToExport',
);
const rootFunctions = extractQuotedList(
  rootModuleSource,
  /\$publicFunctions\s*=\s*@\(/m,
  /\n\s*Export-ModuleMember\s+-Function/m,
  'root publicFunctions',
);
const rootAliasExport = extractQuotedList(
  rootModuleSource,
  /Export-ModuleMember\s+-Function\s+\$publicFunctions\s+-Alias\s+@\(/m,
  /\n\s*\)/m,
  'root alias export',
);

for (const [label, values] of [
  ['manifest functions', manifestFunctions],
  ['manifest aliases', manifestAliases],
  ['root functions', rootFunctions],
  ['root aliases', rootAliasExport],
]) {
  for (const duplicate of duplicateValues(values)) {
    issues.push(`${label}: duplicate export ${duplicate}`);
  }
}

const onlyInManifest = manifestFunctions.filter((name) => !rootFunctions.includes(name));
const onlyInRoot = rootFunctions.filter((name) => !manifestFunctions.includes(name));
if (onlyInManifest.length > 0) issues.push(`root exports missing manifest function(s): ${onlyInManifest.join(', ')}`);
if (onlyInRoot.length > 0) issues.push(`manifest exports missing root function(s): ${onlyInRoot.join(', ')}`);

const aliasOnlyInManifest = manifestAliases.filter((name) => !rootAliasExport.includes(name));
const aliasOnlyInRoot = rootAliasExport.filter((name) => !manifestAliases.includes(name));
if (aliasOnlyInManifest.length > 0) issues.push(`root exports missing manifest alias(es): ${aliasOnlyInManifest.join(', ')}`);
if (aliasOnlyInRoot.length > 0) issues.push(`manifest exports missing root alias(es): ${aliasOnlyInRoot.join(', ')}`);

for (const file of collectFiles(root).sort()) {
  const source = fs.readFileSync(file, 'utf8');
  const relativePath = path.relative(root, file);

  for (const match of source.matchAll(/^function\s+([A-Za-z][A-Za-z0-9]*-[A-Za-z0-9_-]+)\b/gim)) {
    functionCount += 1;
    const name = match[1];
    const verb = verbOf(name);
    if (!approvedVerbs.has(verb)) {
      issues.push(`${relativePath}: function ${name} uses unapproved verb ${verb}`);
    }
  }

  // Short shell aliases such as kgp/kwatch are intentionally exempt. An alias
  // that looks like a cmdlet should obey the same verb convention as a cmdlet.
  for (const match of source.matchAll(/Set-Alias\s+(?:-Name\s+)?['"]?([A-Za-z][A-Za-z0-9]*-[A-Za-z0-9_-]+)['"]?/gim)) {
    commandShapedAliasCount += 1;
    const name = match[1];
    const verb = verbOf(name);
    if (!approvedVerbs.has(verb)) {
      issues.push(`${relativePath}: alias ${name} uses unapproved verb ${verb}`);
    }
  }
}

if (issues.length > 0) {
  for (const issue of issues) console.error(`FAIL ${issue}`);
  console.error(`Verb audit failed with ${issues.length} issue(s).`);
  process.exitCode = 1;
} else {
  console.log(`Verb/API audit passed: ${functionCount} functions use approved verbs; root exports ${new Set(rootFunctions).size} functions and ${new Set(rootAliasExport).size} aliases with no duplicates or manifest drift.`);
}
