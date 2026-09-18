import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import Parser from 'tree-sitter';
import PowerShell from 'tree-sitter-pwsh/bindings/node/index.js';

const root = path.resolve(process.argv[2] ?? path.join(import.meta.dirname, '..'));
const parser = new Parser();
parser.setLanguage(PowerShell);

function collectFiles(directory, files = []) {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
        if (entry.name === 'node_modules' || entry.name === '.git') {
            continue;
        }

        const fullPath = path.join(directory, entry.name);
        if (entry.isDirectory()) {
            collectFiles(fullPath, files);
            continue;
        }

        if (/\.(ps1|psm1|psd1)$/i.test(entry.name)) {
            files.push(fullPath);
        }
    }

    return files;
}

function collectSyntaxIssues(node, source, issues = []) {
    if (node.type === 'ERROR' || node.isMissing) {
        issues.push({
            type: node.isMissing ? `MISSING:${node.type}` : node.type,
            start: node.startPosition,
            end: node.endPosition,
            text: source.slice(node.startIndex, Math.min(node.endIndex, node.startIndex + 160)),
        });
    }

    for (const child of node.children) {
        collectSyntaxIssues(child, source, issues);
    }

    return issues;
}

function formatPosition(position) {
    return `${position.row + 1}:${position.column + 1}`;
}

const files = collectFiles(root).sort();
let failedFiles = 0;
let issueCount = 0;

for (const file of files) {
    const source = fs.readFileSync(file, 'utf8');
    const tree = parser.parse(source);
    const issues = collectSyntaxIssues(tree.rootNode, source);
    const relativePath = path.relative(root, file);

    if (issues.length === 0) {
        console.log(`OK   ${relativePath}`);
        continue;
    }

    failedFiles += 1;
    issueCount += issues.length;
    console.error(`FAIL ${relativePath}`);

    for (const issue of issues) {
        const snippet = issue.text.replaceAll('\r', '').replaceAll('\n', '\\n');
        console.error(
            `  ${issue.type} ${formatPosition(issue.start)}-${formatPosition(issue.end)} ${snippet}`,
        );
    }
}

console.log(`Checked ${files.length} PowerShell files; ${failedFiles} failed; ${issueCount} issue(s).`);
process.exitCode = failedFiles === 0 ? 0 : 1;
