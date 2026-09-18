package protocol

// ContractHash is the SHA-256 of contract-v1.json as committed. During the alpha protocol-1
// phase both peers require an exact fingerprint, so any reviewed wire-contract edit changes it.
// Kubernetes/kubectl version upgrades do not change this value unless the KubeShell wire contract changes.
const ContractHash = "859ffcd280d7e1290372c32b5b220682423ee19459375f3663dd871d53aa7fde"
