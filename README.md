# grafana-dashboards-gitsync

Paneles de Grafana para varios clientes (una org de Grafana por cliente), sincronizados con **Git Sync**.

- Los paneles **generales** se mantienen una sola vez en `master/general/`.
- `master/config.yaml` decide qué carpetas generales recibe cada cliente.
- Cada cliente puede añadir paneles **propios** en `tenants/<cliente>/custom/` cuando quiera.
- Un **Job** (Kubernetes o Docker) crea la conexión de Git Sync de cada cliente si no existe.

> **¿Primera vez? Sigue el [quick start](docs/QUICKSTART.md)** (de cero a tu primer panel en ~20 min) y luego el [manual de uso](docs/MANUAL.md). Novedades: [CHANGELOG](CHANGELOG.md).

> Repo público con datos de prueba. **No subas nunca tokens, contraseñas ni datos reales de clientes.**

## Estructura

```
master/
  config.yaml                 clientes, su org y qué carpetas generales reciben
  general/                    paneles generales (jerarquía libre de carpetas)
tenants/<cliente>/
  general/                    GENERADO por GitHub Actions: no se edita a mano
  custom/                     paneles propios del cliente
scripts/render.sh             lógica de carpetas (bash + yq + jq + rsync, sin IA)
scripts/convert-dashboard.sh  convierte un export de Grafana al formato del repo
scripts/folder-title.sh       define el título de una carpeta en Grafana
deploy/
  tenants.json                GENERADO: lo lee el Job de Git Sync
  gitsync/gitsync-sync.sh     Job idempotente de Git Sync (sh + curl + jq)
  gitsync/job.yaml            Job de Kubernetes (hook PostSync de ArgoCD)
  kustomization.yaml
dev/                          entorno local: Grafana 13 multi-org en Docker
```

## Cómo funciona

```
master/config.yaml + master/general/  --(GitHub Action)-->  tenants/<cliente>/general/
                                                           deploy/tenants.json
deploy/tenants.json  --(Job K8s / init container)-->  Repository de Git Sync por org
tenants/<cliente>/   --(Git Sync de esa org)-->  carpeta del cliente en Grafana
```

### Seleccionar carpetas generales para un cliente

En `master/config.yaml`:

```yaml
tenants:
  cliente-a:
    orgId: 1
    gitSync: true
    general:
      - kubernetes                       # carpeta entera, con subcarpetas
      - aplicacion                        # incluye metrics/ y licencias/
      - otra/carpeta/panel.json          # o un fichero suelto
    exclude:
      - aplicacion/licencias              # quita una subcarpeta de lo seleccionado
```

Al hacer push a `main`, la Action `render-tenants` regenera `tenants/*/general/`:

- Añade y actualiza lo seleccionado, y **borra** lo que deja de estarlo.
- No toca nunca `custom/`.
- Si un cliente desaparece del config, se borra su `general/` y se conserva su `custom/`.

### Añadir un cliente

1. Añádelo en `master/config.yaml` con su `orgId` y su selección (`gitSync: false` al principio).
2. Haz push: la Action crea `tenants/<cliente>/general/`.
3. Cuando quieras conectarlo, pon `gitSync: true`; el Job crea su conexión en el siguiente despliegue.

### Paneles propios de un cliente

Deja el JSON en `tenants/<cliente>/custom/` (con las subcarpetas que quieras), por PR o desde Grafana si la conexión permite escritura por PR. La única regla: su `uid` no puede repetirse dentro del mismo cliente.

### Datasources: variables, no UIDs

Cada org tiene sus propios datasources con UIDs distintos. Los paneles **generales** no llevan UIDs fijos: usan variables ocultas que eligen el datasource de la org por nombre.

```json
"templating": { "list": [
  { "name": "ds_mimir", "type": "datasource", "query": "prometheus", "regex": "/^Mimir/", "hide": 2 },
  { "name": "ds_loki",  "type": "datasource", "query": "loki",       "regex": "/^Loki/",  "hide": 2 }
]},
"panels": [ { "datasource": { "type": "prometheus", "uid": "${ds_mimir}" } } ]
```

### Validaciones (fallan la Action)

| Comprobación | Dónde |
|---|---|
| `orgId` repetido, nombre de cliente no válido, ruta de `general`/`exclude` inexistente | config |
| JSON no válido, falta `uid` o `title`, `uid` no válido | todos los paneles |
| `uid` repetido dentro de un cliente (general + custom) | cada cliente |
| datasource con UID fijo o variable no definida en `templating` | solo `general/` |
| cambios hechos a mano en `tenants/*/general/` | PRs |

Para probar en local: `scripts/render.sh --check` (no escribe nada) o `scripts/render.sh`.

## Job de Git Sync

`deploy/gitsync/gitsync-sync.sh` lee `deploy/tenants.json` y, por cada cliente con `gitSync: true`:

1. Espera a Grafana, detecta la versión de la API de provisioning y aborta si Grafana sigue en legacy storage.
2. Comprueba que la org existe. Namespace: `default` para la org 1 y `org-<id>` para el resto.
3. Si el `Repository` `gitsync-<cliente>` ya existe, no lo toca. Si no, lo crea apuntando a `tenants/<cliente>`.

| Variable | Por defecto | Descripción |
|---|---|---|
| `GRAFANA_URL`, `GRAFANA_USER`, `GRAFANA_PASSWORD` | — | Grafana y administrador del servidor |
| `GITHUB_TOKEN` | — | token con acceso al repo |
| `TENANTS_FILE` | — | ruta a `tenants.json` |
| `SYNC_TARGET` | `folder` | `folder`: el cliente sincroniza en su carpeta; `instance`: toda la org |
| `WORKFLOWS` | `["branch"]` | cambios desde la UI por PR; `[]` = solo lectura |
| `DRY_RUN` | `false` | solo informa |

En Kubernetes: `kubectl apply -k deploy/` (o una app de ArgoCD), con el Secret `grafana-gitsync` creado aparte (ver `deploy/gitsync/secret.example.yaml`).

## Entorno de pruebas

Grafana 13.2.4 multi-org con un stack de datos real en pequeño, parecido a producción:

| Servicio | Qué hace |
|---|---|
| `mimir` | Mimir 2.17 multi-tenant: un tenant por cliente |
| `prometheus` + `node-exporter` | mide el host y escribe en Mimir una vez por cliente, con la etiqueta `cliente=<nombre>` |
| `loki` + `log-generator` | Loki 3.5 multi-tenant; logs realistas de una tienda online por cliente (pedidos con importe, método de pago, canal y región; carritos abandonados; pagos rechazados con motivo; latencias; stock) |
| `orgs-init` | crea las orgs y sus datasources `Mimir-<cliente>` / `Loki-<cliente>` con la cabecera `X-Scope-OrgID` de su cliente |
| `gitsync-init` | el mismo script que el Job de Kubernetes |

```bash
scripts/render.sh                                            # genera deploy/tenants.json
cp dev/.env.example dev/.env                                   # y pon tu token en GITHUB_TOKEN
docker compose -f dev/docker-compose.yml up -d                # Grafana en http://localhost:3001 (admin/admin)
docker compose -f dev/docker-compose.yml logs -f gitsync-init # resultado del Job
dev/check-isolation.sh                                        # qué cliente ve cada org
dev/check-queries.sh <panel.json> [org]                       # ejecuta las consultas de un panel
docker compose -f dev/docker-compose.yml down -v              # borrar todo
```

Cada org solo ve los datos de su cliente: `dev/check-isolation.sh` lanza la misma consulta desde cada org y muestra el resultado.
