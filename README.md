# k8s-fleet

Flux GitOps for `homelab`, a multi-cloud RKE2 cluster: its platform components, cluster-wide policies and tenants. [k8s-infra](https://github.com/nathansiegfrid/k8s-infra) builds the nodes, then bootstraps Flux from the files in this repository.

## Migration in progress

The cluster moves from `clusters/cluster-02-rke2` and `apps/` to `clusters/homelab` and `platform/`, one component at a time. Each step moves the files it reuses; what's left of the old layout isn't reconciled by anything and isn't maintained.

| Component | Where |
| --- | --- |
| Flux Operator, the FluxInstance, Cilium | `platform/`, `clusters/homelab` |
| Gateway API, Istio, the host firewall, tenants | `apps/`, `clusters/cluster-02-rke2`, not migrated yet |

## How it reconciles

The FluxInstance syncs `clusters/homelab` from `main`. Its `platform.yaml` declares one Flux Kustomization per component in `platform/`.

Flux runs in multitenant mode: cross-namespace references are off, and a Kustomization or HelmRelease that doesn't name a ServiceAccount impersonates `<namespace>:flux`. The platform's Kustomizations run as `kustomize-controller` and its HelmReleases as `helm-controller`, both cluster-admin.

## Layout

```
clusters/homelab/      the cluster: its FluxInstance, and a Kustomization per component
platform/<component>/  namespace, chart source and version, HelmRelease, values
archive/               retired clusters, not reconciled
apps/, clusters/cluster-02-rke2/   the old layout, until it's migrated
```

`archive/cluster-01-k3s` is the single-node k3s cluster this repository started with in April 2026, kept as a reference for its cert-manager, Envoy Gateway, Kyverno, Linkerd, monitoring and Sealed Secrets setup.

## Bootstrap

Flux needs a CNI to run, so Cilium has to exist before Flux does, and the FluxInstance needs Flux Operator. k8s-infra installs Cilium and Flux Operator with Helm, then applies the FluxInstance, reading everything from this repository:

| File | Read for |
| --- | --- |
| `platform/<component>/namespace.yaml` | The namespace, with its Pod Security labels |
| `platform/<component>/oci-repository.yaml` | Chart URL and version |
| `platform/<component>/helm-release.yaml` | Release name and namespace |
| `platform/<component>/values.yaml` | Values |
| `clusters/homelab/flux-instance.yaml` | The FluxInstance, applied as is |

Flux then adopts both Helm releases, and from there on manages them, the FluxInstance and itself. An upgrade is a change in this repository only, and the next cluster bootstraps at the same versions.
