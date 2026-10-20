#!/usr/bin/env bash
# Convierte un dashboard exportado de Grafana al formato del repo:
#   - datasources de tipo prometheus -> ${ds_mimir}; de tipo loki -> ${ds_loki}
#   - añade las variables ocultas ds_mimir / ds_loki (regex /^Mimir/, /^Loki/)
#   - quita id, __inputs, __requires y __elements del export
#   - fija el uid del dashboard
#
# Uso: scripts/convert-dashboard.sh <export.json> <uid> <destino.json>
# Ej.: scripts/convert-dashboard.sh ~/Descargas/cpu.json gen-cpu master/general/kubernetes/cpu.json
set -euo pipefail

[[ $# -eq 3 ]] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
src=$1 uid=$2 dst=$3
[[ "$uid" =~ ^[A-Za-z0-9_-]{1,40}$ && "$uid" != "general" ]] || { echo "uid no válido: '$uid'" >&2; exit 1; }
jq empty "$src" || { echo "$src no es un JSON válido" >&2; exit 1; }

mkdir -p "$(dirname "$dst")"
jq --arg uid "$uid" '
  def dsvar:
    if type != "object" then .
    elif .type == "prometheus" then {type: "prometheus", uid: "${ds_mimir}"}
    elif .type == "loki"       then {type: "loki",       uid: "${ds_loki}"}
    else . end;

  # Algunos exports envuelven el dashboard en {"dashboard": {...}}
  (if has("dashboard") and (.dashboard | type) == "object" then .dashboard else . end)
  | del(.id, .__inputs, .__requires, .__elements)
  | .uid = $uid
  | walk(if type == "object" and has("datasource") then .datasource |= dsvar else . end)
  | .templating.list = (
      [ {name: "ds_mimir", label: "Mimir", type: "datasource", query: "prometheus", regex: "/^Mimir/", hide: 2},
        {name: "ds_loki",  label: "Loki",  type: "datasource", query: "loki",       regex: "/^Loki/",  hide: 2} ]
      + ((.templating.list // []) | map(select(.type != "datasource")))
    )
' "$src" > "$dst"

echo "Convertido: $dst (uid $uid)"
left=$(jq -r '[.. | objects | select(has("datasource")) | .datasource | objects | .uid // empty
               | select(type == "string" and (startswith("$") | not))
               | select(IN("grafana", "-- Grafana --", "-- Mixed --", "-- Dashboard --") | not)] | unique | join(", ")' "$dst")
[[ -z "$left" ]] || echo "AVISO: quedan datasources con UID fijo (tipos que no son prometheus/loki): $left"
