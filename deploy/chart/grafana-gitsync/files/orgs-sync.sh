#!/bin/sh
# Prepara las orgs de los clientes y sus datasources SIN MODIFICAR NADA QUE YA EXISTA.
# Comprueba antes de escribir: solo crea lo que falta y avisa de lo que no encaja.
#
# Por cada cliente de TENANTS_FILE (ordenados por orgId):
#   - Org: si existe, no se toca (si su nombre no coincide, solo avisa; con RENAME_ORGS=true la renombra).
#          Si no existe, solo se crea si su orgId es el siguiente que asignará Grafana (máximo + 1):
#          Grafana no reutiliza ids, y crear orgs de relleno para llegar a otro id no es aceptable.
#   - Datasources, por tipo (prometheus, loki y, si TEMPO_URL tiene valor, tempo):
#          si la org ya tiene alguno de ese tipo, no se toca; si su nombre no empieza por el prefijo
#          que buscan los paneles (Mimir, Loki, Tempo), avisa. Si no hay ninguno, crea
#          <Prefijo>-<cliente> con la cabecera X-Scope-OrgID=<cliente>.
#
# Requiere: sh, curl, jq.
# Variables: GRAFANA_URL, GRAFANA_USER, GRAFANA_PASSWORD, TENANTS_FILE, MIMIR_URL, LOKI_URL,
#            TEMPO_URL (opcional), LOKI_USER / LOKI_PASS (opcionales, basic auth de Loki),
#            RENAME_ORGS (false), DRY_RUN (false: true = solo informa), WAIT_SECONDS (300)
set -eu

: "${GRAFANA_URL:?}" "${GRAFANA_USER:?}" "${GRAFANA_PASSWORD:?}" "${TENANTS_FILE:?}" "${MIMIR_URL:?}" "${LOKI_URL:?}"
TEMPO_URL="${TEMPO_URL:-}"
LOKI_USER="${LOKI_USER:-}"
LOKI_PASS="${LOKI_PASS:-}"
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

created=0; warned=0; failed=0
warn() { log "AVISO: $*"; warned=$((warned + 1)); }
fail() { log "ERROR: $*"; failed=$((failed + 1)); }

# Crea un datasource si la org no tiene ninguno de ese tipo. Uso: ensure_ds ORG CLIENTE TIPO PREFIJO URL
ensure_ds() {
  _d_org=$1 _d_name=$2 type=$3 prefix=$4 url=$5
  existing=$(j "$DS_LIST" "[.[] | select(.type == \"$type\") | .name] | join(\", \")")
  if [ -n "$existing" ]; then
    log "org $_d_org ($_d_name): $type ya existe ($existing); no se toca"
    if ! j "$DS_LIST" "[.[] | select(.type == \"$type\") | .name | test(\"^$prefix\")] | any" | grep -q true; then
      warn "org $_d_org ($_d_name): ningún datasource $type empieza por '$prefix'; los paneles con la variable /^$prefix/ no lo encontrarán"
    fi
    return 0
  fi
  dsname="$prefix-$_d_name"
  body=$(jq -n --arg n "$dsname" --arg t "$type" --arg u "$url" --arg tenant "$_d_name" \
    '{name:$n, type:$t, url:$u, access:"proxy", jsonData:{httpHeaderName1:"X-Scope-OrgID"}, secureJsonData:{httpHeaderValue1:$tenant}}')
  [ "$type" = "prometheus" ] && body=$(j "$body" '. + {isDefault: true}' | jq -c .)
  if [ "$type" = "loki" ] && [ -n "$LOKI_USER" ]; then
    body=$(printf '%s' "$body" | jq -c --arg lu "$LOKI_USER" --arg lp "$LOKI_PASS" '. * {basicAuth:true, basicAuthUser:$lu, secureJsonData:{basicAuthPassword:$lp}}')
  fi
  if [ "$DRY_RUN" = "true" ]; then
    log "org $_d_org ($_d_name): crearía $dsname [$type] -> $url"; return 0
  fi
  c=$(call POST /api/datasources "$_d_org" -d "$body")
  if [ "$c" = "200" ]; then
    log "org $_d_org ($_d_name): creado $dsname [$type]"; created=$((created + 1))
  else
    fail "org $_d_org ($_d_name): no se pudo crear $dsname (HTTP $c): $(jq -r '.message // empty' "$TMP" 2>/dev/null)"
  fi
}

ROWS=$(mktemp)
jq -c '.tenants | sort_by(.orgId) | .[]' "$TENANTS_FILE" > "$ROWS"
while IFS= read -r t; do
  name=$(j "$t" .name); org=$(j "$t" .orgId)

  # --- Org ---
  c=$(call GET "/api/orgs/$org")
  if [ "$c" = "200" ]; then
    current=$(jq -r .name "$TMP")
    if [ "$current" != "$name" ]; then
      if [ "$RENAME_ORGS" = "true" ] && [ "$DRY_RUN" != "true" ]; then
        call PUT "/api/orgs/$org" "" -d "{\"name\":\"$name\"}" >/dev/null && log "org $org: renombrada '$current' -> '$name'"
      else
        warn "org $org se llama '$current' y en el config '$name'; no se renombra (RENAME_ORGS=true para hacerlo)"
      fi
    else
      log "org $org ($name): existe"
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

  # --- Datasources ---
  c=$(call GET /api/datasources "$org")
  [ "$c" = "200" ] || { fail "org $org ($name): no se pueden listar sus datasources (HTTP $c)"; continue; }
  DS_LIST=$(cat "$TMP")
  ensure_ds "$org" "$name" prometheus Mimir "$MIMIR_URL"
  ensure_ds "$org" "$name" loki Loki "$LOKI_URL"
  [ -n "$TEMPO_URL" ] && ensure_ds "$org" "$name" tempo Tempo "$TEMPO_URL"
done < "$ROWS"
rm -f "$ROWS"

log "Resumen: creados=$created avisos=$warned errores=$failed"
[ "$failed" -eq 0 ]
