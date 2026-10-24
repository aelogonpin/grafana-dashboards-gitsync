#!/bin/sh
# Crea las orgs de los clientes que falten SIN MODIFICAR las que ya existen.
# Los datasources NO se gestionan aquí: los provisiona el chart de Grafana (datasources.yaml / sidecar),
# y para eso la org tiene que existir antes (si no, Grafana no arranca).
#
# Por cada cliente de TENANTS_FILE (ordenados por orgId):
#   - Si la org existe: no se toca. Si su nombre no coincide con el del config, solo avisa
#     (con RENAME_ORGS=true la renombra).
#   - Si no existe: solo se crea si su orgId es el siguiente que asignará Grafana (máximo + 1).
#     Grafana no reutiliza ids, y crear orgs de relleno para llegar a otro id no es aceptable.
#
# Requiere: sh, curl, jq.
# Variables: GRAFANA_URL, GRAFANA_USER, GRAFANA_PASSWORD, TENANTS_FILE,
#            RENAME_ORGS (false), DRY_RUN (false: true = solo informa), WAIT_SECONDS (300)
set -eu

: "${GRAFANA_URL:?}" "${GRAFANA_USER:?}" "${GRAFANA_PASSWORD:?}" "${TENANTS_FILE:?}"
RENAME_ORGS="${RENAME_ORGS:-false}"
DRY_RUN="${DRY_RUN:-false}"
WAIT_SECONDS="${WAIT_SECONDS:-300}"

API="${GRAFANA_URL%/}"
AUTH="$GRAFANA_USER:$GRAFANA_PASSWORD"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

log() { echo "[orgs] $*"; }
j() { printf '%s\n' "$1" | jq -r "$2"; }
# curl que devuelve el código HTTP y deja el cuerpo en $TMP. Uso: call MÉTODO RUTA [ORG] [args curl...]
# (en sh las variables de las funciones son globales: prefijo _c_ para no pisar las del bucle)
call() {
  _c_method=$1; _c_path=$2; _c_org=${3:-}; if [ $# -ge 3 ]; then shift 3; else shift $#; fi
  if [ -n "$_c_org" ]; then
    curl -s -o "$TMP" -w '%{http_code}' -u "$AUTH" -H "X-Grafana-Org-Id: $_c_org" -H 'Content-Type: application/json' -X "$_c_method" "$API$_c_path" "$@"
  else
    curl -s -o "$TMP" -w '%{http_code}' -u "$AUTH" -H 'Content-Type: application/json' -X "$_c_method" "$API$_c_path" "$@"
  fi
}

[ "$DRY_RUN" = "true" ] && log "MODO COMPROBACIÓN (DRY_RUN): no se crea ni se modifica nada"

elapsed=0
until curl -sf "$API/api/health" >/dev/null 2>&1; do
  [ "$elapsed" -ge "$WAIT_SECONDS" ] && { log "ERROR: Grafana no responde tras ${WAIT_SECONDS}s"; exit 1; }
  log "esperando a Grafana..."; sleep 5; elapsed=$((elapsed + 5))
done

created=0; existing=0; warned=0; failed=0
warn() { log "AVISO: $*"; warned=$((warned + 1)); }
fail() { log "ERROR: $*"; failed=$((failed + 1)); }

ROWS=$(mktemp)
jq -c '.tenants | sort_by(.orgId) | .[]' "$TENANTS_FILE" > "$ROWS"
while IFS= read -r t; do
  name=$(j "$t" .name); org=$(j "$t" .orgId)
  c=$(call GET "/api/orgs/$org")
  if [ "$c" = "200" ]; then
    current=$(jq -r .name "$TMP")
    if [ "$current" != "$name" ]; then
      if [ "$RENAME_ORGS" = "true" ] && [ "$DRY_RUN" != "true" ]; then
        call PUT "/api/orgs/$org" "" -d "{\"name\":\"$name\"}" >/dev/null && log "org $org: renombrada '$current' -> '$name'"
      else
        warn "org $org se llama '$current' y en el config '$name'; no se renombra (RENAME_ORGS=true para hacerlo)"; existing=$((existing + 1))
      fi
    else
      log "org $org ($name): existe; no se toca"; existing=$((existing + 1))
    fi
  elif [ "$c" = "404" ]; then
    call GET /api/orgs >/dev/null
    max=$(jq '[.[].id] | max // 0' "$TMP")
    if [ "$org" -ne $((max + 1)) ]; then
      fail "org $org ($name) no existe y Grafana asignaría el id $((max + 1)) (no reutiliza ids). Crea la org a mano y pon su id real en master/config.yaml"
      continue
    fi
    if [ "$DRY_RUN" = "true" ]; then
      log "org $org ($name): crearía la org"; continue
    fi
    c=$(call POST /api/orgs "" -d "{\"name\":\"$name\"}")
    newid=$(jq -r '.orgId // empty' "$TMP")
    if [ "$c" = "200" ] && [ "$newid" = "$org" ]; then
      log "org $org ($name): creada"; created=$((created + 1))
    else
      fail "org $org ($name): no se pudo crear (HTTP $c, id asignado '$newid')"; continue
    fi
  else
    fail "org $org ($name): error al consultarla (HTTP $c)"; continue
  fi
done < "$ROWS"
rm -f "$ROWS"

log "Resumen: creadas=$created ya_existian=$existing avisos=$warned errores=$failed"
[ "$failed" -eq 0 ]
