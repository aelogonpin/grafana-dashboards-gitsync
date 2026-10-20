#!/bin/sh
# Estado de Git Sync y dashboards de cada org.
G="${GRAFANA:-http://localhost:3001}"; AUTH="${AUTH:-admin:admin}"
for o in ${*:-1 2 3}; do
  ns=$([ "$o" = 1 ] && echo default || echo "org-$o")
  org=$(curl -s -u "$AUTH" "$G/api/orgs/$o" | jq -r .name)
  echo "== org $o ($org)"
  curl -s -u "$AUTH" "$G/apis/provisioning.grafana.app/v0alpha1/namespaces/$ns/repositories" \
    | jq -r '.items[]? | "   Git Sync \(.metadata.name): healthy=\(.status.health.healthy) sync=\(.status.sync.state // "-") \(.status.health.message // [] | join(" "))"'
  curl -s -u "$AUTH" -H "X-Grafana-Org-Id: $o" "$G/api/search?type=dash-db" \
    | jq -r 'if length == 0 then "   (sin dashboards)" else sort_by(.folderTitle, .title)[] | "   \(.folderTitle // "-") / \(.title)" end'
done
