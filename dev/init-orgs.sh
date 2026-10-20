#!/bin/sh
# Solo para el entorno local: crea las orgs de tenants.json que falten y les pone
# Mimir-<cliente> y Loki-<cliente> con la cabecera X-Scope-OrgID de su cliente.
# En producción las orgs y sus datasources ya existen.
set -eu
API="$GRAFANA_URL"
AUTH="$GRAFANA_USER:$GRAFANA_PASSWORD"

curl -s -u "$AUTH" -H 'Content-Type: application/json' -X PUT "$API/api/orgs/1" \
  -d "{\"name\":\"$(jq -r '.tenants[] | select(.orgId == 1) | .name' "$TENANTS_FILE")\"}" >/dev/null

jq -c '.tenants[] | select(.orgId != 1)' "$TENANTS_FILE" | while read -r t; do
  name=$(echo "$t" | jq -r .name); org=$(echo "$t" | jq -r .orgId)
  # Los IDs de org son autoincrementales: se crean en orden hasta llegar al orgId pedido.
  while [ "$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" "$API/api/orgs/$org")" = "404" ]; do
    curl -sf -u "$AUTH" -H 'Content-Type: application/json' -X POST "$API/api/orgs" \
      -d "{\"name\":\"tmp-$(date +%s%N)\"}" >/dev/null
  done
  curl -s -u "$AUTH" -H 'Content-Type: application/json' -X PUT "$API/api/orgs/$org" -d "{\"name\":\"$name\"}" >/dev/null
  for ds in "Mimir prometheus http://mimir:9009/prometheus" "Loki loki http://loki:3100"; do
    set -- $ds
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -H "X-Grafana-Org-Id: $org" \
      -H 'Content-Type: application/json' -X POST "$API/api/datasources" \
      -d "{\"name\":\"$1-$name\",\"type\":\"$2\",\"url\":\"$3\",\"access\":\"proxy\",
           \"jsonData\":{\"httpHeaderName1\":\"X-Scope-OrgID\"},
           \"secureJsonData\":{\"httpHeaderValue1\":\"$name\"}}")
    echo "org $org ($name): datasource $1-$name -> HTTP $code"
  done
done
