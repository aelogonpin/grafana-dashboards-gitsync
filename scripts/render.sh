#!/usr/bin/env bash
# Genera tenants/<cliente>/general/ a partir de master/general/ según master/config.yaml,
# valida el resultado y escribe deploy/tenants.json para el Job de Git Sync.
#
# Uso:
#   scripts/render.sh           genera y escribe en el repo
#   scripts/render.sh --check   genera en un directorio temporal y solo valida (para PRs)
#
# Requiere: bash 4+, yq (mikefarah v4), jq, rsync.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/master/config.yaml"
MASTER="$ROOT/master/general"
CHECK_ONLY=false
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=true

# Datasources que pueden ir con UID fijo en general/ (los internos de Grafana).
ALLOWED_DS_UIDS='["grafana","-- Grafana --","-- Mixed --","-- Dashboard --"]'

errors=0
err()  { echo "ERROR: $*" >&2; errors=$((errors + 1)); }
info() { echo "  $*"; }

for bin in yq jq rsync; do
  command -v "$bin" >/dev/null || { echo "Falta '$bin' en el PATH" >&2; exit 2; }
done

# ---------------------------------------------------------------------------
# 1. Validar el config
# ---------------------------------------------------------------------------
echo "== Validando $CONFIG"
yq -e '.tenants | type == "!!map"' "$CONFIG" >/dev/null 2>&1 || { echo "ERROR: 'tenants' no existe o no es un mapa" >&2; exit 1; }

mapfile -t TENANTS < <(yq -r '.tenants | keys | .[]' "$CONFIG")
[[ ${#TENANTS[@]} -gt 0 ]] || { echo "ERROR: no hay clientes en el config" >&2; exit 1; }

dup_orgs=$(yq -r '.tenants[].orgId' "$CONFIG" | sort | uniq -d)
[[ -z "$dup_orgs" ]] || err "orgId repetido: $(echo $dup_orgs)"

for t in "${TENANTS[@]}"; do
  [[ "$t" =~ ^[a-z0-9][a-z0-9-]*$ ]] || err "[$t] nombre de cliente no válido (solo minúsculas, números y guiones)"
  org=$(yq -r ".tenants.\"$t\".orgId" "$CONFIG")
  [[ "$org" =~ ^[0-9]+$ ]] || err "[$t] orgId no válido: '$org'"
  gs=$(yq -r ".tenants.\"$t\".gitSync // false" "$CONFIG")
  [[ "$gs" == "true" || "$gs" == "false" ]] || err "[$t] gitSync debe ser true o false"
  [[ $(yq -r ".tenants.\"$t\".general // [] | length" "$CONFIG") -gt 0 ]] || err "[$t] 'general' está vacío"
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    [[ "$p" == *..* || "$p" == /* ]] && { err "[$t] ruta no permitida: '$p'"; continue; }
    [[ -e "$MASTER/$p" ]] || err "[$t] la ruta '$p' no existe en master/general/"
  done < <(yq -r ".tenants.\"$t\" | (.general // []) + (.exclude // []) | .[]" "$CONFIG")
done
[[ $errors -eq 0 ]] || { echo "Config con $errors error(es); no se genera nada." >&2; exit 1; }

# ---------------------------------------------------------------------------
# 2. Generar general/ de cada cliente
# ---------------------------------------------------------------------------
WORK="$ROOT"
if $CHECK_ONLY; then
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  rsync -a --exclude .git "$ROOT/" "$WORK/"
fi

# UID estable de carpeta a partir de su ruta: <prefijo>-<ruta-con-guiones>, o un hash si no cabe en 40.
folder_uid() {
  local prefix=$1 rel=$2 slug
  slug="$prefix-$(echo "$rel" | tr '/' '-' | tr -c 'a-zA-Z0-9_\n-' '-' | tr '[:upper:]' '[:lower:]')"
  [[ ${#slug} -le 40 ]] || slug="$prefix-$(echo -n "$rel" | md5sum | cut -c1-20)"
  echo "$slug"
}

# Escribe _folder.json (metadatos de carpeta de Git Sync: UID y título fijos).
# Grafana reserva el UID "general", por eso todos llevan prefijo.
write_folder_meta() {
  local file=$1 uid=$2 title=$3
  jq -n --arg uid "$uid" --arg title "$title" \
    '{apiVersion: "folder.grafana.app/v1beta1", kind: "Folder", metadata: {name: $uid}, spec: {title: $title}}' > "$file"
}

# general/: siempre se regeneran. Si master/ trae un _folder.json, se respeta su título.
folder_meta_general() {
  local stage=$1 dir rel title
  write_folder_meta "$stage/_folder.json" "gen" "Paneles generales"
  while IFS= read -r -d '' dir; do
    rel="${dir#"$stage"/}"
    title="$(basename "$rel")"
    [[ -f "$MASTER/$rel/_folder.json" ]] && title="$(jq -r '.spec.title // empty' "$MASTER/$rel/_folder.json")"
    write_folder_meta "$dir/_folder.json" "$(folder_uid gen "$rel")" "${title:-$(basename "$rel")}"
  done < <(find "$stage" -mindepth 1 -type d -print0)
}

# custom/: solo se crean los que falten; nunca se pisa uno existente.
folder_meta_custom() {
  local base=$1 dir rel
  [[ -f "$base/_folder.json" ]] || write_folder_meta "$base/_folder.json" "custom" "Paneles propios"
  while IFS= read -r -d '' dir; do
    rel="${dir#"$base"/}"
    [[ -f "$dir/_folder.json" ]] || write_folder_meta "$dir/_folder.json" "$(folder_uid custom "$rel")" "$(basename "$rel")"
  done < <(find "$base" -mindepth 1 -type d -print0)
}

render_tenant() {
  local t=$1 stage
  stage="$(mktemp -d)"
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if [[ -d "$MASTER/$p" ]]; then
      mkdir -p "$stage/$p"
      rsync -a "$MASTER/$p/" "$stage/$p/"
    else
      mkdir -p "$stage/$(dirname "$p")"
      cp "$MASTER/$p" "$stage/$p"
    fi
  done < <(yq -r ".tenants.\"$t\".general[]" "$CONFIG")
  while IFS= read -r e; do
    [[ -z "$e" ]] && continue
    rm -rf "${stage:?}/$e"
  done < <(yq -r ".tenants.\"$t\".exclude // [] | .[]" "$CONFIG")
  find "$stage" -name _folder.json -delete
  find "$stage" -type d -empty -delete 2>/dev/null || true
  mkdir -p "$stage" "$WORK/tenants/$t/general" "$WORK/tenants/$t/custom"
  folder_meta_general "$stage"
  rsync -a --delete --checksum "$stage/" "$WORK/tenants/$t/general/"
  rm -rf "$stage"
  folder_meta_custom "$WORK/tenants/$t/custom"
  rm -f "$WORK/tenants/$t/custom/.keep"
  info "[$t] $(find "$WORK/tenants/$t/general" -name '*.json' ! -name _folder.json | wc -l) paneles generales"
}

echo "== Generando tenants/*/general/"
for t in "${TENANTS[@]}"; do render_tenant "$t"; done

# Clientes que ya no están en el config: se borra su general/, su custom/ se conserva.
for dir in "$WORK"/tenants/*/; do
  t="$(basename "$dir")"
  if ! printf '%s\n' "${TENANTS[@]}" | grep -qx "$t"; then
    rm -rf "${dir:?}general"
    info "[$t] ya no está en el config: borrado su general/ (custom/ se conserva)"
  fi
done

# ---------------------------------------------------------------------------
# 3. Validar lo generado
# ---------------------------------------------------------------------------
echo "== Validando paneles"
for t in "${TENANTS[@]}"; do
  base="$WORK/tenants/$t"
  uids_file="$(mktemp)"
  while IFS= read -r -d '' f; do
    rel="${f#"$WORK"/}"
    if ! jq empty "$f" 2>/dev/null; then err "$rel: JSON no válido"; continue; fi
    uid=$(jq -r '.uid // empty' "$f")
    title=$(jq -r '.title // empty' "$f")
    [[ -n "$uid" ]]   || err "$rel: falta 'uid'"
    [[ -n "$title" ]] || err "$rel: falta 'title'"
    [[ -z "$uid" || "$uid" =~ ^[A-Za-z0-9_-]{1,40}$ ]] || err "$rel: uid '$uid' no válido (máx. 40, letras, números, - y _)"
    [[ -n "$uid" ]] && echo "$uid $rel" >> "$uids_file"

    # En general/ no se permiten UIDs de datasource fijos: solo variables (${ds_mimir}, ${ds_loki}...).
    if [[ "$rel" == tenants/*/general/* ]]; then
      bad=$(jq -r --argjson ok "$ALLOWED_DS_UIDS" '
        [.. | objects | select(has("datasource")) | .datasource | objects | .uid // empty
         | select(type == "string" and (startswith("$") | not) and (. as $u | $ok | index($u) | not))]
        | unique | join(", ")' "$f")
      [[ -z "$bad" ]] || err "$rel: datasource con UID fijo ($bad); usa una variable como \${ds_mimir}"
      missing=$(jq -r '
        ([.templating.list[]?.name]) as $vars
        | [.. | objects | select(has("datasource")) | .datasource | objects | .uid // empty
           | select(type == "string" and startswith("$")) | ltrimstr("${") | ltrimstr("$") | rtrimstr("}")]
        | unique | map(select(. as $v | $vars | index($v) | not)) | join(", ")' "$f")
      [[ -z "$missing" ]] || err "$rel: usa variables sin definir en templating ($missing)"
    fi
  done < <(find "$base" -name '*.json' ! -name _folder.json -print0)

  while IFS= read -r -d '' f; do
    jq -e '.kind == "Folder" and (.metadata.name // "") != "" and (.metadata.name != "general")' "$f" >/dev/null 2>&1 \
      || err "${f#"$WORK"/}: _folder.json no válido (kind Folder, metadata.name obligatorio y distinto de 'general')"
  done < <(find "$base" -name _folder.json -print0)

  dups=$(awk '{print $1}' "$uids_file" | sort | uniq -d)
  for d in $dups; do
    err "[$t] uid '$d' repetido en: $(awk -v u="$d" '$1 == u {print $2}' "$uids_file" | paste -sd' ')"
  done
  rm -f "$uids_file"
done

# ---------------------------------------------------------------------------
# 4. deploy/tenants.json para el Job de Git Sync
# ---------------------------------------------------------------------------
mkdir -p "$WORK/deploy"
yq -o=json '
  {
    "repo": {"url": .repo.url, "branch": (.repo.branch // "main")},
    "tenants": [ .tenants | to_entries | .[] | {
      "name": .key,
      "orgId": .value.orgId,
      "gitSync": (.value.gitSync // false),
      "path": "tenants/" + .key
    } ]
  }' "$CONFIG" > "$WORK/deploy/tenants.json"
info "deploy/tenants.json: $(jq '[.tenants[] | select(.gitSync)] | length' "$WORK/deploy/tenants.json") cliente(s) con gitSync"

if [[ $errors -gt 0 ]]; then
  echo "FALLO: $errors error(es)." >&2
  exit 1
fi
echo "OK$($CHECK_ONLY && echo ' (solo comprobación, no se ha escrito nada)')"
