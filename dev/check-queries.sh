#!/bin/sh
# Ejecuta cada consulta de un dashboard contra el Grafana de pruebas, en la org indicada,
# y muestra si devuelve datos y su último valor. Sirve para validar un panel antes de subirlo.
#
# Uso: dev/check-queries.sh <dashboard.json> [orgId] [rango]
#   orgId  org con la que probar (por defecto 1); cada org usa sus datasources
#   rango  ventana de tiempo (por defecto now-1h)
# Variables: GRAFANA (http://localhost:3001), AUTH (admin:admin)
# Resuelve ${ds_mimir} / ${ds_loki} al datasource prometheus / loki de esa org.
# Sale con código 1 si alguna consulta falla o no devuelve datos.
# Las consultas con variables del panel ($cluster, $host...) no se pueden resolver aquí:
# se marcan con VAR y hay que revisarlas en Grafana.
set -eu
[ $# -ge 1 ] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
F=$1; ORG=${2:-1}; FROM=${3:-now-1h}
G="${GRAFANA:-http://localhost:3001}"; AUTH="${AUTH:-admin:admin}"

j() { printf '%s\n' "$1" | jq -r "$2"; }   # printf: el echo de dash interpreta las barras invertidas

ds=$(curl -sf -u "$AUTH" -H "X-Grafana-Org-Id: $ORG" "$G/api/datasources") \
  || { echo "No se puede consultar Grafana en $G (org $ORG)"; exit 1; }
PROM=$(j "$ds" '[.[] | select(.type == "prometheus")][0].uid // empty')
LOKI=$(j "$ds" '[.[] | select(.type == "loki")][0].uid // empty')

ROWS=$(mktemp); trap 'rm -f "$ROWS"' EXIT
jq -c '.panels[]? | select(.targets) | . as $p | .targets[] | select(.expr) |
       {t: $p.title, typ: $p.type, ds: ((.datasource // $p.datasource).type // "prometheus"), e: .expr}' "$F" > "$ROWS"

fail=0
echo "$(jq -r .title "$F") — org $ORG, desde $FROM"
while IFS= read -r row; do
  title=$(j "$row" .t); typ=$(j "$row" .typ); expr=$(j "$row" .e)
  if [ "$(j "$row" .ds)" = loki ]; then uid=$LOKI; else uid=$PROM; fi
  vars=$(printf '%s' "$expr" | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' | grep -vE '__(interval|rate_interval|range|auto)' | tr -d '${' | sort -u | tr '\n' ' ')
  if [ -n "$vars" ]; then
    printf '%-3s %-44s %s\n' VAR "$title" "usa variables ($vars): revisar en Grafana"
    continue
  fi
  body=$(jq -n --arg u "$uid" --arg e "$expr" --arg from "$FROM" \
    '{from: $from, to: "now", queries: [{refId: "A", datasource: {uid: $u}, expr: $e, queryType: "range", maxLines: 3, step: "60s"}]}')
  r=$(curl -s -u "$AUTH" -H "X-Grafana-Org-Id: $ORG" -H 'Content-Type: application/json' -X POST "$G/api/ds/query" -d "$body")
  err=$(j "$r" '.results.A.error // empty' | cut -c1-100)
  if [ "$typ" = logs ]; then
    val=$(j "$r" '[.results.A.frames[]?.data.values[]? | arrays | .[] | strings | select(test("="))][0] // empty' | cut -c1-70)
  else
    val=$(j "$r" '[.results.A.frames[]? | ((.schema.fields[1].labels // {}) | to_entries | map(.value) | join(",")) as $l
           | ((.data.values[1] // []) | last) as $v | select($v != null) | (if $l == "" then "" else $l + "=" end) + ($v | tostring | .[0:8])]
           | .[0:4] | join("  ")')
  fi
  if [ -z "$err" ] && [ -n "$val" ]; then st=OK; else st=XX; fail=1; fi
  printf '%-3s %-44s %s\n' "$st" "$title" "${err:-${val:-sin datos}}"
done < "$ROWS"
exit "$fail"
