# Instrucciones para GitHub Copilot

Repo **público** de paneles de Grafana multi-cliente sincronizados con Git Sync. El contexto completo (arquitectura y aprendizajes de Grafana 13) está en [`AGENTS.md`](../AGENTS.md); el uso, en [`docs/MANUAL.md`](../docs/MANUAL.md). Responde en español.

## Reglas que no se rompen

- `master/config.yaml` es la única fuente de verdad. `tenants/*/general/` y `deploy/tenants.json` los genera `scripts/render.sh`: **no se editan a mano**.
- Los paneles de `master/general/` no llevan UIDs de datasource: usan `${ds_mimir}` y `${ds_loki}` (variables ocultas con `regex: /^Mimir/` y `/^Loki/`).
- El `uid` de un panel es único dentro de cada cliente, como mucho 40 caracteres, y nunca `general` (UID reservado de Grafana).
- Cada carpeta lleva `_folder.json` (`kind: Folder`, `metadata.name` = UID, `spec.title`).
- La lógica es determinista: bash + yq v4 + jq + rsync, sin IA.
- El Job de Git Sync (`deploy/gitsync/gitsync-sync.sh`) corre como Job de Kubernetes o init container en Docker, **nunca en GitHub Actions**. Es POSIX sh + curl + jq e idempotente.
- Nunca subas tokens, contraseñas, URLs internas ni nombres reales de clientes.

## Antes de proponer un cambio

Ejecuta `scripts/render.sh --check`. Si cambia el comportamiento, actualiza `README.md`, `docs/MANUAL.md` y `AGENTS.md`.
