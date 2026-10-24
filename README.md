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
  chart/grafana-gitsync/      chart de Helm: un Job de Git Sync por cliente (lee master/config.yaml)
    files/gitsync-sync.sh     script idempotente (sh + curl + jq)
  argocd/application.example.yaml   Application de ArgoCD de ejemplo
  tenants.json                GENERADO: lista de clientes para el entorno Docker de dev/
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

## Job de Git Sync (chart de Helm)

Las conexiones de Git Sync las crea un **Job dentro del clúster**, nunca GitHub Actions. El chart `deploy/chart/grafana-gitsync` lee `master/config.yaml` como fichero de values y crea **un Job por cliente** con `gitSync: true`. Cada Job:

1. Espera a Grafana, detecta la versión de la API de provisioning y aborta si Grafana sigue en legacy storage.
2. Comprueba que la org existe. Namespace: `default` para la org 1 y `org-<id>` para el resto.
3. Si el `Repository` `gitsync-<cliente>` ya existe, no lo toca. Si no, lo crea apuntando a `tenants/<cliente>`.

Los Jobs son hooks `post-install,post-upgrade` de Helm, que ArgoCD ejecuta como **PostSync**: se lanzan en cada sincronización. En ArgoCD se ve un Job por cliente con su estado.

```
master/config.yaml  ──(push)──►  ArgoCD sincroniza  ──►  Job gitsync-<cliente> por cada gitSync: true
                                                            └─► crea la conexión si falta ──► Git Sync carga sus paneles
```

**Instalación con ArgoCD:** ver `deploy/argocd/application.example.yaml`. Usa dos fuentes del mismo repo: el chart y `master/config.yaml` como values (`$paneles/master/config.yaml`). Antes, crea el Secret `grafana-gitsync` en el namespace destino (`deploy/chart/grafana-gitsync/secret.example.yaml`).

**Sin ArgoCD:**

```bash
helm upgrade --install grafana-gitsync deploy/chart/grafana-gitsync -n <namespace> \
  -f master/config.yaml --set grafana.url=http://<service-de-grafana>
```

| Value | Por defecto | Descripción |
|---|---|---|
| `grafana.url` | `http://grafana.grafana.svc:80` | Service de Grafana visto desde el clúster (con sub-path si lo usa) |
| `grafana.existingSecret` | `grafana-gitsync` | Secret con `grafana-user`, `grafana-password` y `github-token` |
| `gitSync.target` | `folder` | `folder`: el cliente sincroniza en su carpeta; `instance`: toda la org |
| `gitSync.workflows` | `["branch"]` | cambios desde la UI por PR; `[]` = solo lectura |
| `image.installTools` | `true` | instala curl y jq al arrancar (necesita internet); `false` con una imagen que ya los traiga |
| `cronjob.enabled` | `false` | CronJob que revisa todos los clientes periódicamente y recrea conexiones borradas |
| `orgs.enabled` | `false` | Job que prepara las orgs y sus datasources (ver abajo) |
| `orgs.dryRun` | `false` | el Job de orgs solo informa de lo que haría |
| `orgs.datasources.mimirUrl`, `lokiUrl`, `tempoUrl` | de prueba | URLs para los datasources que haya que crear (`tempoUrl` vacío: no gestiona trazas) |
| `orgs.lokiAuth.existingSecret`, `userKey`, `passwordKey` | vacío | basic auth de Loki desde un Secret (opcional) |
| `orgs.renameOrgs` | `false` | renombrar las orgs cuyo nombre no coincide con el del config |
| `job.dryRun` | `false` | solo informa |
| `tenants`, `repo` | — | vienen de `master/config.yaml` |

### Orgs y datasources (opcional, `orgs.enabled`)

Un Job `<release>-orgs` corre **antes** que los de Git Sync (`hook-weight: -5`) y prepara cada org del config **sin modificar nada que ya exista**:

| Qué | Si existe | Si no existe |
|---|---|---|
| Org | no se toca; si su nombre no coincide, solo avisa (`orgs.renameOrgs` para renombrarla) | se crea solo si su `orgId` es el siguiente que asignará Grafana (no reutiliza ids); si no, error explicando por qué |
| Datasource por tipo (`prometheus`, `loki`, `tempo`) | no se toca, sea cual sea su nombre; si ninguno empieza por `Mimir` / `Loki` / `Tempo`, avisa (los paneles no lo encontrarían) | crea `Mimir-<cliente>`, `Loki-<cliente>` o `Tempo-<cliente>` con `X-Scope-OrgID=<cliente>` |

La primera vez en un entorno que ya tiene orgs, lánzalo con `orgs.dryRun=true` y revisa el log: dice qué existe, qué crearía y qué no encaja.

Para dar de alta o conectar un cliente basta con cambiar `master/config.yaml` (`gitSync: true`) y hacer push: ArgoCD sincroniza y su Job lo conecta. El entorno Docker de `dev/` usa el mismo script en modo "todos los clientes" (`TENANTS_FILE`).

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
