# Contexto para agentes de IA (Claude Code, GitHub Copilot y otros)

Repo **público** de paneles de Grafana multi-cliente sincronizados con Git Sync. Datos de prueba (`cliente-a/b/c`); los valores reales se pondrán más adelante. Responde en español.

## Arquitectura

- `master/general/`: paneles comunes, con jerarquía libre. `_folder.json` en cada carpeta solo aporta el título.
- `master/config.yaml`: única fuente de verdad. Por cliente: `orgId`, `gitSync`, `general` (rutas o ficheros) y `exclude`.
- `scripts/render.sh`: lógica determinista (bash + yq v4 + jq + rsync, **sin IA**). Genera `tenants/<cliente>/general/` (con `rsync --delete`), crea los `_folder.json` y `deploy/tenants.json`, y valida. `--check` no escribe nada.
- `scripts/convert-dashboard.sh <export.json> <uid> <destino.json> ["<título carpeta>"]`: convierte un export de Grafana (datasources → variables, uid fijo) y, opcionalmente, titula la carpeta. `scripts/folder-title.sh <carpeta> "<título>"`: escribe el `_folder.json` con el título visible (UID derivado de la ruta).
- `.github/workflows/render.yml`: en push a `main` ejecuta render y hace commit del bot. `validate.yml`: en PRs ejecuta `--check` y rechaza cambios en `tenants/*/general/`.
- `deploy/chart/grafana-gitsync/`: **chart de Helm** (nada de kustomize, decisión del usuario). Lee `master/config.yaml` como values y crea **un Job por cliente** con `gitSync: true` (hook `post-install,post-upgrade`, PostSync en ArgoCD) y un CronJob opcional. El script `files/gitsync-sync.sh` (sh + curl + jq, idempotente) crea el `Repository` `gitsync-<cliente>` en el namespace `default` (org 1) u `org-<id>` solo si falta, con `path: tenants/<cliente>` y `target: folder`; admite un cliente (`TENANT`, `ORG_ID`…) o todos (`TENANTS_FILE`, usado por el CronJob y por `dev/`). Opcional `orgs.enabled`: Job `<release>-orgs` (`files/orgs-sync.sh`, hook-weight -5, antes que los de Git Sync) que crea las **orgs** que falten **sin modificar nunca las existentes** (solo avisa), sin orgs de relleno y con `orgs.dryRun`. **Los datasources no son cosa de este chart**: los provisiona el chart de Grafana (decisión del usuario), y la org debe existir antes. Ejemplo de Application con dos fuentes: `deploy/argocd/application.example.yaml`. **Las conexiones se crean siempre desde el clúster, nunca desde GitHub Actions** (requisito del usuario).
- `dev/`: Grafana 13.2.4 + Postgres + Mimir 2.17 y Loki 3.5 multi-tenant (`X-Scope-OrgID` = nombre del cliente) + Prometheus/node-exporter + generador de logs realistas de una tienda online (logfmt). Grafana en http://localhost:3001 (admin/admin). Puerto, contraseña, URL y token, en `dev/.env` (plantilla: `dev/.env.example`). Herramientas: `dev/status.sh`, `dev/check-isolation.sh` y `dev/check-queries.sh <panel.json> [org]`.

## Reglas y aprendizajes (comprobados en Grafana 13.x)

- Los paneles de `general/` **no llevan UIDs de datasource**: usan variables ocultas `ds_mimir` (`query: prometheus`, `regex: /^Mimir/`) y `ds_loki` (`regex: /^Loki/`). Cada org conserva sus UIDs de datasource; los nombres deben empezar por `Mimir` o `Loki`.
- Los UIDs de dashboard, carpeta y datasource son **únicos por org**, no globales.
- `general` es el UID reservado de la carpeta raíz de Grafana: nunca usarlo. Las carpetas generadas llevan prefijo `gen-`, y las de custom, `custom-`.
- Grafana 13.2 pide `_folder.json` (`kind: Folder`, `metadata.name` = UID y `spec.title`) en cada carpeta; sin él, el UID cambia en cada sync.
- Grafana 13 solo permite por defecto `target: folder` (no `instance`).
- El token de GitHub necesita *Contents*, *Pull requests* y *Webhooks* en **Read and write**; sin escritura, Git Sync da `write permission denied` aunque los workflows sean `["branch"]`.
- Si un datasource provisionado apunta a una org que no existe, Grafana 13 no arranca.
- Añadir `uid` a un datasource que ya existe falla (`data source not found`); habría que borrarlo y recrearlo. Por eso se usan variables.
- Tras una sincronización fallida puede hacer falta un pull completo: `POST .../repositories/<nombre>/jobs` con `{"action":"pull","pull":{"incremental":false}}`.
- La API de provisioning en 13.x prefiere `v0alpha1`; el Job la detecta solo.
- En las llamadas a la API, manda siempre `X-Grafana-Org-Id`: sin ella, Grafana usa la org "actual" del usuario, que cambia cuando alguien cambia de org en el navegador.
- El acceso de un token fine-grained va ligado al repo concreto: si el repo se borra y se recrea con el mismo nombre, hay que volver a darle acceso.
- `GF_SECURITY_ADMIN_PASSWORD` solo se aplica al crear la BD; después: `grafana cli admin reset-admin-password`.
- En POSIX sh (dash), `echo` interpreta las barras invertidas y rompe el JSON: usa `printf '%s\n'`. Las comillas dentro de líneas de log enviadas a Loki deben ir escapadas.
- En los `sum by (<etiqueta>)` de LogQL, filtra `<etiqueta>!=""` para que no salgan series sin nombre.
- Hay dos programas llamados `yq`: el de Python (Ubuntu, `/usr/bin/yq`, versión `0.0.0`) no sirve; hace falta el de mikefarah v4 (en `~/.local/bin`). `render.sh` lo detecta.
- En `dev/` todas las métricas llevan `cluster="dev"`: los paneles importados que filtran por `$cluster` funcionan eligiendo ese valor.
- `dev/check-queries.sh` marca como `VAR` las consultas que usan variables del panel (no puede resolverlas): hay que revisarlas en Grafana o sustituir los valores a mano.
- El 4.º dato de `convert-dashboard.sh` titula la **carpeta** destino, no el panel: solo para carpetas nuevas. En una existente renombraría la carpeta para todos los clientes.
- Los paneles exportados de producción guardan los **valores actuales de sus variables** (`templating.list[].current`): clúster, nodos, IPs. Revísalos antes de subir.
- Las comprobaciones previas a un push deben **parar** si encuentran algo; nunca `git add -A` a ciegas ni subir ficheros que no has creado sin preguntar.

## Cómo trabajar aquí

- Tras cualquier cambio en `master/`, `tenants/*/custom/` o `scripts/`, ejecuta `scripts/render.sh --check` (necesita `yq` v4 de mikefarah en el PATH).
- No edites `tenants/*/general/` ni `deploy/tenants.json` a mano: se generan.
- Nunca subas secretos ni nada de producción (nombres de clientes o productos, namespaces, hosts, repos internos): el repo es público. Antes de cada commit, sigue la skill `publicar-cambios`. El token va en `dev/.env` (ignorado por git).
- Commits en español; termina el mensaje con la línea `Co-Authored-By` que indique el sistema.
- Manual para usuarios: `docs/MANUAL.md`; arranque desde cero: `docs/QUICKSTART.md`; historial de cambios: `CHANGELOG.md` (añade una entrada por cada cambio que afecte al uso).
- Skills (estándar Agent Skills, una sola copia en `.github/skills/`; `.claude/skills` es un enlace simbólico):
  - `probar-en-local`: levantar y depurar `dev/`, también en otra máquina o desde el móvil.
  - `nuevo-panel`: añadir o convertir un panel.
  - `panel-con-datos`: paneles con datos realistas (LogQL y PromQL) y su verificación.
  - `nuevo-cliente`: clientes y selección de carpetas.
  - `publicar-cambios`: lista de comprobación antes de commit y push (repo público) y verificación posterior.
- Agentes `gitsync-repo-expert`, `revisor-paneles` y `disenador-paneles`, en `.github/agents/*.agent.md` (Copilot) y `.claude/agents/*.md` (Claude Code). Mismo cuerpo con distinta cabecera: si cambias uno, cambia el otro.
- Contexto: este `AGENTS.md` es la fuente; `CLAUDE.md` lo importa y `.github/copilot-instructions.md` resume las reglas para Copilot (chat y code review).

## Contexto

Este sistema se diseñó para montar los paneles de un Grafana multi-org en producción tras subirlo a Grafana 13. Los detalles de producción **no se guardan en este repo público**: pídeselos al usuario si los necesitas.
