import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(process.argv[2] ?? '.');
const protocolRoot = path.join(root, 'native/kubeshell-kubectl/internal/protocol');
const contractPath = path.join(protocolRoot, 'contract-v1.json');
const contractBytes = fs.readFileSync(contractPath);
// Git may materialize text files with CRLF on Windows. The protocol hash is defined
// over the repository's canonical LF representation so checkout policy cannot change it.
const canonicalContractBytes = Buffer.from(contractBytes.toString('utf8').replace(/\r\n?/g, '\n'), 'utf8');
const contract = JSON.parse(canonicalContractBytes.toString('utf8'));
const goProtocol = fs.readFileSync(path.join(protocolRoot, 'types.go'), 'utf8');
const goFrame = fs.readFileSync(path.join(protocolRoot, 'frame.go'), 'utf8');
const goContract = fs.readFileSync(path.join(protocolRoot, 'contract.go'), 'utf8');
const csProtocol = fs.readFileSync(path.join(root, 'Backends/KubeShell.Kubectl/src/Protocol/WireProtocol.cs'), 'utf8');
const apply = fs.readFileSync(path.join(root, 'native/kubeshell-kubectl/host/internal/kube/apply.go'), 'utf8');


// Release metadata is deliberately duplicated across package surfaces. Audit it here so a
// source snapshot cannot advertise one version while the host reports another at handshake.
const packageJson = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
const manifest = fs.readFileSync(path.join(root, 'KubeShell.psd1'), 'utf8');
const managedProject = fs.readFileSync(path.join(root, 'Backends/KubeShell.Kubectl/KubeShell.Kubectl.csproj'), 'utf8');
const handler = fs.readFileSync(path.join(root, 'native/kubeshell-kubectl/host/internal/kube/handler.go'), 'utf8');
const hostGoMod = fs.readFileSync(path.join(root, 'native/kubeshell-kubectl/host/go.mod'), 'utf8');
const releaseVersion = packageJson.version;
const prerelease = capture(manifest, /Prerelease\s*=\s*'([^']+)'/, 'PowerShell prerelease');
const moduleVersion = capture(manifest, /ModuleVersion\s*=\s*'([^']+)'/, 'PowerShell module version');
const managedVersion = capture(managedProject, /<Version>([^<]+)<\/Version>/, 'managed backend version');
const hostVersion = capture(handler, /BuildVersion\s*=\s*"([^"]+)"/, 'Go host build version');
if (`${moduleVersion}-${prerelease}` !== releaseVersion || managedVersion !== releaseVersion || hostVersion !== releaseVersion)
  throw new Error(`Release version drift: package=${releaseVersion}, manifest=${moduleVersion}-${prerelease}, managed=${managedVersion}, host=${hostVersion}`);

// Kubernetes modules move together. Mixing kubectl/client-go/cli-runtime minors is unsupported
// by this adapter because it intentionally relies on upstream kubectl implementation details.
if (!/^go\s+1\.26\.0\s*$/m.test(hostGoMod))
  throw new Error('kubectl-host must require Go 1.26.0 for Kubernetes 0.37.x.');
for (const module of ['k8s.io/api', 'k8s.io/apimachinery', 'k8s.io/cli-runtime', 'k8s.io/client-go', 'k8s.io/kubectl']) {
  const escaped = module.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  if (!new RegExp(`^\\s*${escaped}\\s+v0\\.37\\.0\\s*$`, 'm').test(hostGoMod))
    throw new Error(`kubectl-host Kubernetes module pin drift: ${module} must be v0.37.0.`);
}

function capture(text, regex, label) {
  const match = text.match(regex);
  if (!match) throw new Error(`Cannot find ${label}`);
  return match[1];
}

const expectedHash = crypto.createHash('sha256').update(canonicalContractBytes).digest('hex');
const goHash = capture(goContract, /ContractHash\s*=\s*"([0-9a-f]{64})"/, 'Go contract hash');
const csHash = capture(csProtocol, /ContractHash\s*=\s*"([0-9a-f]{64})"/, 'C# contract hash');
if (goHash !== expectedHash || csHash !== expectedHash)
  throw new Error(`Contract hash mismatch: spec=${expectedHash}, Go=${goHash}, C#=${csHash}`);

const scalarChecks = [
  ['protocol major', contract.protocolMajor, /ProtocolMajor\s+uint16\s*=\s*(\d+)/, /ProtocolMajor\s*=\s*(\d+)/],
  ['protocol minor', contract.protocolMinor, /ProtocolMinor\s+uint16\s*=\s*(\d+)/, /ProtocolMinor\s*=\s*(\d+)/],
  ['header size', contract.frame.headerSize, /HeaderSize\s*=\s*(\d+)/, /HeaderSize\s*=\s*(\d+)/],
];
for (const [label, expected, goRegex, csRegex] of scalarChecks) {
  const go = Number(capture(goFrame, goRegex, `Go ${label}`));
  const cs = Number(capture(csProtocol, csRegex, `C# ${label}`));
  if (go !== expected || cs !== expected) throw new Error(`${label} mismatch: spec=${expected}, Go=${go}, C#=${cs}`);
}
if (!goFrame.includes(`Magic         uint32 = ${contract.frame.magic}`) || !csProtocol.includes(`Magic = ${contract.frame.magic}`))
  throw new Error('Frame magic does not match contract-v1.json.');
if (!goFrame.includes('MaxPayload           = 64 << 20') || !csProtocol.includes('MaxPayload = 64 << 20'))
  throw new Error('Max payload implementation no longer matches the 64 MiB protocol contract.');

const methodNameMap = { DiscoverApiVersion: 'DiscoverAPIVersion', DnsProbe: 'DNSProbe' };
for (const [specName, id] of Object.entries(contract.methods)) {
  const goName = methodNameMap[specName] ?? specName;
  const go = new RegExp(`Method${goName}\\s+Method\\s*=\\s*${id}\\b`);
  const cs = new RegExp(`${specName}\\s*=\\s*${id}\\b`);
  if (!go.test(goProtocol)) throw new Error(`Go protocol method ${goName} != ${id}`);
  if (!cs.test(csProtocol)) throw new Error(`C# protocol method ${specName} != ${id}`);
}

// Go uses iota for kinds/features, so their declaration order is part of protocol v1.
const goKinds = [...goFrame.matchAll(/^\s*Kind([A-Za-z0-9]+)(?:\s+MessageKind\s*=\s*1\s*\+\s*iota)?\s*$/gm)].map(x => x[1]);
const expectedKinds = Object.keys(contract.messageKinds);
if (JSON.stringify(goKinds) !== JSON.stringify(expectedKinds))
  throw new Error(`Go message-kind order drift: ${JSON.stringify(goKinds)}`);
for (const [name, id] of Object.entries(contract.messageKinds)) {
  if (!new RegExp(`\\b${name}(?:\\s*=\\s*${id}\\b|\\s*=\\s*1\\b|\\s*,|\\s*$)`, 'm').test(csProtocol))
    throw new Error(`C# message kind ${name} is missing; enum order/IDs require review.`);
}

const featureNames = Object.keys(contract.features);
const goFeatureNameMap = { Crud: 'CRUD' };
const expectedGoFeatureNames = featureNames.map(name => goFeatureNameMap[name] ?? name);
const goFeatureOrder = [...goProtocol.matchAll(/^\s*Feature([A-Za-z0-9]+)(?:\s+uint64\s*=\s*1\s*<<\s*iota)?\s*$/gm)].map(x => x[1]);
if (JSON.stringify(goFeatureOrder) !== JSON.stringify(expectedGoFeatureNames))
  throw new Error(`Go feature-bit order drift: ${JSON.stringify(goFeatureOrder)}`);
for (const [name, bit] of Object.entries(contract.features)) {
  if (!new RegExp(`${name}\\s*=\\s*1UL\\s*<<\\s*${bit}\\b`).test(csProtocol))
    throw new Error(`C# feature bit ${name} != ${bit}`);
}

if (/NewCmdApply|CheckErr\s*\(/.test(apply))
  throw new Error('Go host must not execute Cobra NewCmdApply/CheckErr paths that can terminate the process.');
if (!/NewApplyFlags/.test(apply) || !/\.ToOptions\(/.test(apply) || !/options\.Validate\(\)/.test(apply) || !/options\.Run\(\)/.test(apply))
  throw new Error('Go host no longer uses the reviewed upstream ApplyFlags -> ToOptions -> Validate -> Run path.');

const productionCs = fs.readdirSync(path.join(root, 'Backends/KubeShell.Kubectl/src'), { recursive: true })
  .filter(name => name.endsWith('.cs'))
  .map(name => fs.readFileSync(path.join(root, 'Backends/KubeShell.Kubectl/src', name), 'utf8'))
  .join('\n');
if (/DllImport|LibraryImport|NativeLibrary\./.test(productionCs))
  throw new Error('Production KubeShell.Kubectl backend contains in-process native interop.');

console.log(`Kubectl IPC protocol audit passed (contract ${expectedHash.slice(0, 12)}…).`);
