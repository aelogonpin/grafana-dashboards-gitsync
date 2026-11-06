#!/usr/bin/env bash
# Convierte un dashboard exportado de Grafana al formato del repo. Admite JSON o YAML en
# cualquiera de estos formatos: clásico, envuelto en {"dashboard": ...}, recurso v1 y recurso v2.
#   - datasources prometheus -> ${ds_mimir}; loki -> ${ds_loki}
#   - añade las variables ocultas ds_mimir / ds_loki (regex /^Mimir/, /^Loki/)
#   - quita lo que añade el export: id, __inputs..., y en v1/v2 namespace, resourceVersion, etc.
#   - fija el uid del dashboard. El clásico y el v1 quedan en clásico; el v2 sigue en v2
#   - opcional: define el título de la carpeta destino en Grafana (scripts/folder-title.sh)
#
# Uso: scripts/convert-dashboard.sh <export> <uid> <destino.json> ["Título de la carpeta"]
# Ej.: scripts/convert-dashboard.sh ~/Descargas/cpu.json gen-cpu master/general/kubernetes/cpu.json "Kubernetes"
set -euo pipefail

[[ $# -eq 3 || $# -eq 4 ]] || { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
src=$1 uid=$2 dst=$3 folder_title=${4:-}
LIB="$(dirname "${BASH_SOURCE[0]}")"
[[ "$uid" =~ ^[A-Za-z0-9_-]{1,40}$ && "$uid" != "general" ]] || { echo "uid no válido: '$uid'" >&2; exit 1; }

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
case "$src" in
  *.yaml|*.yml)
    command -v yq >/dev/null || { echo "Para leer YAML hace falta yq" >&2; exit 1; }
    yq -o=json '.' "$src" > "$tmp" ;;
  *) cp "$src" "$tmp" ;;
esac
jq empty "$tmp" || { echo "$src no es un JSON válido" >&2; exit 1; }

mkdir -p "$(dirname "$dst")"
jq -L "$LIB" --arg uid "$uid" '
  include "dashboard-format";

  def dsvar:
    if type != "object" then .
    elif .type == "prometheus" then {type: "prometheus", uid: "${ds_mimir}"}
    elif .type == "loki"       then {type: "loki",       uid: "${ds_loki}"}
    else . end;

  def classic:
    del(.id, .__inputs, .__requires, .__elements)
    | .uid = $uid
    | walk(if type == "object" and has("datasource") then .datasource |= dsvar else . end)
    | .templating.list = (
        [ {name: "ds_mimir", label: "Mimir", type: "datasource", query: "prometheus", regex: "/^Mimir/", hide: 2},
          {name: "ds_loki",  label: "Loki",  type: "datasource", query: "loki",       regex: "/^Loki/",  hide: 2} ]
        + ((.templating.list // []) | map(select(.type != "datasource")))
      );

  def v2var($name; $plugin; $label; $regex):
    {kind: "DatasourceVariable", spec: {
      name: $name, pluginId: $plugin, refresh: "onDashboardLoad", regex: $regex,
      current: {text: "", value: ""}, options: [], multi: false, includeAll: false,
      label: $label, hide: "hideVariable", skipUrlSync: false, allowCustomValue: true}};

  def v2:
    {
      apiVersion: (.apiVersion // "dashboard.grafana.app/v2"),
      kind: "Dashboard",
      metadata: {name: $uid},
      spec: (
        (if is_k8s then .spec else . end)
        | walk(
            if type != "object" then .
            elif .kind? == "DataQuery" and .group? == "prometheus" then .datasource = {name: "${ds_mimir}"}
            elif .kind? == "DataQuery" and .group? == "loki"       then .datasource = {name: "${ds_loki}"}
            elif has("datasource") then .datasource |= dsvar
            else . end)
        | .variables = (
            [ v2var("ds_mimir"; "prometheus"; "Mimir"; "/^Mimir/"),
              v2var("ds_loki";  "loki";       "Loki";  "/^Loki/") ]
            + ((.variables // []) | map(select(.kind != "DatasourceVariable")))
          )
      )
    };

  # Algunos exports envuelven el dashboard en {"dashboard": {...}}
  (if has("dashboard") and (.dashboard | type) == "object" then .dashboard else . end)
  | dash_format as $f
  | if   $f == "v2" or $f == "v2-spec" then v2
    elif $f == "k8s-v1" then (.spec | classic)
    else classic end
' "$tmp" > "$dst"

fmt=$(jq -r -L "$LIB" 'include "dashboard-format"; dash_format' "$dst")
echo "Convertido: $dst (uid $uid, formato $fmt)"

left=$(jq -r -L "$LIB" 'include "dashboard-format";
  ds_refs | map(select((startswith("$") | not) and (IN("grafana", "-- Grafana --", "-- Mixed --", "-- Dashboard --") | not))) | join(", ")' "$dst")
[[ -z "$left" ]] || echo "AVISO: quedan datasources con UID fijo (tipos que no son prometheus/loki): $left"

# Los enlaces internos llevan el UID del panel original: si cambia, apuntan a otro panel.
links=$(jq -r --arg uid "$uid" '
  [.. | strings | scan("/d/([A-Za-z0-9_-]+)") | .[0] | select(. != $uid)] | unique | join(", ")' "$dst")
[[ -z "$links" ]] || echo "AVISO: hay enlaces a otros UIDs ($links); revisa que no sean a este mismo panel"

if [[ -n "$folder_title" ]]; then
  "$(dirname "${BASH_SOURCE[0]}")/folder-title.sh" "$(dirname "$dst")" "$folder_title"
fi
