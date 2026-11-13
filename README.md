# k8s-fleet

Flux GitOps for `homelab`, a multi-cloud RKE2 cluster: its platform components, cluster-wide policies and tenants. [k8s-infra](https://github.com/nathansiegfrid/k8s-infra) builds the nodes, then bootstraps Flux from the files in this repository.

## How it reconciles

The FluxInstance syncs `clusters/homelab` from `main`. Its `platform.yaml`, `policies.yaml` and `tenants.yaml` declare one Flux Kustomization per directory in `platform/`, `policies/` and `tenants/`.

Flux runs in multitenant mode: cross-namespace references are off, and a Kustomization or HelmRelease that doesn't name a ServiceAccount impersonates `<namespace>:flux`. The platform's Kustomizations run as `kustomize-controller` and its HelmReleases as `helm-controller`, both cluster-admin.

## Layout

```
clusters/homelab/      the cluster: its FluxInstance, and a Kustomization per component
platform/<component>/  namespace, chart source and version, HelmRelease, values
policies/<policy>/     cluster-wide policies: the host firewall, tenant admission
tenants/               the tenants ResourceSet, one input per tenant
archive/               retired clusters, not reconciled
```

`archive/cluster-01-k3s` is the single-node k3s cluster this repository started with in April 2026, kept as a reference for its cert-manager, Envoy Gateway, Kyverno, Linkerd, monitoring and Sealed Secrets setup.

## Tenants

Each entry in `tenants/tenants.yaml` gets a namespace, a `flux` ServiceAccount that is `admin` there, and a Flux sync of its own repository that runs as that ServiceAccount. The namespace enforces Pod Security `restricted` and is in Istio's ambient mesh. The policies in `policies/tenants` keep its pods off the masters and its Services inside the cluster; traffic from outside comes through the `public` Gateway, where tenants attach HTTPRoutes.

## Secrets

Secrets are encrypted with [SOPS](https://getsops.io/) and age for two keys: Nathan's, to edit them, and the cluster's, so Flux can decrypt them. `.sops.yaml` holds both public keys, and k8s-infra gives Flux the cluster's private key, the `sops-age` Secret, at bootstrap. Only Kustomizations that hold secrets get `decryption`: today, `external-dns` and `cert-manager`.

Create or edit one with `sops`, which encrypts on save, so plaintext never reaches the working tree:

```sh
sops platform/external-dns/cloudflare-api-token.sops.yaml
```

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
