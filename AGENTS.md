# Contexto para agentes de IA (Claude Code, GitHub Copilot y otros)

Repo **público** de paneles de Grafana multi-cliente sincronizados con Git Sync. Datos de prueba (`cliente-a/b/c`); los valores reales se pondrán más adelante. Responde en español.

## Arquitectura

- `master/general/`: paneles comunes, con jerarquía libre. `_folder.json` en cada carpeta solo aporta el título.
- `master/config.yaml`: única fuente de verdad. Por cliente: `orgId`, `gitSync`, `general` (rutas o ficheros) y `exclude`.
- `scripts/render.sh`: lógica determinista (bash + yq v4 + jq + rsync, **sin IA**). Genera `tenants/<cliente>/general/` (con `rsync --delete`), crea los `_folder.json` y `deploy/tenants.json`, y valida. `--check` no escribe nada.
- `.github/workflows/render.yml`: en push a `main` ejecuta render y hace commit del bot. `validate.yml`: en PRs ejecuta `--check` y rechaza cambios en `tenants/*/general/`.
- `deploy/gitsync/gitsync-sync.sh`: Job idempotente (sh + curl + jq). Por cada cliente con `gitSync: true`, si no existe el `Repository` `gitsync-<cliente>` en el namespace `default` (org 1) u `org-<id>`, lo crea con `path: tenants/<cliente>` y `target: folder`. **Corre como Job de Kubernetes (`deploy/`, hook PostSync de ArgoCD) o como init container en Docker. Nunca en GitHub Actions** (requisito del usuario).
- `dev/`: Grafana 13.2.4 + Postgres + Mimir 2.17 y Loki 3.5 multi-tenant (`X-Scope-OrgID` = nombre del cliente) + Prometheus/node-exporter + generador de logs. Grafana en http://localhost:3001 (admin/admin).

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

## Cómo trabajar aquí

- Tras cualquier cambio en `master/`, `tenants/*/custom/` o `scripts/`, ejecuta `scripts/render.sh --check` (necesita `yq` v4 de mikefarah en el PATH).
- No edites `tenants/*/general/` ni `deploy/tenants.json` a mano: se generan.
- Nunca subas secretos: el repo es público. El token va en una variable de entorno (`GITHUB_TOKEN`).
- Commits en español; termina el mensaje con la línea `Co-Authored-By` que indique el sistema.
- Manual para usuarios: `docs/MANUAL.md`.
- Skills (estándar Agent Skills, una sola copia): `.github/skills/`; `.claude/skills` es un enlace simbólico a esa carpeta.
- Agentes: `.github/agents/*.agent.md` (Copilot) y `.claude/agents/*.md` (Claude Code). Mismo contenido con distinta cabecera: si cambias uno, cambia el otro.
- Contexto: este `AGENTS.md` es la fuente; `CLAUDE.md` lo importa y `.github/copilot-instructions.md` resume las reglas para Copilot (chat y code review).

## Contexto

Este sistema se diseñó para montar los paneles de un Grafana multi-org en producción tras subirlo a Grafana 13. Los detalles de producción **no se guardan en este repo público**: pídeselos al usuario si los necesitas.
