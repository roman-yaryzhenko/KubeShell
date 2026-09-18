import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import Parser from 'tree-sitter';
import PowerShell from 'tree-sitter-pwsh/bindings/node/index.js';

const root = path.resolve(process.argv[2] ?? path.join(import.meta.dirname, '..'));
const parser = new Parser();
parser.setLanguage(PowerShell);

const expectations = new Map([
    ['Modules/KubeShell.Core/Private/ResourceResolution.ps1::Invoke-KubeTypedGet', 'Invoke-KubeRuntimeGet'],
    ['Modules/KubeShell.Manifests/KubeShell.Manifests.psm1::Set-KubeResourcePatch', 'Invoke-KubeRuntimePatch'],
    ['Modules/KubeShell.Manifests/KubeShell.Manifests.psm1::Set-KubeObject', 'Invoke-KubeRuntimeApply'],
    ['Modules/KubeShell.Operations/Private/Mutations.ps1::Remove-KubeResource', 'Invoke-KubeRuntimeDelete'],
    ['Modules/KubeShell.Operations/Private/Mutations.ps1::Set-KubeCronJobSuspension', 'Invoke-KubeRuntimePatch'],
    ['Optional/KubeShell.Api/KubeShell.Api.psm1::Get-KubeApiResource', 'Invoke-KubeApiClientGet'],
    ['Optional/KubeShell.Api/KubeShell.Api.psm1::Set-KubeApiResourcePatch', 'Invoke-KubeApiClientPatch'],
    ['Optional/KubeShell.Api/KubeShell.Api.psm1::Remove-KubeApiResource', 'Invoke-KubeApiClientDelete'],
]);

const forbiddenRawCalls = new Set([
    'Invoke-KubectlText',
    'Invoke-KubectlResult',
    'Invoke-KubectlNative',
    'Invoke-KubectlJsonStream',
    'Invoke-KubeJson',
]);

function nodeText(source, node) {
    return source.slice(node.startIndex, node.endIndex);
}

function commandName(source, command) {
    const name = command.namedChildren.find(child => child.type === 'command_name');
    if (name) return nodeText(source, name).trim();

    // Commands nested in array/subexpressions can expose their first token without a
    // command_name node in some grammar productions. Use the first visible token only.
    const text = nodeText(source, command).trim();
    const match = /^([A-Za-z][A-Za-z0-9_-]*)\b/.exec(text);
    return match?.[1] ?? null;
}

const seen = new Set();
const violations = [];
const report = [];

for (const relativeFile of [...new Set([...expectations.keys()].map(key => key.split('::', 1)[0]))]) {
    const fullPath = path.join(root, relativeFile);
    const source = fs.readFileSync(fullPath, 'utf8');
    const tree = parser.parse(source);

    for (const fn of tree.rootNode.descendantsOfType('function_statement')) {
        const nameNode = fn.descendantsOfType('function_name')[0];
        if (!nameNode) continue;
        const name = nodeText(source, nameNode);
        const key = `${relativeFile}::${name}`;
        if (!expectations.has(key)) continue;

        seen.add(key);
        const calls = fn.descendantsOfType('command')
            .map(node => commandName(source, node))
            .filter(Boolean);
        const expected = expectations.get(key);
        const raw = calls.filter(call => forbiddenRawCalls.has(call));

        report.push({ key, expected, calls, raw });
        if (!calls.includes(expected)) {
            violations.push(`${key}: expected Runtime boundary call '${expected}' was not found`);
        }
        if (raw.length > 0) {
            violations.push(`${key}: generic resource path still calls raw kubectl adapter(s): ${[...new Set(raw)].join(', ')}`);
        }
    }
}

for (const key of expectations.keys()) {
    if (!seen.has(key)) violations.push(`${key}: expected function was not found`);
}

for (const item of report) {
    console.log(`OK   ${item.key} -> ${item.expected}`);
}

if (violations.length > 0) {
    for (const violation of violations) console.error(`FAIL ${violation}`);
    process.exitCode = 1;
} else {
    console.log(`Architecture boundary audit passed for ${report.length} generic resource paths.`);
}
