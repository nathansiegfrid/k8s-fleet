# k8s-fleet

This repository holds everything that runs on `homelab`, an RKE2 cluster built from VPSs at several providers. The cluster exists to host tenants: each one gets a namespace and deploys from its own git repository, while all of them share the same nodes. [k8s-infra](https://github.com/nathansiegfrid/k8s-infra) builds the nodes and bootstraps Flux. After that, Flux keeps the cluster in sync with this repository's `main` branch.

## Layout

```
clusters/homelab/      the cluster's FluxInstance and a Flux Kustomization per directory below
platform/<component>/  namespace, chart source and version, HelmRelease, values
policies/<policy>/     cluster-wide policies: the host firewall, pods' denied egress, tenant admission
tenants/               the tenants ResourceSet, one input per tenant
```

Flux runs in multitenant mode. Cross-namespace references are turned off, and any Kustomization or HelmRelease that doesn't name a ServiceAccount impersonates `<namespace>:flux`.

## For tenants

A tenant needs only a git repository to run on the cluster. The platform handles the parts a tenant would otherwise have to set up and secure on its own: TLS certificates, DNS records, ingress from the internet, and network isolation.

### Joining

Each tenant is an entry in `tenants/tenants.yaml`. Flux Operator reads it and creates the tenant's namespace, a `flux` ServiceAccount with `admin` (not `cluster-admin`) rights in that namespace, and a Flux sync that pulls the tenant's repository as that ServiceAccount. Private repositories and SOPS encryption are supported: the tenant's deploy key or age key is stored encrypted in `tenants/` and copied into its namespace. After that, the tenant deploys by pushing to its own repository.

### Serving a site

Two shared Gateways take traffic from outside the cluster, and each runs a pod on every worker:

- `public-gateway` serves on the workers' public IPs.
- `private-gateway` serves on the workers' private IPs to VPN clients.

A tenant serves its sites on its own domain, on any DNS provider, without sharing any credentials. To achieve this, two CNAME records are required from the tenant:

- `*.<domain>` (or each subdomain), pointing to `public-gateway.siegfrid.com`
- `_acme-challenge.<domain>`, pointing to `<domain>.acme.siegfrid.com`

`public-gateway.siegfrid.com` is the Gateway's own DNS name. Its A records hold the workers' public IPs and are defined in [`dns-endpoint.yaml`](platform/gateway/public-gateway/dns-endpoint.yaml), so when a worker changes, every tenant's domain follows without needing a DNS change on the tenant's side.

cert-manager follows the `_acme-challenge` CNAME into siegfrid.com and writes the DNS-01 challenge there. The platform then adds a listener and a Let's Encrypt certificate for the domain.

To publish a site, a tenant only needs an HTTPRoute. The certificate renews on its own, and plain HTTP redirects to HTTPS.

### Opening the network

By default, a tenant's pods can reach only their own namespace and `kube-dns`. To reach anything else, such as the internet or another app's API, the tenant adds a NetworkPolicy or a CiliumNetworkPolicy to its own repository. Some addresses, such as the VPN clients and the cloud metadata service, stay blocked and can't be opened, even when the tenant's own policies attempt to allow them.

### Sharing the workers

Each tenant gets a fixed share of the workers: by default, 1 CPU of requests, 4Gi of memory limits, 20Gi of volume claims, 20 pods and 5 volumes. A ResourceQuota enforces it, which the tenant can read but not change, and a larger share is one field on its entry in `tenants.yaml`. A container that doesn't declare its resources gets a request of 10m CPU and 64Mi memory and a memory limit of 256Mi. CPU has no default limit, so an app can use spare CPU when the node has it.

### Leaving

To remove a tenant, delete its entry from `inputs`. That stops its sync, but the namespace and everything running in it stay, along with the network policy and quota. Deleting the namespace is a separate step that someone has to take on purpose, so a typo in `tenants.yaml` can't destroy a tenant's data.

## Security choices

Tenants have `admin` rights in their namespaces, and their pods share nodes with no sandbox between them. So every choice below starts from the same assumption: any tenant's pod, or the app inside it, may be compromised.

### A default network policy in every namespace

We have `default-network-policy`, which allows pods to accept connections only from other pods in their own namespace. Without it, any pod, a tenant's included, could read every flow in the cluster from Hubble Relay, which has no login, list every Service through istiod's plaintext port, and reach other tenants' pods directly instead of going through the Gateways. All of those connections now time out. Traffic that crosses namespaces on purpose, such as webhooks, probes and the Gateways, is allowed by exceptions in each namespace's policy. If a tenant deletes its policy, Flux Operator puts it back.

### Egress closed by default, with denies no allow can override

In tenant namespaces, `default-network-policy` also denies egress by default, so tenant pods can connect only to their own namespace and `kube-dns`. A tenant can lift this restriction with a network policy in its own namespace. For addresses that tenants may not access, `policies/pod-egress` adds Cilium deny rules, which win over any allow.

### A host firewall, since every node faces the internet

Every node is a VPS with a public IP, and the providers share no private network or firewall, so each node should expose only what the mesh needs. Cilium's host firewall, in policies/host-firewall, admits only ping and WireGuard from the internet. VPN clients get a separate range, 10.0.3.0/24, distinct from the nodes' range, 10.0.1.0/24, and can reach only the Kubernetes API and the Gateway pods. The exception is the admin's primary machine, 10.0.3.1, which can also connect over SSH. etcd accepts connections only from the masters. HTTP and HTTPS ports are not opened: Cilium's load balancer sends that traffic directly to the Gateway pods, and their NetworkPolicies decide what gets through. As a result, a connection from the internet to port 80 on a master times out, and the nodes can't even SSH to one another.

### Each VPN device reaches only what it needs

Tenants' devices join the VPN alongside the admin's, so access is restricted per device at two layers: At the network layer, the host firewall lets every VPN client reach the Kubernetes API but limits SSH to the admin's primary machine. On the API, a tenant authenticates with its own kubeconfig, and RBAC confines it to its namespace. At the application layer, the private Gateway preserves each client's source IP, and an AuthorizationPolicy lists the hostnames each device may reach. Envoy answers any other request with a 403. So a tenant's device can be limited to their own domains.

### Admission rules for what Pod Security doesn't cover

Pod Security's `restricted` level blocks root and privileged pods, but it doesn't control where a pod runs or how a Service is exposed. Both matter here. The masters run external-dns, whose Cloudflare token can rewrite every record in the zone, and a Service with external IPs can take over a node's address and port, including the Gateway's (CVE-2020-8554). Two ValidatingAdmissionPolicies in `policies/tenants` close these gaps: tenant pods can't choose a node or tolerate the masters' taint, and tenant Services can only be `ClusterIP`. Tenant pods now run only on the workers. `tenant-01` also deploys `forbidden`, a root pod that Pod Security keeps rejecting, as a standing check that the rule still holds.

## Monitoring

Prometheus scrapes the nodes, Kubernetes, istiod, every node's ztunnel and both Gateways, whose Envoy proxies report requests by status code. The Grafana dashboards are stored in this repository. Alertmanager sends an email when a node or a scrape target goes down, a disk fills up, memory runs low, a pod is crash-looping, a proxy stops getting istiod's config, or one of Flux's platform objects fails to reconcile.

### Logging in to Kiali

Kiali is accessible at `https://kiali.siegfrid.org` over the VPN. It's read-only and asks for a token of the custom `kiali-login` ServiceAccount, which excludes Secrets. Create a long-lived token and keep it in a password manager:

```sh
kubectl -n monitoring create token kiali-login --duration=87600h
```

To revoke every token, delete and recreate the ServiceAccount.

Because a port-forward bypasses NetworkPolicies, it is removed from Kiali's role. As a result, Kiali's proxy sync status and ztunnel views are disabled. You can get the same information from your own machine with `istioctl proxy-status` and `istioctl ztunnel-config`, and Grafana's Istio Control Plane dashboard shows istiod's health. Port-forward to the `gateway` namespace is explicitly allowed for the Gateways' Envoy tab.

### Previewing dashboards

Grafana doesn't save edits to the dashboards it loads from this repository. To check an edit before committing it, run `./scripts/preview-dashboards.sh`. It uploads a copy of every dashboard to a "Dashboard Previews" folder, and needs the VPN and kubectl access to the `grafana-admin` Secret.

## Secrets

Secrets are encrypted with [SOPS](https://getsops.io/) and age for two keys: the admin's, to edit them, and the cluster's, so Flux can decrypt them. k8s-infra gives the cluster's age key to Flux during bootstrap.

## Bootstrap

Flux needs a CNI to run, so Cilium has to be installed before Flux. k8s-infra installs Cilium and Flux Operator with Helm, then applies the FluxInstance. It reads all of these from this repository:

| File | What k8s-infra reads from it |
| --- | --- |
| `platform/<component>/namespace.yaml` | The namespace, with its Pod Security labels |
| `platform/<component>/oci-repository.yaml` | Chart URL and version |
| `platform/<component>/helm-release.yaml` | Release name and namespace |
| `platform/<component>/values.yaml` | Values |
| `clusters/homelab/flux-instance.yaml` | The FluxInstance, applied as is |

Moving or renaming these files breaks the next bootstrap. Once the cluster is up, Flux adopts both Helm releases.

## Upgrades

[Renovate](https://docs.renovatebot.com/) opens a pull request for each new chart version. A new Gateway API release waits for approval in the Dependency Dashboard, because its version has to match the one Istio is built against.

## Validating

```sh
./scripts/validate.sh
```

The script builds every kustomization and the tenants ResourceSet, validates the output against the Kubernetes and CRD schemas, checks Prometheus's rules, and fails if any `*.sops.yaml` file isn't encrypted. CI runs it on every push to `main` and on pull requests. It needs kustomize or kubectl, [kubeconform](https://github.com/yannh/kubeconform), the [flux-operator CLI](https://github.com/controlplaneio-fluxcd/flux-operator/releases) and promtool.
