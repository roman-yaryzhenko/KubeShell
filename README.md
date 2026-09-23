# KubeShell

---

KubeShell is a PowerShell extension for managing Kubernetes clusters, inspired by OpenVMS `SYSMAN`, the desire for consistent command semantics, and the intuitively perceived similarity between PowerShell objects and k8s resources.

## Features

* KubeShell Runtime — a backend-aware library on top of which the cmdlets are built.

* Three backends: one based on the managed C# client, one using a long-lived Go process (essentially a wrapper around some imports from the standard `kubectl`), and one using `kubectl` as a command-line executable.

* A Provider that exposes a tree of items which can be operated on using native PowerShell commands.

## Warnings

The code was written with the use of LLMs and has not yet seen practical use. The process that inspired me to create `KubeShell` had been put on hold by the time this was written.

## TODO

* Test on a real k8s cluster.

* Refactor the code (for example, split some large `.cs` files into smaller ones).

* Add more cmdlets if needed.

##  Notes

Translated from Russian by LLM, reviewed and edited by human.