#!/bin/sh
# Lanza la misma consulta desde cada org y muestra qué cliente ve cada una (Mimir y Loki).
# Uso: dev/check-isolation.sh [orgs...]   (por defecto 1 2 3)
G="${GRAFANA:-http://localhost:3001}"; AUTH="${AUTH:-admin:admin}"
q() { curl -s -u "$AUTH" -H 'Content-Type: application/json' -H "X-Grafana-Org-Id: $1" -X POST "$G/api/ds/query" -d "$2"; }
for o in ${*:-1 2 3}; do
  ds=$(curl -s -u "$AUTH" -H "X-Grafana-Org-Id: $o" "$G/api/datasources")
  prom=$(echo "$ds" | jq -r '.[] | select(.type=="prometheus") | .uid')
  loki=$(echo "$ds" | jq -r '.[] | select(.type=="loki") | .uid')
  m=$(q "$o" '{"from":"now-5m","to":"now","queries":[{"refId":"A","datasource":{"uid":"'"$prom"'"},"expr":"count by (cliente) (up)","instant":true}]}' \
      | jq -r '[.results.A.frames[]?.schema.fields[1].labels.cliente] | join(",")')
  l=$(q "$o" '{"from":"now-5m","to":"now","queries":[{"refId":"A","datasource":{"uid":"'"$loki"'"},"expr":"{app=\"tienda\"}","queryType":"range","maxLines":1}]}' \
      | jq -r '[.results.A.frames[0].data.values[]? | arrays | .[] | strings | select(startswith("level="))][0] // "sin logs"' | cut -c1-85)
  echo "org $o -> Mimir ve: [${m:-sin datos}] | Loki: $l"
done
