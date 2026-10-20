---
applyTo: "scripts/**,deploy/**,dev/**,.github/workflows/**,master/config.yaml"
---

# Scripts, Job, entorno de pruebas y workflows

- `scripts/render.sh`: bash 4 + yq v4 (mikefarah) + jq + rsync, determinista. Cualquier cambio debe seguir detectando: ruta inexistente en `general`/`exclude`, `orgId` repetido, JSON no válido, `uid` repetido o no válido, datasource con UID fijo en `general/` y `_folder.json` no válido. También debe seguir borrando lo que deja de seleccionarse y conservando `custom/`.
- Los workflows solo ejecutan `render.sh` (push a `main`: generar y commit del bot; PR: `--check` y rechazo de cambios en `tenants/*/general/`). No añadas pasos que llamen a Grafana desde Actions.
- `deploy/gitsync/gitsync-sync.sh`: POSIX sh (imagen alpine) + curl + jq. Idempotente: GET del `Repository` y POST solo si devuelve 404. Namespace `default` para la org 1 y `org-<id>` para el resto. Detecta la versión de la API (`preferredVersion`) y aborta si `legacyStorage` es true.
- `master/config.yaml`: claves por cliente `orgId` (único), `gitSync` (bool), `general` (lista no vacía) y `exclude` (opcional). Nombres de cliente: `^[a-z0-9][a-z0-9-]*$`. Con datos de prueba, nombres genéricos.
- `dev/`: solo la org 1 se provisiona por fichero; si un datasource provisionado apunta a una org inexistente, Grafana 13 no arranca.
- Secretos: solo por variables de entorno o Secrets de Kubernetes cifrados fuera del repo.
