# Quick start: de cero a ver tu primer panel en Grafana

En unos 20 minutos tendrás en tu ordenador un Grafana con 3 clientes, datos reales de prueba, y un panel tuyo que viaja de tu carpeta de Descargas hasta Grafana pasando por GitHub.

```
Tu panel (.json) ──> repo en GitHub ──> robot (GitHub Actions) ──> carpeta del cliente ──> Grafana del cliente
```

Si algo no sale como aquí, mira la tabla del final o el [manual](MANUAL.md).

---

## Paso 1. Instalar las herramientas

Necesitas **Docker** (con `docker compose`), **git**, **gh** (la CLI de GitHub), **jq** y **yq**. Comprueba cuáles tienes:

```bash
docker compose version && git --version && gh --version && jq --version && yq --version
```

Si falta `yq` (tiene que ser la v4 de *mikefarah*):

```bash
mkdir -p ~/.local/bin
curl -sSL -o ~/.local/bin/yq https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64
chmod +x ~/.local/bin/yq
export PATH="$HOME/.local/bin:$PATH"     # añádelo también a tu ~/.bashrc
yq --version                              # debe decir v4.x
```

Para el resto, en Ubuntu: `sudo apt install git jq gh`, y Docker según [su guía](https://docs.docker.com/engine/install/).

## Paso 2. Iniciar sesión en GitHub y bajar el repo

```bash
gh auth login --web --git-protocol https --scopes repo,workflow
gh auth setup-git
gh repo clone aelogonpin/grafana-dashboards-gitsync
cd grafana-dashboards-gitsync
```

Si vas a trabajar en tu propia copia, haz antes un *fork* y clona el tuyo.

## Paso 3. Crear el token para Grafana

Grafana necesita un token para leer el repo y proponer cambios por PR.

1. Ve a https://github.com/settings/personal-access-tokens/new
2. Rellena:
   - **Expiration**: 30 días (es para pruebas).
   - **Repository access**: *Only select repositories* → `grafana-dashboards-gitsync`.
   - **Repository permissions**: *Contents*, *Pull requests* y *Webhooks* en **Read and write** (*Metadata* se pone solo).
3. Pulsa **Generate token** y cópialo.
4. Guárdalo en `dev/.env`. Ese fichero está en `.gitignore` y nunca se sube:

```bash
cp dev/.env.example dev/.env
nano dev/.env                       # pega el token en GITHUB_TOKEN=
git check-ignore dev/.env && echo "bien: no se subirá a GitHub"
```

En `dev/.env` también puedes cambiar el puerto (`GRAFANA_PORT`), la contraseña de admin (`GRAFANA_ADMIN_PASSWORD`) y la URL (`GRAFANA_ROOT_URL`). Ver el paso 5 bis.

**No pegues el token en ningún otro sitio**: ni en el chat, ni en un fichero del repo.

## Paso 4. Arrancarlo todo

```bash
scripts/render.sh                                   # prepara las carpetas de los clientes
docker compose -f dev/docker-compose.yml up -d      # la primera vez descarga imágenes: tarda unos minutos
```

Comprueba que está todo arriba:

```bash
docker compose -f dev/docker-compose.yml ps
docker compose -f dev/docker-compose.yml logs gitsync-init | grep gitsync
```

En los logs de `gitsync-init` tienes que ver algo así:

```
[gitsync] [cliente-a] creado default/gitsync-cliente-a -> tenants/cliente-a
[gitsync] [cliente-b] creado org-2/gitsync-cliente-b -> tenants/cliente-b
[gitsync] Resumen: creados=2 ya_existian=0 errores=0
```

`cliente-c` no aparece porque en `master/config.yaml` tiene `gitSync: false`.

## Paso 5. Mirar Grafana

1. Abre **http://localhost:3001** y entra con `admin` / `admin` (si te pide cambiar la contraseña, puedes saltarlo).
2. Arriba a la izquierda está el **selector de organización**: hay una por cliente (`cliente-a`, `cliente-b`, `cliente-c`).
3. En `cliente-a`, abre *Dashboards → Kubernetes → Nodo - Visión general*. El panel "Datos del cliente" dice **cliente-a**.
4. Cambia a `cliente-b` y abre el mismo dashboard: ahora dice **cliente-b**. Es el mismo JSON y cada cliente ve solo sus datos.

Lo mismo desde la terminal:

```bash
dev/status.sh             # conexión de Git Sync y paneles de cada cliente
dev/check-isolation.sh    # qué datos ve cada cliente
```

Si los dashboards tardan, espera un minuto y repite `dev/status.sh`.

## Paso 5 bis. Verlo desde el móvil u otro ordenador

1. Averigua la IP de tu máquina: `ip -4 -o addr show scope global | awk '{print $2, $4}'`. Usa la de tu red (wifi o cable, suele ser `192.168.x.x`) o la de tu VPN si el móvil está conectado a ella. Las de `docker0`, `br-*` o `virbr*` no sirven.
2. En el móvil, abre `http://<esa-IP>:3001`. Si no carga, abre el puerto en el cortafuegos: `sudo ufw allow 3001/tcp`.
3. Pon esa URL en `dev/.env` (`GRAFANA_ROOT_URL=http://<esa-IP>:3001/`) y aplica: `docker compose -f dev/docker-compose.yml up -d grafana`.
4. **Ojo**: con `admin`/`admin`, cualquiera de tu red puede entrar. Si no es tu red de casa, cámbiala:
   ```bash
   docker compose -f dev/docker-compose.yml exec grafana grafana cli admin reset-admin-password 'otra-contraseña'
   ```
   y pon la misma en `GRAFANA_ADMIN_PASSWORD` dentro de `dev/.env`.
5. En el móvil, el selector de organización está dentro del menú ☰.

## Paso 6. Tu primer panel: el POC

Vas a subir un panel nuevo, "POC - Tienda en vivo", y hacer que solo lo vea `cliente-a`.

**6.1. El panel.** Usa `docs/ejemplos/poc-tienda.json`. Es un export de Grafana tal cual, con los datasources de una org concreta. Si te lo has descargado, usa tu fichero.

**6.2. Convertirlo** al formato del repo (cambia los datasources por variables y le pone un `uid` fijo):

```bash
scripts/convert-dashboard.sh docs/ejemplos/poc-tienda.json gen-poc-tienda master/general/poc/tienda.json
```

**6.3. Ponerle nombre bonito a la carpeta**:

```bash
echo '{"apiVersion":"folder.grafana.app/v1beta1","kind":"Folder","metadata":{"name":"titulo"},"spec":{"title":"POC"}}' \
  > master/general/poc/_folder.json
```

**6.4. Dárselo solo a `cliente-a`**: abre `master/config.yaml` y añade `poc` a su lista `general`:

```yaml
  cliente-a:
    orgId: 1
    gitSync: true
    general:
      - kubernetes
      - aplicacion
      - poc              # <- nuevo
```

**6.5. Comprobar** antes de subir:

```bash
scripts/render.sh --check                              # debe terminar en OK
dev/check-queries.sh master/general/poc/tienda.json 1  # cada consulta del panel debe dar OK
```

**6.6. Subirlo**:

```bash
git add master/
git commit -m "POC: panel Tienda en vivo para cliente-a"
git push
gh run watch                  # mira cómo trabaja el robot; debe acabar en verde
```

El robot hace un commit "regenerar paneles de clientes desde master" que copia el panel a `tenants/cliente-a/general/poc/`.

**6.7. Verlo en Grafana.** En 1 minuto como mucho (Git Sync revisa el repo cada 60 s):

```bash
dev/status.sh 1 2
```

`cliente-a` tiene ahora `POC / POC - Tienda en vivo`; `cliente-b`, no. En http://localhost:3001 (org `cliente-a`) abre el panel: pedidos, errores, CPU, memoria y logs en vivo.

**6.8. Dárselo también a `cliente-b`**: añade `poc` a su lista en `master/config.yaml`, y luego `git pull`, commit y push (el `pull` trae antes el commit del robot). En un minuto también lo tiene, con **sus** datos.

## Paso 7. Apagar

```bash
docker compose -f dev/docker-compose.yml stop       # parar, conservando todo
docker compose -f dev/docker-compose.yml down -v    # borrarlo todo
```

Si haces `down -v`, al volver a levantar con `up -d` el Job crea otra vez las conexiones.

---

## Si algo falla

| Lo que ves | Qué pasa | Solución |
|---|---|---|
| `yq: command not found` o error raro de `yq` | falta `yq` o no es la v4 de mikefarah | Paso 1 |
| `gitsync-init` dice `GITHUB_TOKEN vacío` | no existe `dev/.env` | Paso 3, punto 4 |
| `dev/status.sh` dice `write permission denied` | el token no tiene acceso o no puede escribir | revisa el token (Paso 3): repo seleccionado y los 3 permisos en Read and write |
| `git push` pide usuario y contraseña | git no usa tu sesión de `gh` | `gh auth setup-git` |
| `git push` rechazado (`fetch first`) | el robot hizo un commit después del tuyo | `git pull --rebase` y otra vez `git push` |
| La Action sale en rojo | el config o el panel tienen un error | `gh run view --log-failed`; el mensaje dice qué fichero y qué corregir |
| Grafana sin dashboards tras 2 minutos | la conexión está bien pero no se sincronizó todo | `docker compose -f dev/docker-compose.yml run --rm --no-deps gitsync-init` y luego `dev/status.sh` |
| Paneles vacíos | aún no hay datos | espera 1–2 minutos tras arrancar; `dev/check-queries.sh <panel.json> <org>` dice qué consulta falla |
| El móvil no carga Grafana | IP equivocada o cortafuegos | Paso 5 bis |
| `port is already allocated` | el puerto 3001 está ocupado | `GRAFANA_PORT=3002` en `dev/.env` |

## Siguientes pasos

- Recetas para el día a día (clientes nuevos, paneles propios, quitar carpetas): [manual](MANUAL.md).
- Cómo está montado por dentro: [README](../README.md).
