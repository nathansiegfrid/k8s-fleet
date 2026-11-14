#!/usr/bin/env bash
# Check what Flux will apply:
#   1. every *.sops.yaml file is actually encrypted, and
#   2. every kustomization builds and matches the Kubernetes and CRD schemas,
#   3. every ResourceSet renders to objects that match them too.
# Needs kustomize (or kubectl), kubeconform and the flux-operator CLI.

set -euo pipefail
cd "$(dirname "$0")/.."

status=0

echo "==> SOPS files"
while IFS= read -r file; do
  if ! grep -q '^sops:' "$file" || ! grep -q 'ENC\[' "$file"; then
    echo "not encrypted: $file" >&2
    status=1
  fi
done < <(find . -name '*.sops.yaml' -not -name .sops.yaml -not -path './.git/*' -not -path './archive/*')

build() {
  if command -v kustomize >/dev/null; then kustomize build "$1"; else kubectl kustomize "$1"; fi
}

schemas=(
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
)

# Encrypted Secrets carry a `sops` block the Secret schema doesn't know.
while IFS= read -r file; do
  dir=$(dirname "$file")
  echo "==> $dir"
  build "$dir" | kubeconform -strict -summary -skip Secret "${schemas[@]}" || status=1
done < <(find . -name kustomization.yaml -not -path './.git/*' -not -path './archive/*' | sort)

# kubeconform only sees the ResourceSet itself, not what it generates.
while IFS= read -r file; do
  echo "==> $file (rendered)"
  flux-operator build resourceset -f "$file" | kubeconform -strict -summary "${schemas[@]}" || status=1
done < <(grep -rl --include='*.yaml' '^kind: ResourceSet' clusters platform policies tenants | sort)

exit "$status"
