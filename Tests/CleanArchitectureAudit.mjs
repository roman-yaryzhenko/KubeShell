import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const root = path.resolve(process.argv[2] ?? path.join(import.meta.dirname, '..'));
const runtimeSrc = path.join(root, 'Runtime', 'KubeShell.Runtime', 'src');
const managedSrc = path.join(root, 'Backends', 'KubeShell.KubernetesClient', 'src');

function filesUnder(dir, suffix = '.cs') {
    const result = [];
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) result.push(...filesUnder(full, suffix));
        else if (entry.name.endsWith(suffix)) result.push(full);
    }
    return result.sort();
}

const violations = [];
const runtimeFiles = filesUnder(runtimeSrc);
const runtimeText = runtimeFiles.map(file => fs.readFileSync(file, 'utf8')).join('\n');

const forbiddenRuntime = [
    ['PowerShell automation', /System\.Management\.Automation/],
    ['official Kubernetes SDK', /\bKubernetesClient\b|\bk8s\./],
    ['kubectl process backend', /KubeShell\.KubectlProcess/],
    ['native loading/PInvoke', /\bDllImport\b|\bNativeLibrary\b|\bLibraryImport\b/],
    ['HTTP implementation', /\bHttpClient\b|\bHttpRequestMessage\b/],
    ['configuration/file-system infrastructure', /using\s+System\.IO\s*;|\bFile\.|\bDirectory\.|\bOperatingSystem\.|\bEnvironment\.(GetEnvironmentVariable|GetFolderPath)/],
];

for (const [label, pattern] of forbiddenRuntime) {
    if (pattern.test(runtimeText)) violations.push(`Runtime contains forbidden ${label} detail (${pattern}).`);
}

const configText = fs.readFileSync(path.join(runtimeSrc, 'Configuration', 'KubeConfiguration.cs'), 'utf8');
if (/KubeConfigurationStore|LoadDefault\s*\(/.test(configText)) {
    violations.push('Runtime configuration model still owns persistence/default-store loading.');
}

const exceptionText = fs.readFileSync(path.join(runtimeSrc, 'Errors', 'KubeException.cs'), 'utf8');
for (const token of ['HttpStatusCode', 'ExitCode', 'StdErr']) {
    if (exceptionText.includes(token)) violations.push(`Runtime KubeException/KubeError leaks adapter detail '${token}'.`);
}

const resourceClientText = fs.readFileSync(path.join(runtimeSrc, 'Resources', 'KubeResourceClient.cs'), 'utf8');
const operationInterface = /public interface IKubeOperationClient\s*\{([\s\S]*?)\n\}/.exec(resourceClientText)?.[1] ?? '';
const resourceInterface = /public interface IKubeResourceClient\s*\{([\s\S]*?)\n\}/.exec(resourceClientText)?.[1] ?? '';
if (!operationInterface.includes('ExecuteAsync') || /\bGet\s*\(/.test(operationInterface)) {
    violations.push('IKubeOperationClient is not a narrow Evaluate/Execute semantic port.');
}
if (!/\bGet\s*\(/.test(resourceInterface) || !/\bCreate\s*\(/.test(resourceInterface) || !/\bReplace\s*\(/.test(resourceInterface) || resourceInterface.includes('ExecuteAsync')) {
    violations.push('IKubeResourceClient is missing the narrow resource CRUD contract or leaks backend operation routing.');
}
for (const asyncMethod of ['GetAsync','ExistsAsync','TryGetAsync','ListNamesAsync','CreateAsync','ReplaceAsync','ApplyAsync','PatchAsync','DeleteAsync']) {
    if (!resourceInterface.includes(asyncMethod)) violations.push(`IKubeResourceClient is missing cancellable async facade member ${asyncMethod}.`);
}
if (!/public sealed class KubeOperationClient\s*:\s*IKubeOperationClient/.test(resourceClientText) ||
    !/public sealed class KubeResourceClient\s*:\s*IKubeResourceClient/.test(resourceClientText)) {
    violations.push('Operation routing and resource facade are not physically separated into distinct classes.');
}

for (const name of [
    'KubernetesSessionFactory.cs',
    'KubernetesDiscoveryService.cs',
    'KubernetesOperationExecutor.cs',
    'KubernetesResponseMapper.cs',
]) {
    if (!fs.existsSync(path.join(managedSrc, name))) violations.push(`Managed adapter component is missing: ${name}.`);
}
const managedFacade = fs.readFileSync(path.join(managedSrc, 'KubernetesClientBackend.cs'), 'utf8');
if (/LoadKubeConfig|HttpOperationException|ConcurrentDictionary/.test(managedFacade)) {
    violations.push('KubernetesClientBackend facade still owns session/discovery/response infrastructure responsibilities.');
}

if (violations.length > 0) {
    for (const violation of violations) console.error(`FAIL ${violation}`);
    process.exitCode = 1;
} else {
    console.log(`Clean Architecture boundary audit passed (${runtimeFiles.length} Runtime C# files).`);
}
