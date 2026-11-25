#!/usr/bin/env bash
# Upload every dashboard to Grafana's "Dashboard Previews" folder, to see
# edits before a commit. Each copy keeps its title; its uid gets "-preview".
# Needs kubectl access to the grafana-admin Secret, jq, curl and the VPN.

set -euo pipefail
cd "$(dirname "$0")/.."

url=${GRAFANA_URL:-https://grafana.siegfrid.org}
folder=dashboard-previews

# The dashboards are the JSON files in the grafana-dashboards ConfigMap, so
# its generator says where they live.
kustomization=$(grep -rl --include=kustomization.yaml 'name: grafana-dashboards$' platform || true)
if [[ -z $kustomization || $kustomization == *$'\n'* ]]; then
  echo "expected one kustomization generating grafana-dashboards, found: ${kustomization:-none}" >&2
  exit 1
fi
base=$(dirname "$kustomization")
listed=$(sed -nE 's/^[[:space:]]*- ([^[:space:]]+\.json)$/\1/p' "$kustomization")
dir=$base/$(dirname "$(head -n 1 <<<"$listed")")

secret=$(kubectl -n monitoring get secret grafana-admin -o json)
auth=$(jq -r '(.data["admin-user"] | @base64d) + ":" + (.data["admin-password"] | @base64d)' <<<"$secret")

api() {
  local method=$1 path=$2
  shift 2
  curl -sS --fail-with-body -u "$auth" -H 'Content-Type: application/json' -X "$method" "$url$path" "$@"
}

if ! api GET "/api/folders/$folder" >/dev/null 2>&1; then
  response=$(api POST /api/folders --data "{\"uid\": \"$folder\", \"title\": \"Dashboard Previews\"}") ||
    { echo "can't create the Dashboard Previews folder: $response" >&2; exit 1; }
fi

status=0
uploaded=()
for file in "$dir"/*.json; do
  # A file missing from the generator uploads here but never reaches Grafana.
  if ! grep -qxF "${file#"$base"/}" <<<"$listed"; then
    echo "warning: $file isn't in the grafana-dashboards generator" >&2
  fi
  uid=$(jq -r '.uid // empty' "$file" 2>/dev/null) || true
  if [[ -z $uid ]]; then
    echo "skipped $file: not JSON, or no uid" >&2
    status=1
    continue
  fi
  uid=$uid-preview
  if response=$(jq --arg folder "$folder" --arg uid "$uid" \
    '{dashboard: (. + {id: null, uid: $uid}), folderUid: $folder, overwrite: true}' "$file" |
    api POST /api/dashboards/db --data-binary @-); then
    echo "$file -> $url/d/$uid"
    uploaded+=("$uid")
  else
    echo "failed: $file: $response" >&2
    status=1
  fi
done

# Remove copies whose file is gone, e.g. after a rename. Dashboards made in
# the folder by hand have other uids, so they stay.
if (( status == 0 )); then
  for uid in $(api GET "/api/search?type=dash-db&folderUIDs=$folder" | jq -r '.[].uid | select(endswith("-preview"))'); do
    if [[ " ${uploaded[*]} " != *" $uid "* ]]; then
      api DELETE "/api/dashboards/uid/$uid" >/dev/null
      echo "removed $url/d/$uid"
    fi
  done
fi

exit "$status"
