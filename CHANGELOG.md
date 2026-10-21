# Cambios

Historial de cambios que afectan al uso del repo, del más reciente al más antiguo. Añade una entrada por cada cambio visible: nuevos scripts, cambios de comportamiento o de documentación importantes.

## 2026-10-21

### Añadido
- `scripts/folder-title.sh <carpeta> "<título>"`: define el título con el que se ve una carpeta en Grafana (escribe su `_folder.json`).
- `scripts/convert-dashboard.sh`: 4.º dato opcional con el título de la carpeta destino. Úsalo solo para carpetas nuevas: en una existente renombraría la carpeta para todos los clientes.
- Panel de monitorización de VMs Linux en `master/general/kubernetes/` (aportado por el usuario), que reciben cliente-a, cliente-b y cliente-c.
- `dev/`: todas las métricas llevan la etiqueta `cluster="dev"`, para que funcionen los paneles que filtran por clúster.
- `CHANGELOG.md`.

### Cambiado
- `scripts/folder-title.sh` y `scripts/convert-dashboard.sh` admiten rutas relativas al directorio actual (también `../master/...` desde `scripts/`) y absolutas.
- `scripts/render.sh` detecta el `yq` de Python (el de Ubuntu) y explica cómo instalar el de mikefarah, en vez de fallar con un error confuso.
- `dev/check-queries.sh` marca como `VAR` las consultas que usan variables del panel, en vez de darlas por fallidas.
- Quick start: los pasos de convertir el panel y titular la carpeta se unen en uno (6.2), con la explicación de cada dato del comando.
- Skills y agentes: las comprobaciones antes de publicar paran el proceso si encuentran algo, y los ficheros añadidos por otra persona no se suben sin preguntar; el revisor busca datos en los valores guardados de las variables.

## 2026-10-20

### Añadido
- Sistema de reparto de paneles: `master/config.yaml` (selección por cliente con `general` y `exclude`), `scripts/render.sh` con validaciones y GitHub Actions (regeneración en push a `main` y validación en PRs).
- Metadatos de carpeta (`_folder.json`) generados automáticamente; se evita el UID reservado `general`.
- `scripts/convert-dashboard.sh`: convierte un export de Grafana al formato del repo (datasources → variables con regex).
- Job idempotente de Git Sync (`deploy/`), como Job de Kubernetes y como init container de Docker.
- Entorno de pruebas `dev/`: Grafana 13.2.4 con 3 orgs, Mimir y Loki multi-tenant, datos realistas de una tienda online, y `dev/status.sh`, `dev/check-isolation.sh` y `dev/check-queries.sh`.
- Panel de negocio de cliente-a y panel POC de ejemplo (`docs/ejemplos/poc-tienda.json`).
- Documentación: `README.md`, `docs/QUICKSTART.md` y `docs/MANUAL.md`.
- Contexto para agentes de IA: `AGENTS.md`, `CLAUDE.md`, instrucciones de Copilot, 5 skills y 3 agentes (formatos Claude Code y GitHub Copilot).
- `dev/.env.example`: puerto, contraseña, URL y token configurables, para usar el entorno desde otra máquina o desde el móvil.

### Cambiado
- Repo recreado con un historial limpio.
