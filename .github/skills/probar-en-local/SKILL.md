---
name: probar-en-local
description: Levantar, comprobar, depurar o reiniciar el entorno Docker de pruebas (dev/) con Grafana 13 multi-org, Mimir, Loki y el Job de Git Sync, en esta máquina o en otra, y abrirlo desde otros dispositivos (móvil, otro PC, VPN). Úsala para enseñar el funcionamiento, verificar un cambio de punta a punta o investigar por qué un panel no aparece en una org.
---

# Entorno de pruebas

Todo desde la raíz del repo. Por defecto, Grafana está en http://localhost:3001 (admin/admin).

## Levantarlo en una máquina nueva

1. Herramientas: Docker con `docker compose`, git, gh, jq y **yq v4 de mikefarah** (no el yq de Python). Si falta yq:
   ```bash
   mkdir -p ~/.local/bin && curl -sSL -o ~/.local/bin/yq https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64 && chmod +x ~/.local/bin/yq
   export PATH="$HOME/.local/bin:$PATH"
   ```
2. Repo y sesión: `gh auth login --web --git-protocol https --scopes repo,workflow && gh auth setup-git && gh repo clone aelogonpin/grafana-dashboards-gitsync`.
3. Configuración: `cp dev/.env.example dev/.env` y que el **usuario** rellene `GITHUB_TOKEN` (fine-grained, solo este repo, *Contents*, *Pull requests* y *Webhooks* en Read and write). Nunca pidas que pegue el token en el chat. Comprueba `git check-ignore dev/.env`.
4. Arranque:
   ```bash
   scripts/render.sh
   docker compose -f dev/docker-compose.yml up -d
   docker compose -f dev/docker-compose.yml logs gitsync-init | grep gitsync
   ```
   La primera vez descarga ~2 GB de imágenes. Orden: postgres → grafana → `orgs-init` (orgs 2..N y datasources `Mimir-<cliente>`/`Loki-<cliente>` con `X-Scope-OrgID`) → `gitsync-init` (el Job). Mimir, Loki, Prometheus, node-exporter y log-generator generan datos por cliente.

Variables de `dev/.env` (todas opcionales salvo el token):

| Variable | Por defecto | Para qué |
|---|---|---|
| `GITHUB_TOKEN` | — | token que Grafana guarda para Git Sync |
| `GRAFANA_PORT` | `3001` | puerto en la máquina (cámbialo si está ocupado) |
| `GRAFANA_ADMIN_PASSWORD` | `admin` | contraseña de admin; solo se aplica al crear la BD por primera vez |
| `GRAFANA_ROOT_URL` | `http://localhost:3001/` | URL desde la que se entra; ponla con la IP si se accede desde otros dispositivos |

Si cambias el puerto o la contraseña, los scripts de `dev/` necesitan `GRAFANA=http://localhost:<puerto>` y `AUTH=admin:<contraseña>`.

## Abrirlo desde otro dispositivo (móvil, otro PC)

1. IP de la máquina: `ip -4 -o addr show scope global | awk '{print $2, $4}'`. Usa la de la interfaz de red física (p. ej. `enp*`/`wlp*`, 192.168.x.x) si están en la misma red, o la de la VPN (p. ej. `wt0`, `tailscale0`) si el otro dispositivo está en ella. Las de Docker y las de virtualización (`docker0`, `br-*`, `virbr*`, `lxdbr*`) no sirven.
2. Comprueba desde la máquina: `curl -s -o /dev/null -w '%{http_code}\n' http://<IP>:3001/` (302 = bien).
3. Si no carga desde el otro dispositivo: cortafuegos. Con ufw, el usuario ejecuta `sudo ufw allow 3001/tcp`.
4. Pon `GRAFANA_ROOT_URL=http://<IP>:3001/` en `dev/.env` y `docker compose -f dev/docker-compose.yml up -d grafana`, para que los enlaces absolutos usen la IP.
5. **Seguridad**: con admin/admin, cualquiera en esa red entra. Si la red no es de confianza, cambia la contraseña. Con la BD ya creada:
   ```bash
   docker compose -f dev/docker-compose.yml exec grafana grafana cli admin reset-admin-password '<nueva>'
   ```
   y pon la misma en `GRAFANA_ADMIN_PASSWORD` para que los init containers y los scripts la usen.
6. En el móvil, el selector de org está en el menú ☰. Enlace directo a un panel: `http://<IP>:3001/d/<uid>/?orgId=<org>`.

## Comprobar

| Comando | Muestra |
|---|---|
| `dev/status.sh [orgs]` | estado de Git Sync (healthy/sync) y los paneles de cada org |
| `dev/check-isolation.sh [orgs]` | qué cliente ve cada org en Mimir y Loki (debe ser solo el suyo) |
| `dev/check-queries.sh <panel.json> [org] [rango]` | ejecuta cada consulta del panel en esa org y enseña el último valor; sale con 1 si alguna no tiene datos |
| `docker compose -f dev/docker-compose.yml run --rm --no-deps gitsync-init` | relanza el Job (idempotente; lee el token de `dev/.env`) |
| `DRY_RUN=true docker compose -f dev/docker-compose.yml run --rm --no-deps gitsync-init` | qué haría el Job sin tocar nada |

Las llamadas a la API llevan siempre `-H "X-Grafana-Org-Id: <org>"`: sin esa cabecera, Grafana usa la org "actual" del usuario admin, que cambia cuando alguien cambia de org en el navegador.

## Diagnóstico

| Síntoma | Causa | Solución |
|---|---|---|
| `write permission denied` | el token no puede escribir en el repo (o no tiene acceso: el acceso va ligado al repo concreto, y si se recrea hay que volver a darlo) | revisar el token. Prueba: crear una rama temporal con `POST /repos/<repo>/git/refs` (201) y borrarla después (`DELETE .../git/refs/heads/<rama>`) |
| `A folder with that name already exists` en `general/` | falta `_folder.json` y Git Sync usa el UID reservado `general` | `scripts/render.sh` (genera los `_folder.json`) y push |
| sync `success` pero faltan paneles o siguen los antiguos | la sincronización incremental no reprocesa lo de antes | pull completo: `curl -u admin:admin -H Content-Type:application/json -X POST localhost:3001/apis/provisioning.grafana.app/v0alpha1/namespaces/<ns>/repositories/gitsync-<cliente>/jobs -d '{"action":"pull","pull":{"incremental":false}}'` (`ns`: `default` para la org 1, `org-<id>` para el resto) |
| `job ... already exists` al forzar el pull | ya hay una sincronización en marcha | esperar y repetir |
| Grafana no arranca | un datasource provisionado apunta a una org que no existe | solo la org 1 va por fichero (`dev/provisioning/datasources/org1.yaml`); el resto, por API en `dev/init-orgs.sh` |
| panel vacío | la org no tiene datasource cuyo nombre empiece por `Mimir`/`Loki`, o aún no hay datos | renombrarlo / esperar 1–2 min |
| Loki no recibe logs del generador | JSON mal formado (comillas sin escapar en la línea) | `dev/stack/log-generator.sh` escapa `"`; prueba un push a mano con `curl -w '%{http_code}'` (204 = bien) |
| puerto 3001 ocupado | otro entorno levantado | `GRAFANA_PORT` en `dev/.env`, o `down` del otro |

Detalle de una sincronización: `curl -s -u admin:admin localhost:3001/apis/provisioning.grafana.app/v0alpha1/namespaces/<ns>/repositories/gitsync-<cliente> | jq .status`.

## Reiniciar o borrar

```bash
docker compose -f dev/docker-compose.yml up -d --force-recreate <servicio>   # tras cambiar su config
docker compose -f dev/docker-compose.yml stop                                # parar, conservando todo
docker compose -f dev/docker-compose.yml down -v                             # borrarlo todo
```

Tras un `down -v`, el siguiente `up -d` vuelve a crear las orgs y el Job crea otra vez las conexiones.
