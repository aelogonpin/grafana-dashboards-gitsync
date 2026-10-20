#!/bin/sh
# Crea la conexión de Git Sync (recurso Repository) de cada cliente con gitSync: true,
# solo si no existe. Idempotente: se puede relanzar sin duplicar nada.
#
# Se ejecuta como Job de Kubernetes (hook PostSync de ArgoCD) o como init container en Docker.
# Requiere: sh, curl, jq.
#
# Variables:
#   GRAFANA_URL        p. ej. http://grafana.grafana.svc:80
#   GRAFANA_USER       usuario administrador del servidor
#   GRAFANA_PASSWORD
#   GITHUB_TOKEN       token con acceso al repo (lo guarda Grafana como secreto)
#   TENANTS_FILE       deploy/tenants.json (lo genera scripts/render.sh)
#   SYNC_TARGET        folder (por defecto) | instance
#   SYNC_INTERVAL      segundos entre sincronizaciones (60)
#   WORKFLOWS          JSON: ["branch"] = cambios desde la UI por PR (por defecto); [] = solo lectura
#   DRY_RUN            true = solo informa de lo que haría
#   WAIT_SECONDS       espera máxima a que Grafana responda (300)
set -eu

: "${GRAFANA_URL:?}" "${GRAFANA_USER:?}" "${GRAFANA_PASSWORD:?}" "${TENANTS_FILE:?}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
SYNC_TARGET="${SYNC_TARGET:-folder}"
SYNC_INTERVAL="${SYNC_INTERVAL:-60}"
WORKFLOWS="${WORKFLOWS:-[\"branch\"]}"
DRY_RUN="${DRY_RUN:-false}"
WAIT_SECONDS="${WAIT_SECONDS:-300}"

API="${GRAFANA_URL%/}"
AUTH="$GRAFANA_USER:$GRAFANA_PASSWORD"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

log() { echo "[gitsync] $*"; }

# curl que devuelve el código HTTP y deja el cuerpo en $TMP
call() {
  method=$1; path=$2; shift 2
  curl -s -o "$TMP" -w '%{http_code}' -u "$AUTH" -H 'Content-Type: application/json' -X "$method" "$API$path" "$@"
}

# 1. Esperar a Grafana
log "Esperando a Grafana en $API ..."
elapsed=0
until curl -sf "$API/api/health" >/dev/null 2>&1; do
  [ "$elapsed" -ge "$WAIT_SECONDS" ] && { log "ERROR: Grafana no responde tras ${WAIT_SECONDS}s"; exit 1; }
  sleep 5; elapsed=$((elapsed + 5))
done

# 2. Versión de la API de provisioning
code=$(call GET /apis/provisioning.grafana.app)
[ "$code" = "200" ] || { log "ERROR: la API de provisioning no está disponible (HTTP $code). ¿Git Sync activado?"; exit 1; }
VERSION=$(jq -r '.preferredVersion.version' "$TMP")
GROUP="/apis/provisioning.grafana.app/$VERSION"
log "API de provisioning: $VERSION"

# 3. Abortar si Grafana sigue en legacy storage
code=$(call GET "$GROUP/namespaces/default/settings")
if [ "$code" = "200" ] && [ "$(jq -r '.legacyStorage // false' "$TMP")" = "true" ]; then
  log "ERROR: Grafana está en legacy storage; no se crea ninguna conexión."
  exit 1
fi

REPO_URL=$(jq -r '.repo.url' "$TENANTS_FILE")
BRANCH=$(jq -r '.repo.branch' "$TENANTS_FILE")
[ -n "$GITHUB_TOKEN" ] || log "AVISO: GITHUB_TOKEN vacío; Grafana puede rechazar la conexión."

created=0; existing=0; failed=0
for t in $(jq -r '.tenants[] | select(.gitSync) | @base64' "$TENANTS_FILE"); do
  row=$(echo "$t" | base64 -d)
  name=$(echo "$row" | jq -r .name)
  org=$(echo "$row" | jq -r .orgId)
  path=$(echo "$row" | jq -r .path)
  if [ "$org" = "1" ]; then ns=default; else ns="org-$org"; fi
  repo="gitsync-$name"

  # 4. La org debe existir
  code=$(call GET "/api/orgs/$org")
  if [ "$code" != "200" ]; then
    log "[$name] ERROR: la org $org no existe (HTTP $code)"
    failed=$((failed + 1)); continue
  fi

  # 5. ¿Ya existe la conexión?
  code=$(call GET "$GROUP/namespaces/$ns/repositories/$repo")
  if [ "$code" = "200" ]; then
    log "[$name] ya existe ($ns/$repo); no se toca"
    existing=$((existing + 1)); continue
  elif [ "$code" != "404" ]; then
    log "[$name] ERROR al consultar $ns/$repo (HTTP $code): $(jq -r '.message // empty' "$TMP" 2>/dev/null)"
    failed=$((failed + 1)); continue
  fi

  body=$(jq -n \
    --arg v "provisioning.grafana.app/$VERSION" --arg name "$repo" --arg ns "$ns" \
    --arg title "$name" --arg url "$REPO_URL" --arg branch "$BRANCH" --arg path "$path" \
    --arg target "$SYNC_TARGET" --argjson interval "$SYNC_INTERVAL" \
    --argjson workflows "$WORKFLOWS" --arg token "$GITHUB_TOKEN" '
    {
      apiVersion: $v, kind: "Repository",
      metadata: { name: $name, namespace: $ns },
      spec: {
        title: $title, type: "github",
        github: { url: $url, branch: $branch, path: $path },
        sync: { enabled: true, target: $target, intervalSeconds: $interval },
        workflows: $workflows
      }
    } + (if $token == "" then {} else { secure: { token: { create: $token } } } end)')

  if [ "$DRY_RUN" = "true" ]; then
    log "[$name] DRY_RUN: crearía $ns/$repo -> $REPO_URL ($BRANCH:$path, $SYNC_TARGET)"
    continue
  fi

  # 6. Crear
  code=$(call POST "$GROUP/namespaces/$ns/repositories" -d "$body")
  if [ "$code" = "201" ] || [ "$code" = "200" ]; then
    log "[$name] creado $ns/$repo -> $path"
    created=$((created + 1))
  else
    log "[$name] ERROR al crear (HTTP $code): $(jq -r '.message // empty' "$TMP" 2>/dev/null)"
    failed=$((failed + 1))
  fi
done

log "Resumen: creados=$created ya_existian=$existing errores=$failed"
[ "$failed" -eq 0 ]
