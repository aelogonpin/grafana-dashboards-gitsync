#!/bin/sh
# Crea la conexión de Git Sync (recurso Repository) de un cliente, o de todos los que tengan
# gitSync: true, solo si no existe. Idempotente: se puede relanzar sin duplicar nada.
#
# Dos modos:
#   - Un cliente (lo usa cada Job del chart de Helm): TENANT, ORG_ID, REPO_PATH, REPO_URL, REPO_BRANCH
#   - Todos (CronJob del chart y entorno Docker de dev/): TENANTS_FILE con la lista en JSON
#
# Requiere: sh, curl, jq.
#
# Variables comunes:
#   GRAFANA_URL        p. ej. http://grafana.grafana.svc:80
#   GRAFANA_USER       usuario administrador del servidor
#   GRAFANA_PASSWORD
#   GITHUB_TOKEN       token con acceso al repo (lo guarda Grafana como secreto)
#   SYNC_TARGET        folder (por defecto) | instance
#   SYNC_INTERVAL      segundos entre sincronizaciones (60)
#   WORKFLOWS          JSON: ["branch"] = cambios desde la UI por PR (por defecto); [] = solo lectura
#   DRY_RUN            true = solo informa de lo que haría
#   WAIT_SECONDS       espera máxima a que Grafana responda (300)
set -eu

: "${GRAFANA_URL:?}" "${GRAFANA_USER:?}" "${GRAFANA_PASSWORD:?}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
SYNC_TARGET="${SYNC_TARGET:-folder}"
SYNC_INTERVAL="${SYNC_INTERVAL:-60}"
WORKFLOWS="${WORKFLOWS:-[\"branch\"]}"
DRY_RUN="${DRY_RUN:-false}"
WAIT_SECONDS="${WAIT_SECONDS:-300}"
TENANT="${TENANT:-}"
TENANTS_FILE="${TENANTS_FILE:-}"
[ -n "$TENANT" ] || [ -n "$TENANTS_FILE" ] || { echo "[gitsync] ERROR: define TENANT (un cliente) o TENANTS_FILE (todos)"; exit 1; }

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
[ -n "$GITHUB_TOKEN" ] || log "AVISO: GITHUB_TOKEN vacío; Grafana puede rechazar la conexión."

# Crea la conexión de un cliente si falta. Devuelve 0 (creado/ya existe/dry-run) o 1 (error).
# Deja en RESULT: creado | existe | dry-run | error
ensure_repository() {
  name=$1 org=$2 path=$3 repo_url=$4 branch=$5
  if [ "$org" = "1" ]; then ns=default; else ns="org-$org"; fi
  repo="gitsync-$name"

  # La org debe existir
  code=$(call GET "/api/orgs/$org")
  if [ "$code" != "200" ]; then
    log "[$name] ERROR: la org $org no existe (HTTP $code)"; RESULT=error; return 1
  fi

  # ¿Ya existe la conexión?
  code=$(call GET "$GROUP/namespaces/$ns/repositories/$repo")
  if [ "$code" = "200" ]; then
    log "[$name] ya existe ($ns/$repo); no se toca"; RESULT=existe; return 0
  elif [ "$code" != "404" ]; then
    log "[$name] ERROR al consultar $ns/$repo (HTTP $code): $(jq -r '.message // empty' "$TMP" 2>/dev/null)"
    RESULT=error; return 1
  fi

  body=$(jq -n \
    --arg v "provisioning.grafana.app/$VERSION" --arg name "$repo" --arg ns "$ns" \
    --arg title "$name" --arg url "$repo_url" --arg branch "$branch" --arg path "$path" \
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
    log "[$name] DRY_RUN: crearía $ns/$repo -> $repo_url ($branch:$path, $SYNC_TARGET)"; RESULT=dry-run; return 0
  fi

  code=$(call POST "$GROUP/namespaces/$ns/repositories" -d "$body")
  if [ "$code" = "201" ] || [ "$code" = "200" ]; then
    log "[$name] creado $ns/$repo -> $path"; RESULT=creado; return 0
  fi
  log "[$name] ERROR al crear (HTTP $code): $(jq -r '.message // empty' "$TMP" 2>/dev/null)"
  RESULT=error; return 1
}

# 4a. Modo un cliente
if [ -n "$TENANT" ]; then
  : "${ORG_ID:?}" "${REPO_URL:?}"
  ensure_repository "$TENANT" "$ORG_ID" "${REPO_PATH:-tenants/$TENANT}" "$REPO_URL" "${REPO_BRANCH:-main}"
  exit $?
fi

# 4b. Modo todos
REPO_URL=$(jq -r '.repo.url' "$TENANTS_FILE")
BRANCH=$(jq -r '.repo.branch // "main"' "$TENANTS_FILE")
created=0; existing=0; failed=0
for t in $(jq -r '.tenants[] | select(.gitSync) | @base64' "$TENANTS_FILE"); do
  row=$(printf '%s' "$t" | base64 -d)
  RESULT=""
  ensure_repository "$(printf '%s' "$row" | jq -r .name)" "$(printf '%s' "$row" | jq -r .orgId)" \
    "$(printf '%s' "$row" | jq -r .path)" "$REPO_URL" "$BRANCH" || true
  case "$RESULT" in
    creado) created=$((created + 1)) ;;
    existe) existing=$((existing + 1)) ;;
    error)  failed=$((failed + 1)) ;;
  esac
done
log "Resumen: creados=$created ya_existian=$existing errores=$failed"
[ "$failed" -eq 0 ]
