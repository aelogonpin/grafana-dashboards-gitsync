# Formatos de dashboard que admite el repo. Se usa con:
#   jq -L scripts 'include "dashboard-format"; dash_uid' panel.json
#
#   classic  JSON de siempre: uid, title, panels, templating
#   k8s-v1   apiVersion dashboard.grafana.app/v1*: metadata.name y spec con el modelo clásico
#   v2       apiVersion dashboard.grafana.app/v2*: metadata.name, spec.elements, spec.variables
#   v2-spec  el spec v2 suelto, sin apiVersion ni metadata

def is_k8s: ((.apiVersion? // "") | tostring | startswith("dashboard.grafana.app/")) and .kind? == "Dashboard";

def dash_format:
  if is_k8s then
    (if (.apiVersion | test("/v2")) or (.spec | has("elements")) then "v2" else "k8s-v1" end)
  elif has("elements") then "v2-spec"
  else "classic" end;

def dash_uid:
  if is_k8s then (.metadata.name // .spec.uid // empty) else (.uid // empty) end;

def dash_title:
  if is_k8s then (.spec.title // empty) else (.title // empty) end;

# Referencias a datasources: {uid} en clásico, {name} en v2.
def ds_refs:
  [.. | objects | select(has("datasource")) | .datasource | objects | (.uid // .name // empty)
   | select(type == "string")] | unique;

# Variables definidas, en cualquier formato.
def dash_vars:
  [ (.templating.list[]?.name),
    (.spec.templating.list[]?.name),
    (.variables[]?.spec.name),
    (.spec.variables[]?.spec.name) ] | unique;

# Campos del servidor que un export v2 o v1 arrastra en metadata y que no deben ir al repo.
def server_metadata:
  (.metadata // {}) | keys_unsorted - ["name", "annotations", "labels"]
  | map(select(. as $k | ["namespace", "uid", "resourceVersion", "generation", "creationTimestamp"] | index($k)));

# Consultas de un dashboard, para dev/check-queries.sh: {t, typ, ds, e}
def dash_queries:
  (if is_k8s then .spec else . end) as $d
  | if ($d | has("elements")) then
      ($d.elements // {}) | to_entries[] | .value.spec as $p
      | ($p.data.spec.queries // [])[] | .spec.query
      | select(.spec.expr? != null)
      | {t: $p.title, typ: $p.vizConfig.group, ds: .group, e: .spec.expr}
    else
      $d.panels[]? | select(.targets) | . as $p | .targets[] | select(.expr)
      | {t: $p.title, typ: $p.type, ds: ((.datasource // $p.datasource).type // "prometheus"), e: .expr}
    end;
