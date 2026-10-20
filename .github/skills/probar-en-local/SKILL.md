---
name: probar-en-local
description: Levantar, comprobar, depurar o reiniciar el entorno Docker de pruebas (dev/) con Grafana 13 multi-org, Mimir, Loki y el Job de Git Sync. Úsala para enseñar el funcionamiento, verificar un cambio de punta a punta o investigar por qué un panel no aparece en una org.
---

# Entorno de pruebas local

Todo desde la raíz del repo. Grafana en http://localhost:3001 (admin/admin).

## Levantar

```bash
scripts/render.sh                                  # genera deploy/tenants.json
export GITHUB_TOKEN=...                             # token del usuario; pídele que lo ponga en su .env, nunca en el chat
docker compose -f dev/docker-compose.yml up -d
```

Orden de arranque: postgres → grafana → `orgs-init` (crea orgs 2..N y datasources `Mimir-<cliente>`/`Loki-<cliente>` con `X-Scope-OrgID`) → `gitsync-init` (el Job). Mimir, Loki, Prometheus, node-exporter y log-generator dan datos reales por cliente.

## Comprobar

| Comando | Muestra |
|---|---|
| `dev/status.sh [orgs]` | estado de Git Sync (healthy/sync) y los paneles de cada org |
| `dev/check-isolation.sh [orgs]` | qué cliente ve cada org en Mimir y Loki (debe ser solo el suyo) |
| `docker compose -f dev/docker-compose.yml run --rm --no-deps -e GITHUB_TOKEN gitsync-init` | relanza el Job (idempotente) |
| `DRY_RUN=true docker compose -f dev/docker-compose.yml run --rm --no-deps gitsync-init` | qué haría el Job sin tocar nada |

## Diagnóstico

| Síntoma | Causa | Solución |
|---|---|---|
| `write permission denied` | el token no puede escribir en el repo | token con *Contents*, *Pull requests* y *Webhooks* en Read and write. Probar con `POST /repos/<repo>/git/refs` en una rama temporal y borrarla después |
| `A folder with that name already exists` en `general/` | falta `_folder.json` y Git Sync usa el UID reservado `general` | ejecutar `scripts/render.sh` (genera los `_folder.json`) y push |
| sync `success` pero faltan paneles | la sincronización incremental no reprocesa lo ignorado antes | pull completo: `curl -u admin:admin -H Content-Type:application/json -X POST localhost:3001/apis/provisioning.grafana.app/v0alpha1/namespaces/<ns>/repositories/gitsync-<cliente>/jobs -d '{"action":"pull","pull":{"incremental":false}}'` |
| Grafana no arranca | un datasource provisionado apunta a una org que no existe | solo la org 1 va por fichero (`dev/provisioning/datasources/org1.yaml`); el resto, por API en `dev/init-orgs.sh` |
| panel vacío | la org no tiene datasource cuyo nombre empiece por `Mimir`/`Loki` | renombrarlo |

Detalle de una sincronización: `curl -s -u admin:admin localhost:3001/apis/provisioning.grafana.app/v0alpha1/namespaces/<ns>/repositories/gitsync-<cliente> | jq .status`.

## Reiniciar o borrar

```bash
docker compose -f dev/docker-compose.yml down -v      # borra todo, datos incluidos
```

Si se reinicia desde cero, las conexiones de Git Sync se pierden: relanza `gitsync-init` con el token.
